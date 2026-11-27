import SwiftUI
import UIKit

struct ReaderView: View {
    let comic: Comic
    let chapter: Chapter
    var initialPage = 0
    var chapterDirectory: [Chapter] = []
    let onClose: (Bool) -> Void
    let onPositionChange: (Chapter, Int) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.komiicTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var selectedChapter: Chapter?
    @State private var directory: [Chapter] = []
    @State private var directoryLoaded = false
    @State private var directoryError: String?
    @State private var directoryRequest: Task<Void, Never>?
    @State private var chapterAdvance: Task<Void, Never>?
    @State private var showingChapterMenu = false
    @State private var requestedPage: Int?
    @State private var pageRequestID = UUID()
    @State private var scrollRequestID = UUID()
    @State private var zoomResetID = UUID()
    private var currentChapter: Chapter {
        let selected = selectedChapter ?? chapter
        return directory.first { $0.id == selected.id } ?? selected
    }
    private var isOffline: Bool { downloads.isDownloaded(chapterID: currentChapter.id) }
    private var nextChapter: Chapter? { ReaderChapterNavigation.next(directory, current: currentChapter) }
    private var foreground: Color { settings.einkMode.enabled ? .black : .white }
    private var chapterUnit: String {
        switch currentChapter.type {
        case "book": "卷"
        case "short": "篇"
        default: "话"
        }
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
                let landscapeFrame = landscapeViewport(safe: safeGeometry, expanded: geometry)
                let viewportSize = landscapeFrame?.size ?? geometry.size
                let layout = ReaderSpreadLayout(pageCount: pages.count, doublePage: viewportSize.width > viewportSize.height,
                                                direction: settings.readingDirection)
                ZStack {
                    (settings.einkMode.enabled ? Color.white : Color.black).ignoresSafeArea()
                    if loading {
                        ProgressView("正在载入章节…").tint(foreground).foregroundStyle(foreground)
                    } else if let error {
                        VStack(spacing: 18) {
                            EmptyState(symbol: "wifi.exclamationmark", title: "暂时无法阅读", message: error,
                                       actionTitle: "重试", action: { retry += 1 })
                            Button("返回") { onClose(false) }
                        }.foregroundStyle(foreground)
                    } else if pages.isEmpty {
                        EmptyState(symbol: "doc", title: "本章暂无页面", message: "可以稍后重试，或在官网查看。",
                                   actionTitle: "返回", action: { onClose(false) }).foregroundStyle(foreground)
                    } else {
                        Group {
                            if layout.doublePage {
                                let frame = landscapeFrame ?? CGRect(origin: .zero, size: viewportSize)
                                landscapeSpreadPager(layout: layout, sizing: landscapeFrame == nil ? nil : ipadLandscapeSizing)
                                    .frame(width: frame.width, height: frame.height)
                                    .ignoresSafeArea(.container)
                                    .position(x: frame.midX, y: frame.midY)
                            } else {
                                readerCanvas().onTapGesture { toggleControls() }
                            }
                        }
                        .overlay(alignment: .top) {
                            if controls {
                                readerHeader(offersLandscapeSizing: landscapeFrame != nil)
                                    .padding(.top, ReaderChromePlacement.topPadding(safeAreaTop: safeGeometry.safeAreaInsets.top,
                                        isPhone: UIDevice.current.userInterfaceIdiom == .phone))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if controls {
                                readerTransport(layout: layout)
                                    .padding(.bottom, 12 + geometry.safeAreaInsets.bottom)
                            }
                        }
                    }
                }
                .statusBarHidden(true)
                .preferredColorScheme(settings.einkMode.enabled ? .light : .dark)
                .onChange(of: viewportSize) { _, _ in resetZoom() }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .accessibilityAction(.escape) { onClose(false) }
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
            directoryRequest?.cancel()
            chapterAdvance?.cancel()
            saveProgress()
            if settings.cachePolicy == .afterReading { downloads.clearCache(chapterID: currentChapter.id) }
        }
        .onChange(of: settings.readingDirection) { _, _ in resetZoom() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { chapterAdvance?.cancel() }
        }
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

    private func landscapeSpreadPager(layout: ReaderSpreadLayout, sizing: ReaderLandscapeSizing?) -> some View {
        let chapterID = currentChapter.id
        return ReaderSpreadPager(layout: layout, page: currentPage, requestID: scrollRequestID,
            canvas: { readerCanvas(spread: layout.slots(for: $0), landscapeSizing: sizing) },
            onPageChange: { recordVisiblePage($0, chapterID: chapterID) },
            onEndOfChapter: { requestNextChapter(from: chapterID) })
            .id(chapterID)
            .onTapGesture { toggleControls() }
    }

    private func resetZoom() {
        zoomResetID = UUID()
    }

    private func requestNextChapter(from chapterID: String) {
        guard scenePhase == .active, chapterAdvance == nil, currentChapter.id == chapterID, !loading else { return }
        chapterAdvance = Task { @MainActor in
            defer { chapterAdvance = nil }
            await loadDirectory()
            guard !Task.isCancelled, directoryLoaded, currentChapter.id == chapterID, !loading, !pages.isEmpty else { return }
            currentPage = pages.count - 1
            if let nextChapter { openChapter(nextChapter) }
            else {
                saveProgress()
                onClose(true)
            }
        }
    }

    private var chapterMenu: some View {
        Button { showingChapterMenu = true } label: {
            HStack(spacing: 5) {
                Text(currentChapter.displayTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
        }
        .accessibilityLabel("\(currentChapter.displayTitle)，选择附近五\(chapterUnit)")
        .accessibilityHint("打开后可上下滑动浏览完整目录")
        .popover(isPresented: $showingChapterMenu, arrowEdge: .bottom) {
            Group {
                if directoryLoaded {
                    ReaderChapterPicker(chapters: ReaderChapterNavigation.ordered(directory, current: currentChapter),
                        currentID: currentChapter.id,
                        firstVisibleID: ReaderChapterNavigation.nearby(directory, current: currentChapter).first?.id) { target in
                        showingChapterMenu = false
                        openChapter(target)
                    }
                } else if let directoryError {
                    Button(directoryError) { Task { await loadDirectory() } }
                        .padding(18)
                } else {
                    ProgressView("正在读取目录…").padding(18)
                }
            }
            .presentationCompactAdaptation(.popover)
        }
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
        onPositionChange(target, 0)
    }

    @MainActor private func loadDirectory() async {
        guard !directoryLoaded else { return }
        if chapterDirectory.contains(where: { $0.id == currentChapter.id }) {
            directory = chapterDirectory
            directoryLoaded = true
            return
        }
        if let directoryRequest {
            await directoryRequest.value
            return
        }
        directoryError = nil
        let request = Task { @MainActor in
            defer { directoryRequest = nil }
            do {
                let chapters = try await KomiicAPI(mode: readingContentMode ?? settings.contentMode).chapters(comicID: comic.id)
                try Task.checkCancellation()
                directory = chapters
                directoryLoaded = chapters.contains { $0.id == currentChapter.id }
                directoryError = directoryLoaded ? nil : "暂未找到当前章节，点击重试"
            } catch {
                if !Task.isCancelled { directoryError = "目录读取失败，点击重试" }
            }
        }
        directoryRequest = request
        await request.value
    }

    private func readerCanvas(spread: [Int?]? = nil, landscapeSizing: ReaderLandscapeSizing? = nil) -> ReaderCanvasView {
        let chapterID = currentChapter.id
        let scope = "\(chapterID):\(spread.map { String(describing: $0) } ?? "chapter")"
        return ReaderCanvasView(pages: pages, scopeID: scope, mode: spread.map { .spread($0) } ?? .chapter,
            landscapeSizing: landscapeSizing,
            targetPage: currentPage, requestID: scrollRequestID, resetID: zoomResetID,
            spacing: settings.einkMode.enabled ? 0 : 8,
            footer: spread == nil ? chapterFooter : "",
            onPageChange: { recordVisiblePage($0, chapterID: chapterID) },
            onEndOfChapter: { requestNextChapter(from: chapterID) },
            renderPage: { index in
                guard pages.indices.contains(index) else { return AnyView(EmptyView()) }
                return AnyView(ReaderPageImage(page: pages[index], chapterID: chapterID,
                    baseURL: KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL,
                    allowNetwork: !isOffline)
                    .id("\(chapterID):\(pages[index].id)")
                    .environmentObject(downloads).environmentObject(settings))
            })
    }

    private var chapterFooter: String {
        if directoryError != nil { return "目录读取失败，继续上拉重试" }
        guard directoryLoaded else { return "正在读取目录…" }
        return nextChapter == nil ? "继续上拉返回目录" : "继续上拉阅读下一\(chapterUnit)"
    }

    private func readerHeader(offersLandscapeSizing: Bool) -> some View {
        HStack(spacing: 8) {
            Button { onClose(false) } label: {
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
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
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

    private func readerTransport(layout: ReaderSpreadLayout) -> some View {
        let firstPage = layout.start(for: currentPage)
        let nextPage = layout.next(from: currentPage)
        return VStack(spacing: 5) {
            HStack(spacing: 12) {
                Text(layout.doublePage ? "\(firstPage + 1)–\(min(firstPage + 2, pages.count))" : "\(currentPage + 1)")
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
                Button { move(to: layout.previous(from: currentPage)) } label: {
                    Image(systemName: settings.readingDirection == .right ? "chevron.left" : "chevron.right").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(firstPage == 0)
                .accessibilityLabel("上一页")
                Spacer(minLength: 0)
                chapterMenu
                Spacer(minLength: 0)
                Button { move(to: nextPage) } label: {
                    Image(systemName: settings.readingDirection == .right ? "chevron.right" : "chevron.left").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(nextPage == firstPage)
                .accessibilityLabel("下一页")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .modifier(ReaderChromeSurface(ink: settings.einkMode.enabled, cornerRadius: 28))
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .transition(.opacity)
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
    private func recordVisiblePage(_ page: Int, chapterID: String) {
        guard currentChapter.id == chapterID, pages.indices.contains(page), currentPage != page else { return }
        currentPage = page
        saveProgress()
    }
    private func saveProgress() {
        guard !pages.isEmpty else { return }
        downloads.prioritizeReading(chapterID: currentChapter.id, pageIndex: currentPage)
        library.recordProgress(comic: comic, chapter: currentChapter, page: currentPage, totalPages: pages.count, mode: readingContentMode)
        onPositionChange(currentChapter, currentPage)
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

private struct ReaderChapterPicker: View {
    let chapters: [Chapter]
    let currentID: String
    let onSelect: (Chapter) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 44
    @State private var position: String?

    init(chapters: [Chapter], currentID: String, firstVisibleID: String?, onSelect: @escaping (Chapter) -> Void) {
        self.chapters = chapters
        self.currentID = currentID
        self.onSelect = onSelect
        _position = State(initialValue: firstVisibleID)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(chapters) { chapter in
                    let selected = chapter.id == currentID
                    Button { onSelect(chapter) } label: {
                        HStack(spacing: 12) {
                            Text(chapter.displayTitle).lineLimit(1)
                            Spacer(minLength: 0)
                            if selected {
                                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                            }
                        }
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .frame(height: rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .id(chapter.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $position, anchor: .top)
        .frame(width: 256, height: rowHeight * CGFloat(min(5, chapters.count)))
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
        .task(id: "\(page.id)-\(retry)") {
            guard image == nil else { return }
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
