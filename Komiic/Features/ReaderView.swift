import SwiftUI
import UIKit

struct ReaderView: View {
    let comic: Comic
    let chapter: Chapter
    var initialPage = 0
    var chapterDirectory: [Chapter] = []
    var onReturnToDirectory: ((Comic) -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.komiicTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("reader.iPadLandscapeSizing") private var ipadLandscapeSizing = ReaderLandscapeSizing.original
    @State private var pages: [ComicPage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var currentPage = 0
    @State private var controls = true
    @State private var retry = 0
    @State private var readingContentMode: ComicContentMode?
    @State private var doublePage = false
    @State private var selectedChapter: Chapter?
    @State private var directory: [Chapter] = []
    @State private var directoryLoaded = false
    @State private var directoryError: String?
    @State private var requestedPage: Int?
    @State private var pageRequestID = UUID()
    @State private var scrollRequestID = UUID()
    @State private var zoomedPages: Set<String> = []
    @State private var zoomResetID = UUID()
    private var currentChapter: Chapter {
        let selected = selectedChapter ?? chapter
        return directory.first { $0.id == selected.id } ?? selected
    }
    private var isOffline: Bool { downloads.isDownloaded(chapterID: currentChapter.id) }
    private var nextChapter: Chapter? { ReaderChapterNavigation.next(directory, current: currentChapter) }
    private var foreground: Color { settings.einkMode.enabled ? .black : .white }
    private var spreadLayout: ReaderSpreadLayout {
        ReaderSpreadLayout(pageCount: pages.count, doublePage: doublePage, direction: settings.readingDirection)
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
                let landscapeFrame = landscapeViewport(safe: safeGeometry, expanded: geometry)
                let viewportSize = landscapeFrame?.size ?? geometry.size
                ZStack {
                    (settings.einkMode.enabled ? Color.white : Color.black).ignoresSafeArea()
                    if loading {
                        ProgressView("正在载入章节…").tint(foreground).foregroundStyle(foreground)
                    } else if let error {
                        VStack(spacing: 18) {
                            EmptyState(symbol: "wifi.exclamationmark", title: "暂时无法阅读", message: error,
                                       actionTitle: "重试", action: { retry += 1 })
                            Button("返回") { dismiss() }
                        }.foregroundStyle(foreground)
                    } else if pages.isEmpty {
                        EmptyState(symbol: "doc", title: "本章暂无页面", message: "可以稍后重试，或在官网查看。",
                                   actionTitle: "返回", action: { dismiss() }).foregroundStyle(foreground)
                    } else {
                        if doublePage || landscapeFrame != nil {
                            Group {
                                if let frame = landscapeFrame {
                                    landscapeSpreadPager(size: frame.size)
                                        .position(x: frame.midX, y: frame.midY)
                                } else {
                                    TabView(selection: Binding(get: { spreadLayout.start(for: currentPage) }, set: { move(to: $0) })) {
                                        ForEach(spreadLayout.starts, id: \.self) { index in
                                            readerCanvas(spread: spreadLayout.slots(for: index)).tag(index)
                                        }
                                    }
                                    .tabViewStyle(.page(indexDisplayMode: .never))
                                }
                            }
                            .environment(\.layoutDirection, settings.readingDirection == .left ? .rightToLeft : .leftToRight)
                            .onChange(of: currentPage) { _, _ in saveProgress() }
                            .simultaneousGesture(endOfChapterGesture(atEnd: spreadLayout.next(from: currentPage) == spreadLayout.start(for: currentPage)))
                        } else {
                            readerCanvas()
                        }
                        if controls {
                            readerControls(topInset: ReaderChromePlacement.topPadding(
                                safeAreaTop: safeGeometry.safeAreaInsets.top,
                                isPhone: UIDevice.current.userInterfaceIdiom == .phone), offersLandscapeSizing: landscapeFrame != nil)
                                .padding(.bottom, geometry.safeAreaInsets.bottom)
                        }
                    }
                }
                .statusBarHidden(true)
                .preferredColorScheme(settings.einkMode.enabled ? .light : .dark)
                .onAppear { updateSpread(size: viewportSize) }
                .onChange(of: viewportSize) { _, size in updateSpread(size: size) }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .task(id: "\(currentChapter.id):\(retry)") {
            if readingContentMode == nil { readingContentMode = settings.contentMode }
            await loadPages()
            guard !Task.isCancelled, error == nil, !isOffline else { return }
            await downloads.prefetchChapter(pages: pages, chapterID: currentChapter.id,
                baseURL: KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL,
                startingAt: currentPage, cachePolicy: settings.cachePolicy)
        }
        .task { await loadDirectory() }
        .onDisappear {
            saveProgress()
            if settings.cachePolicy == .afterReading { downloads.clearCache(chapterID: currentChapter.id) }
        }
        .onChange(of: settings.readingDirection) { _, _ in resetZoom() }
    }

    private func landscapeViewport(safe: GeometryProxy, expanded: GeometryProxy) -> CGRect? {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        let rect = safe.frame(in: .global)
        let inset = safe.safeAreaInsets
        let left = layoutDirection == .rightToLeft ? inset.trailing : inset.leading
        let full = CGRect(x: rect.minX - left, y: rect.minY - inset.top,
                          width: rect.width + inset.leading + inset.trailing,
                          height: rect.height + inset.top + inset.bottom)
        let expandedFrame = expanded.frame(in: .global)
        let viewport = full.union(expandedFrame)
        guard viewport.width > viewport.height else { return nil }
        return viewport.offsetBy(dx: -expandedFrame.minX, dy: -expandedFrame.minY)
    }

    private func landscapeSpreadPager(size: CGSize) -> some View {
        let selection = Binding<Int?>(get: { spreadLayout.start(for: currentPage) }, set: { index in
            if let index, index != spreadLayout.start(for: currentPage) { move(to: index) }
        })
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(spreadLayout.starts, id: \.self) { index in
                    readerCanvas(spread: spreadLayout.slots(for: index), landscapeSizing: ipadLandscapeSizing)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: selection, anchor: .center)
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea(.container)
    }

    private func updateSpread(size: CGSize) {
        resetZoom()
        doublePage = size.width > size.height
    }

    private func updateZoom(pageID: String, active: Bool) {
        if active { zoomedPages.insert(pageID) }
        else { zoomedPages.remove(pageID) }
    }

    private func resetZoom() {
        zoomedPages.removeAll()
        zoomResetID = UUID()
    }

    private func endOfChapterGesture(atEnd: Bool) -> some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            guard atEnd, !loading, !pages.isEmpty, zoomedPages.isEmpty,
                  value.translation.height < -85,
                  abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
            Task { await continueToNextChapter() }
        }
    }

