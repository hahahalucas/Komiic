import SwiftUI
import UIKit

struct ReaderView: View {
    let comic: Comic
    let chapter: Chapter
    var initialPage = 0
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pages: [ComicPage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var currentPage = 0
    @State private var scrollID: Int?
    @State private var controls = true
    @State private var retry = 0
    @State private var readingContentMode: ComicContentMode?
    private var isOffline: Bool { downloads.isDownloaded(chapterID: chapter.id) }
    private var foreground: Color { settings.einkMode.enabled ? .black : .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (settings.einkMode.enabled ? Color.white : Color.black).ignoresSafeArea()
                if loading {
                    ProgressView("���������½ڡ�").tint(foreground).foregroundStyle(foreground)
                } else if let error {
                    VStack(spacing: 18) {
                        EmptyState(symbol: "wifi.exclamationmark", title: "��ʱ�޷��Ķ�", message: error,
                                   actionTitle: "����", action: { retry += 1 })
                        Button("����") { dismiss() }
                    }.foregroundStyle(foreground)
                } else if pages.isEmpty {
                    EmptyState(symbol: "doc", title: "��������ҳ��", message: "�����Ժ����ԣ����ڹ����鿴��",
                               actionTitle: "����", action: { dismiss() }).foregroundStyle(foreground)
                } else {
                    if settings.readingMode == .scroll {
                        ScrollView {
                            LazyVStack(spacing: settings.einkMode.enabled ? 0 : 8) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                                    ReaderPageImage(page: page, chapterID: chapter.id, baseURL: KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL, allowNetwork: !isOffline)
                                        .frame(width: min(geometry.size.width, 1_000))
                                        .id(index)
                                }
                            }
                            .scrollTargetLayout()
                            .frame(maxWidth: .infinity)
                        }
                        .scrollPosition(id: $scrollID, anchor: .top)
                        .onChange(of: scrollID) { _, value in
                            guard let value else { return }
                            currentPage = value
                            saveProgress()
                        }
                        .onTapGesture { toggleControls() }
                    } else {
                        TabView(selection: $currentPage) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                                ScrollView([.vertical, .horizontal]) {
                                    ReaderPageImage(page: page, chapterID: chapter.id, baseURL: KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL, allowNetwork: !isOffline, shouldLoad: index == currentPage)
                                        .frame(width: min(geometry.size.width, 1_000))
                                        .frame(minHeight: geometry.size.height)
                                        .frame(maxWidth: .infinity)
                                }
                                .tag(index)
                                .onTapGesture { toggleControls() }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .onChange(of: currentPage) { _, _ in saveProgress() }
                    }
                    if controls { readerControls }
                }
            }
            .statusBarHidden(!controls)
            .preferredColorScheme(settings.einkMode.enabled ? .light : .dark)
        }
        .task(id: retry) {
            if readingContentMode == nil { readingContentMode = settings.contentMode }
            await loadPages()
        }
        .onDisappear {
            saveProgress()
            if settings.cachePolicy == .afterReading { downloads.clearCache(chapterID: chapter.id) }
        }
        .onChange(of: settings.readingMode) { _, mode in
            if mode == .scroll { scrollID = currentPage }
        }
    }

    private var readerControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("�ر��Ķ���")
                VStack(alignment: .leading, spacing: 3) {
                    Text(comic.title).font(.subheadline.bold()).lineLimit(1)
                    Text(chapter.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                readerMenu
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
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var readerMenu: some View {
        Menu {
            Picker("�Ķ���ʽ", selection: $settings.readingMode) {
                ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("�����ʾ", isOn: $settings.dimImages)
            Button(settings.einkMode.enabled ? "�ر�īˮģʽ" : "����īˮģʽ") {
                settings.einkMode = settings.einkMode.enabled ? .off : .on
            }
            if !isOffline {
                Button("���ر���", systemImage: "arrow.down.circle") { scheduleDownload() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("�Ķ�����")
    }

    private var readerTransport: some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                Text("\(currentPage + 1)").monospacedDigit().frame(minWidth: 24)
                Slider(value: Binding(get: { Double(currentPage) }, set: { move(to: Int($0.rounded())) }),
                       in: 0...Double(max(1, pages.count - 1)), step: 1)
                    .disabled(pages.count < 2)
                    .tint(settings.einkMode.enabled ? .black : KomiicTheme.accent)
                    .accessibilityLabel("�Ķ�ҳ��")
                    .accessibilityValue("�� \(currentPage + 1) ҳ���� \(pages.count) ҳ")
                Text("\(pages.count)").monospacedDigit()
            }
            .font(.caption.weight(.medium))

            HStack(spacing: 12) {
                Button { move(to: currentPage - 1) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(currentPage == 0)
                .accessibilityLabel("��һҳ")
                Spacer(minLength: 0)
                Button { library.toggleBookmark(comic: comic, chapter: chapter, page: currentPage, mode: readingContentMode) } label: {
                    Label("��ǩ", systemImage: library.isBookmarked(chapterID: chapter.id, page: currentPage) ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                .accessibilityLabel(library.isBookmarked(chapterID: chapter.id, page: currentPage) ? "�Ƴ���ǰҳ��ǩ" : "���ӵ�ǰҳ��ǩ")
                Spacer(minLength: 0)
                Button { move(to: currentPage + 1) } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold))
                        .frame(width: 48, height: 44).contentShape(Circle())
                }
                .disabled(currentPage >= pages.count - 1)
                .accessibilityLabel("��һҳ")
            }

            Label(isOffline ? "�����Ķ�" : "�����Ķ� �� �Զ�����", systemImage: isOffline ? "checkmark.circle" : "network")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .modifier(ReaderChromeSurface(ink: settings.einkMode.enabled, cornerRadius: 28))
    }

    @MainActor private func loadPages() async {
        loading = true; error = nil
        do {
            if let offline = downloads.items.first(where: { $0.id == chapter.id }), !offline.pages.isEmpty {
                pages = offline.pages
            } else {
                pages = try await KomiicAPI(mode: readingContentMode ?? settings.contentMode).pages(chapterID: chapter.id)
            }
            try Task.checkCancellation()
            currentPage = min(max(0, initialPage), max(0, pages.count - 1))
            scrollID = currentPage
            saveProgress()
            if settings.loadingMode == .download && !isOffline { scheduleDownload() }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func move(to page: Int) {
        currentPage = min(max(0, page), max(0, pages.count - 1))
        scrollID = currentPage
        saveProgress()
    }
    private func saveProgress() {
        guard !pages.isEmpty else { return }
        library.recordProgress(comic: comic, chapter: chapter, page: currentPage, totalPages: pages.count, mode: readingContentMode)
    }
    private func toggleControls() {
        if settings.einkMode.enabled || reduceMotion { controls.toggle() }
        else { withAnimation(.easeInOut(duration: 0.18)) { controls.toggle() } }
    }
    private func scheduleDownload() {
        let baseURL = KomiicAPI(mode: readingContentMode ?? settings.contentMode).baseURL
        Task { await downloads.download(comic: comic, chapter: chapter, pages: pages, baseURL: baseURL) }
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
                        Button("����������һҳ") { retry += 1 }.buttonStyle(.bordered)
                    }.foregroundStyle(settings.einkMode.enabled ? .black : .white).padding(20)
                } else {
                    ProgressView().tint(settings.einkMode.enabled ? .black : .white)
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .accessibilityLabel("����ҳ��")
        .task(id: "\(page.id)-\(retry)-\(shouldLoad)") {
            guard shouldLoad, image == nil else { return }
            do {
                error = nil
                let data = try await downloads.imageData(page: page, chapterID: chapterID, baseURL: baseURL,
                                                        cachePolicy: settings.cachePolicy, allowNetwork: allowNetwork)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                image = decoded
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch { self.error = error.localizedDescription }
        }
    }
}
