import SwiftUI

struct ComicDetailView: View {
    let comic: Comic
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.openAuthor) private var openAuthor
    @State private var detail: Comic?
    @State private var chapters: [Chapter] = []
    @State private var loading = true
    @State private var error: String?
    @State private var launch: ReaderLaunch?
    @State private var addingToShelf = false
    @State private var ascending = true
    @State private var scheduling: Set<String> = []
    @State private var retry = 0
    @State private var chapterType = "book"
    @State private var expandedTypes: Set<String> = []
    private var displayedComic: Comic { detail ?? comic }
    private var chapterTypes: [String] {
        let types = Set(chapters.map(\.type))
        return ["book", "chapter", "short"].filter { types.contains($0) }
            + types.subtracting(["book", "chapter", "short"]).sorted()
    }
    private var directoryItems: [ChapterDirectoryItem] {
        ChapterDirectory.items(chapters: chapters.filter { $0.type == chapterType },
                               readChapterIDs: library.readChapterIDs,
                               lastReadChapterID: library.progress(for: comic.id)?.chapter.id,
                               expanded: expandedTypes.contains(chapterType), ascending: ascending)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    ComicCover(comic: displayedComic)
                        .onTapGesture { settings.revealWarningCover(displayedComic) }
                        .frame(width: 128).clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayedComic.title).font(.title2.bold())
                        Text(authorLinks)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "komiic-author", let index = Int(url.lastPathComponent),
                                      displayedComic.authors.indices.contains(index) else { return .discarded }
                                let name = displayedComic.authors[index]
                                openAuthor(displayedComic.authorDetails.first { $0.name == name }
                                           ?? ComicAuthor(id: "", name: name))
                                return .handled
                            })
                        Text(displayedComic.displayStatus).font(.caption.weight(.semibold))
                            .foregroundStyle(KomiicTheme.accent).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(KomiicTheme.softBlue, in: Capsule())
                        HStack(spacing: 12) {
                            Label(compactCount(displayedComic.views), systemImage: "eye")
                            Label(compactCount(displayedComic.favoriteCount), systemImage: "heart")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Button { startReading() } label: {
                        Label(library.progress(for: comic.id) == nil ? "开始阅读" : "继续阅读", systemImage: "book")
                            .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.komiicActionStyle(prominent: true).disabled(chapters.isEmpty && library.progress(for: comic.id) == nil)
                    Button { library.toggleFavorite(displayedComic) } label: {
                        Image(systemName: library.isFavorite(comic) ? "heart.fill" : "heart").padding(.vertical, 7)
                    }.komiicActionStyle().accessibilityLabel(library.isFavorite(comic) ? "取消喜爱" : "加入喜爱")
                    Button { addingToShelf = true } label: { Image(systemName: "books.vertical").padding(.vertical, 7) }
                        .komiicActionStyle().accessibilityLabel("加入书柜")
                }
                if !displayedComic.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(displayedComic.categories, id: \.self) { category in
                                Text(category).font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(KomiicTheme.softBlue, in: Capsule()).foregroundStyle(KomiicTheme.accent)
                            }
                        }
                    }
                }
                if let description = displayedComic.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "故事简介")
                        Text(description).font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                    }
                }
                contentRating
                HStack {
                    SectionHeading(title: "章节目录", subtitle: "共 \(chapters.count) 章")
                    Button { ascending.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("切换章节排序")
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(20) }
                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                        Button("重新载入") { retry += 1 }.font(.subheadline)
                    }.padding(14).komiicCard()
                }
                if !chapterTypes.isEmpty {
                    Picker("卷与话", selection: $chapterType) {
                        ForEach(chapterTypes, id: \.self) { type in
                            Text(chapterTypeTitle(type)).tag(type)
                        }
                    }.pickerStyle(.segmented)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                    ForEach(directoryItems) { item in
                        switch item {
                        case .chapter(let chapter): chapterButton(chapter)
                        case .collapsed(let hidden):
                            Button { expandedTypes.insert(chapterType) } label: {
                                Image(systemName: "eye").font(.title3)
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .foregroundStyle(KomiicTheme.accent)
                                    .background(KomiicTheme.card, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(KomiicTheme.line, lineWidth: 1))
                            }.buttonStyle(.plain)
                                .accessibilityLabel("展开隐藏的 \(hidden.count) 个章节")
                        }
                    }
                }
                if expandedTypes.contains(chapterType) {
                    Button { expandedTypes.remove(chapterType) } label: {
                        Label("收起章节", systemImage: "eye.slash").font(.caption)
                    }
                }
                Link(destination: KomiicAPI(mode: settings.contentMode).baseURL.appendingPathComponent("comic/\(comic.id)")) {
                    Label("在 Komiic 官网查看", systemImage: "arrow.up.right.square").font(.caption)
                }.padding(.top, 8)
            }.padding(20).padding(.bottom, library.progress(for: comic.id) == nil ? 0 : 88)
                .frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("漫画详情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            Menu {
                ShareLink(item: KomiicAPI(mode: settings.contentMode).baseURL.appendingPathComponent("comic/\(comic.id)"))
                Button("屏蔽漫画", systemImage: "eye.slash", role: .destructive) { library.toggleBlocked(comic) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .task(id: retry) { await load() }
        .overlay(alignment: .bottomTrailing) {
            if let progress = library.progress(for: comic.id) {
                Button { startReading() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("继续阅读", systemImage: "book.fill").font(.subheadline.bold())
                        Text("\(progress.chapter.displayTitle) · 第 \(progress.page + 1) 页")
                            .font(.caption).lineLimit(1)
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                        .foregroundStyle(KomiicTheme.accent)
                        .komiicGlass(cornerRadius: 18, interactive: true)
                }.buttonStyle(.plain).padding(.trailing, 20).padding(.bottom, 10)
                    .accessibilityLabel("继续阅读，\(progress.chapter.displayTitle)，第 \(progress.page + 1) 页")
            }
        }
        .fullScreenCover(item: $launch, onDismiss: resetDirectory) { item in
            ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page, chapterDirectory: chapters)
        }
        .sheet(isPresented: $addingToShelf) { AddToShelfView(comic: displayedComic).presentationDetents([.medium, .large]) }
    }

    @MainActor private func load() async {
        loading = true; error = nil
        if chapters.isEmpty { chapters = downloads.items.filter { $0.comic.id == comic.id }.map(\.chapter) }
        do {
            let api = KomiicAPI(mode: settings.contentMode)
            async let comicResult = api.comic(id: comic.id)
            async let chapterResult = api.chapters(comicID: comic.id)
            let results = try await (comicResult, chapterResult)
            try Task.checkCancellation()
            detail = results.0; chapters = results.1
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
        loading = false
        resetDirectory()
    }
    private var authorLinks: AttributedString {
        guard !displayedComic.authors.isEmpty else { return AttributedString("漫画作品") }
        var result = AttributedString()
        for (index, name) in displayedComic.authors.enumerated() {
            if index > 0 { result += AttributedString(" / ") }
            var link = AttributedString(name)
            link.link = URL(string: "komiic-author://profile/\(index)")
            result += link
        }
        return result
    }
    private var contentRating: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "色情程度")
            if let level = displayedComic.sexyLevel {
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: index < min(max(level, 0), 5) ? "heart.fill" : "heart")
                            .font(.title3).foregroundStyle(.red)
                    }
                    Text(level == 0 ? "无" : "\(level) / 5").font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(level == 0 ? "色情程度：无" : "色情程度：\(level) 级，共 5 级")
                if let reason = displayedComic.sexyLevelReason, !reason.isEmpty {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                }
            } else {
                Text("暂无评级").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private func chapterTypeTitle(_ type: String) -> String {
        switch type {
        case "book": return "卷"
        case "chapter": return "话"
        case "short": return "短篇"
        default: return type
        }
    }
    private func resetDirectory() {
        expandedTypes = []
        if let last = library.progress(for: comic.id)?.chapter, chapterTypes.contains(last.type) {
            chapterType = last.type
        } else if !chapterTypes.contains(chapterType), let first = chapterTypes.first {
            chapterType = first
        }
    }
    private func chapterButton(_ chapter: Chapter) -> some View {
        let read = library.isChapterRead(chapter.id)
        return Button {
            let progress = library.progress(for: comic.id)
            launch = ReaderLaunch(comic: displayedComic, chapter: chapter,
                                  page: progress?.chapter.id == chapter.id ? progress?.page ?? 0 : 0)
        } label: {
            VStack(spacing: 5) {
                Text(chapter.serial.isEmpty ? chapter.displayTitle : chapter.serial)
                    .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(chapter.size) 页").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(read ? Color.secondary : KomiicTheme.accent)
                .background(read ? Color.primary.opacity(0.15) : KomiicTheme.card,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KomiicTheme.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if scheduling.contains(chapter.id) {
                        ProgressView().controlSize(.mini).padding(5)
                    } else if downloads.isDownloaded(chapterID: chapter.id) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(KomiicTheme.accent).padding(5)
                    }
                }
        }.buttonStyle(.plain)
            .accessibilityLabel("\(chapter.displayTitle)，\(chapter.size) 页，\(read ? "已读" : "未读")")
            .contextMenu {
                Button { scheduleDownload(chapter) } label: {
                    Label(downloads.isDownloaded(chapterID: chapter.id) ? "已下载" : "下载本章", systemImage: "arrow.down.circle")
                }.disabled(scheduling.contains(chapter.id) || downloads.isDownloaded(chapterID: chapter.id))
            }
    }
    private func startReading() {
        if let progress = library.progress(for: comic.id) {
            launch = ReaderLaunch(comic: displayedComic, chapter: progress.chapter, page: progress.page)
        } else if let chapter = chapters.first(where: { $0.type == chapterType }) ?? chapters.first {
            launch = ReaderLaunch(comic: displayedComic, chapter: chapter)
        }
    }
    private func scheduleDownload(_ chapter: Chapter) {
        scheduling.insert(chapter.id)
        Task {
            do {
                let api = KomiicAPI(mode: settings.contentMode)
                let pages = try await api.pages(chapterID: chapter.id)
                await downloads.download(comic: displayedComic, chapter: chapter, pages: pages, baseURL: api.baseURL)
            } catch { self.error = error.localizedDescription }
            scheduling.remove(chapter.id)
        }
    }
}

private struct AddToShelfView: View {
    let comic: Comic
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("选择书柜") {
                    ForEach(library.shelves) { shelf in
                        Button { library.addToShelf(comic, shelfID: shelf.id); dismiss() } label: {
                            Label(shelf.name, systemImage: "books.vertical")
                        }
                    }
                }
                Section("新建书柜") {
                    TextField("书柜名称", text: $name)
                    Button("创建并加入") {
                        if let shelf = library.createShelf(name: name) { library.addToShelf(comic, shelfID: shelf.id); dismiss() }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("加入书柜").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