    @MainActor private func continueToNextChapter() async {
        if !directoryLoaded { await loadDirectory() }
        guard directoryLoaded, directory.contains(where: { $0.id == currentChapter.id }), !loading else { return }
        currentPage = max(0, pages.count - 1)
        saveProgress()
        if let nextChapter { openChapter(nextChapter) }
        else {
            dismiss()
            onReturnToDirectory?(comic)
        }
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(ReaderChapterNavigation.nearby(directory, current: currentChapter)) { nearby in
                Button { openChapter(nearby) } label: {
                    if nearby.id == currentChapter.id { Label(nearby.displayTitle, systemImage: "checkmark") }
                    else { Text(nearby.displayTitle) }
                }
            }
            if let directoryError {
                Button(directoryError) { Task { await loadDirectory() } }
            } else if !directoryLoaded {
                Button("读取附近章节") { Task { await loadDirectory() } }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentChapter.displayTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
        }
        .accessibilityLabel("\(currentChapter.displayTitle)，选择附近五话")
    }

    private func openChapter(_ target: Chapter) {
        guard target.id != currentChapter.id, !loading else { return }
        resetZoom()
        saveProgress()
        if settings.cachePolicy == .afterReading { downloads.clearCache(chapterID: currentChapter.id) }
        pageRequestID = UUID()
        requestedPage = 0
        pages = []
        currentPage = 0
        scrollRequestID = UUID()
        error = nil
        loading = true
        selectedChapter = target
    }

    @MainActor private func loadDirectory() async {
        guard !directoryLoaded else { return }
        if !chapterDirectory.isEmpty {
            directory = chapterDirectory
            directoryLoaded = true
            return
        }
        do {
            directory = try await KomiicAPI(mode: readingContentMode ?? settings.contentMode).chapters(comicID: comic.id)
            try Task.checkCancellation()
            directoryLoaded = directory.contains { $0.id == currentChapter.id }
            directoryError = directoryLoaded ? nil : "暂未找到当前章节，点击重试"
        } catch is CancellationError {
        } catch { directoryError = "目录读取失败，点击重试" }
    }

    private func readerCanvas(spread: [Int?]? = nil, landscapeSizing: ReaderLandscapeSizing? = nil) -> some View {
        let chapterID = currentChapter.id
        let scope = "\(chapterID):\(spread.map { String(describing: $0) } ?? "chapter")"
        return ReaderCanvasView(pages: pages, scopeID: scope, mode: spread.map { .spread($0) } ?? .chapter,
            landscapeSizing: landscapeSizing,
            targetPage: currentPage, requestID: scrollRequestID, resetID: zoomResetID,
            spacing: settings.einkMode.enabled ? 0 : 8,
            footer: directoryLoaded ? (nextChapter == nil ? "继续上拉返回目录" : "继续上拉阅读下一话") : "正在读取目录…",
            onPageChange: { index in
                guard spread == nil, currentChapter.id == chapterID, currentPage != index else { return }
                currentPage = index
                saveProgress()
            }, onZoomChange: { updateZoom(pageID: scope, active: $0) },
            onEndOfChapter: { Task { await continueToNextChapter() } },
            renderPage: { index in
                guard pages.indices.contains(index) else { return AnyView(EmptyView()) }
                return AnyView(ReaderPageImage(page: pages[index], chapterID: chapterID,
                    baseURL: KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL,
                    allowNetwork: !isOffline,
                    shouldLoad: spread == nil || abs(index - currentPage) <= spreadLayout.step + 1)
                    .id("\(chapterID):\(pages[index].id)")
                    .environmentObject(downloads).environmentObject(settings))
            })
            .onTapGesture { toggleControls() }
            .onDisappear { updateZoom(pageID: scope, active: false) }
    }

    private func readerControls(topInset: CGFloat, offersLandscapeSizing: Bool) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("关闭阅读器")
                VStack(alignment: .leading, spacing: 3) {
                    Text(comic.title).font(.subheadline.bold()).lineLimit(1)
                    Text(currentChapter.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                readerMenu(offersLandscapeSizing: offersLandscapeSizing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .modifier(ReaderChromeSurface(ink: settings.einkMode.enabled, cornerRadius: 32))

            Spacer(minLength: 0)
            readerTransport
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func readerMenu(offersLandscapeSizing: Bool) -> some View {
        Menu {
            Picker("阅读方向", selection: $settings.readingDirection) {
                ForEach(ReadingDirection.allCases) { Text($0.title).tag($0) }
            }
            if offersLandscapeSizing {
                Divider()
                ForEach(ReaderLandscapeSizing.allCases) { sizing in
                    Button {
                        guard ipadLandscapeSizing != sizing else { return }
                        resetZoom()
                        ipadLandscapeSizing = sizing
                    } label: {
                        if ipadLandscapeSizing == sizing { Label(sizing.title, systemImage: "checkmark") }
                        else { Text(sizing.title) }
                    }
                }
                Divider()
            }
            Button(library.isBookmarked(chapterID: currentChapter.id, page: currentPage) ? "移除当前页书签" : "添加当前页书签", systemImage: "bookmark") {
                library.toggleBookmark(comic: comic, chapter: currentChapter, page: currentPage, mode: readingContentMode)
            }
            Toggle("柔和显示", isOn: $settings.dimImages)
            Button(settings.einkMode.enabled ? "关闭墨水模式" : "开启墨水模式") {
                settings.einkMode = settings.einkMode.enabled ? .off : .on
            }
            if !isOffline {
                Button("下载本章", systemImage: "arrow.down.circle") { scheduleDownload() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("阅读设置")
    }

    private var readerTransport: some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                Text(doublePage ? "\(spreadLayout.start(for: currentPage) + 1)–\(min(spreadLayout.start(for: currentPage) + 2, pages.count))" : "\(currentPage + 1)")
                    .monospacedDigit().frame(minWidth: 24)
                Slider(value: Binding(get: { Double(currentPage) }, set: { move(to: Int($0.rounded())) }),
                       in: 0...Double(max(1, pages.count - 1)), step: 1)
                    .disabled(pages.count < 2)
                    .tint(settings.einkMode.enabled ? .black : theme.accent)
                    .accessibilityLabel("阅读页码")
                    .accessibilityValue("第 \(currentPage + 1) 页，共 \(pages.count) 页")
                Text("\(pages.count)").monospacedDigit()
            }
            .font(.caption.weight(.medium))

            HStack(spacing: 12) {
                Button { move(to: spreadLayout.previous(from: currentPage)) } label: {
                    Image(systemName: settings.readingDirection == .right ? "chevron.left" : "chevron.right").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(spreadLayout.start(for: currentPage) == 0)
                .accessibilityLabel("上一页")
                Spacer(minLength: 0)
                chapterMenu
                Spacer(minLength: 0)
                Button { move(to: spreadLayout.next(from: currentPage)) } label: {
                    Image(systemName: settings.readingDirection == .right ? "chevron.right" : "chevron.left").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(spreadLayout.next(from: currentPage) == spreadLayout.start(for: currentPage))
                .accessibilityLabel("下一页")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .modifier(ReaderChromeSurface(ink: settings.einkMode.enabled, cornerRadius: 28))
    }

    @MainActor private func loadPages() async {
        let target = currentChapter
        let id = UUID()
        pageRequestID = id
        loading = true; error = nil
        defer { if pageRequestID == id { loading = false } }
        do {
            let loadedPages: [ComicPage]
            if let offline = downloads.items.first(where: { $0.id == target.id }), !offline.pages.isEmpty {
                loadedPages = offline.pages
            } else {
                loadedPages = try await KomiicAPI(mode: readingContentMode ?? settings.contentMode).pages(chapterID: target.id)
            }
            try Task.checkCancellation()
            guard pageRequestID == id, currentChapter.id == target.id else { return }
            pages = loadedPages
            currentPage = min(max(0, requestedPage ?? initialPage), max(0, pages.count - 1))
            scrollRequestID = UUID()
            saveProgress()
            if settings.loadingMode == .download && !isOffline { scheduleDownload() }
        } catch is CancellationError {
        } catch { if pageRequestID == id { self.error = error.localizedDescription } }
    }
    private func move(to page: Int) {
        resetZoom()
        currentPage = min(max(0, page), max(0, pages.count - 1))
        scrollRequestID = UUID()
        saveProgress()
    }
    private func saveProgress() {
        guard !pages.isEmpty else { return }
        downloads.prioritizeReading(chapterID: currentChapter.id, pageIndex: currentPage)
        library.recordProgress(comic: comic, chapter: currentChapter, page: currentPage, totalPages: pages.count, mode: readingContentMode)
    }
    private func toggleControls() {
        if settings.einkMode.enabled || reduceMotion { controls.toggle() }
        else { withAnimation(.easeInOut(duration: 0.18)) { controls.toggle() } }
    }
    private func scheduleDownload() {
        let baseURL = KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL
        let target = currentChapter
        let chapterPages = pages
        Task { await downloads.download(comic: comic, chapter: target, pages: chapterPages, baseURL: baseURL) }
    }
}

/// Reading chrome uses the system glass surface; electronic ink mode stays opaque.
private struct ReaderChromeSurface: ViewModifier {
    let ink: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if ink {
            content
                .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.black.opacity(0.18), lineWidth: 1))
        } else {
            content.komiicGlass(cornerRadius: cornerRadius)
        }
    }
}

private struct ReaderPageImage: View {
    let page: ComicPage
    let chapterID: String
    let baseURL: URL
    let allowNetwork: Bool
    var shouldLoad = true
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = 0
    private var ratio: CGFloat { page.width > 0 && page.height > 0 ? CGFloat(page.width) / CGFloat(page.height) : 0.7 }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .grayscale(settings.einkMode.enabled ? 1 : 0)
                    .brightness(settings.dimImages ? -0.16 : 0)
            } else {
                Rectangle().fill(settings.einkMode.enabled ? Color(white: 0.96) : Color(white: 0.10))
                if let error {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title2)
                        Text(error).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 280)
                        Button("重新载入这一页") { retry += 1 }.buttonStyle(.bordered)
                    }.foregroundStyle(settings.einkMode.enabled ? .black : .white).padding(20)
                } else {
                    ProgressView().tint(settings.einkMode.enabled ? .black : .white)
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .accessibilityLabel("漫画页面")
        .accessibilityHint("双指放大，收拢还原至原始比例")
        .task(id: "\(page.id)-\(retry)-\(shouldLoad)") {
            guard shouldLoad, image == nil else { return }
            do {
                error = nil
                let data = try await downloads.imageData(page: page, chapterID: chapterID, baseURL: baseURL,
                                                        cachePolicy: settings.cachePolicy, allowNetwork: allowNetwork)
                try Task.checkCancellation()
                let decoded = try await ImageDecoding.image(from: data)
                try Task.checkCancellation()
                image = decoded
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch { self.error = error.localizedDescription }
        }
    }
}
