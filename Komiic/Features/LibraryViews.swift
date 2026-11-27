import SwiftUI

struct ReaderLaunch: Identifiable {
    let comic: Comic
    let chapter: Chapter
    var page = 0
    var id: String { "\(chapter.id)-\(page)" }
}

struct FavoritesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var selected = 0
    private var comics: [Comic] {
        library.favorites.filter { comic in
            guard !library.isBlocked(comic), !settings.shouldHide(comic) else { return false }
            let progress = library.progress(for: comic.id)
            switch selected {
            case 1: return progress == nil
            case 2: return progress != nil && progress?.isFinished == false
            case 3: return progress?.isFinished == true
            default: return true
            }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: "我的喜爱", subtitle: "\(library.favorites.count) 部漫画")
                Picker("阅读状态", selection: $selected) {
                    Text("全部").tag(0); Text("未读").tag(1); Text("在读").tag(2); Text("本章已读").tag(3)
                }.pickerStyle(.segmented)
                if comics.isEmpty {
                    EmptyState(symbol: "heart", title: "收藏喜欢的故事", message: "在漫画详情中轻点爱心，即可在这里找到。")
                } else {
                    ComicGrid(comics: comics)
                }
            }.padding(16)
        }
        .refreshable { await library.refreshOfficialLibrary() }
    }
}

struct BookmarksView: View {
    @Environment(\.openComicDirectory) private var openComicDirectory
    @Environment(\.komiicTheme) private var theme
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var launch: ReaderLaunch?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "阅读书签", subtitle: "\(library.bookmarks.count) 个位置")
                if library.bookmarks.isEmpty {
                    EmptyState(symbol: "bookmark", title: "留住想再看的那一页", message: "阅读时轻点书签按钮，保存当前页。")
                }
                ForEach(library.bookmarks.filter { !settings.shouldHide($0.comic) && !library.isBlocked($0.comic) }) { bookmark in
                    ComicActivation(comic: bookmark.comic, action: {
                        launch = ReaderLaunch(comic: bookmark.comic, chapter: bookmark.chapter, page: bookmark.page)
                    }) {
                        HStack(spacing: 14) {
                            ComicCover(comic: bookmark.comic).frame(width: 58, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.comic.title).font(.subheadline.bold()).lineLimit(2)
                                Text("\(bookmark.chapter.displayTitle) · 第 \(bookmark.page + 1) 页")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(bookmark.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "bookmark.fill").foregroundStyle(theme.accent)
                        }.padding(13).komiicCard()
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("删除书签", role: .destructive) { library.removeBookmark(id: bookmark.id) }
                    }
                }
            }.padding(16)
        }
        .fullScreenCover(item: $launch) { item in
            ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page, onReturnToDirectory: openComicDirectory)
        }
    }
}

struct ShelvesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    SectionHeading(title: "我的书柜", subtitle: "\(library.shelves.count) 个")
                    Button { name = ""; creating = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                        .accessibilityLabel("创建书柜")
                }
                Text("把喜欢的漫画，整理成自己的小小书房。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let message = library.lastError ?? library.officialSyncError {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if library.syncingOfficial { ProgressView().frame(maxWidth: .infinity) }
                if library.shelves.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "创建第一个书柜", message: "按题材、心情或阅读计划整理漫画。",
                               actionTitle: "创建书柜", action: { name = ""; creating = true })
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 18) {
                    ForEach(library.shelves) { shelf in
                        NavigationLink(value: BookshelfRoute(id: shelf.id)) {
                            VStack(alignment: .leading, spacing: 12) {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                                    ForEach(0..<4) { index in
                                        let visible = shelf.comics.filter { !settings.shouldHide($0) && !library.isBlocked($0) }
                                        if index < visible.count {
                                            ComicCover(comic: visible[index], aspectRatio: 0.76)
                                        } else {
                                            RemoteImage(url: nil, aspectRatio: 0.76)
                                        }
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 9))
                                Text(shelf.name).font(.headline).lineLimit(1)
                                Text("\(shelf.comics.count) 本漫画").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).komiicCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .task(id: library.activeMode) { await library.refreshOfficialLibrary(force: false) }
        .refreshable { await library.refreshOfficialLibrary() }
        .alert("创建书柜", isPresented: $creating) {
            TextField("书柜名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("创建") { library.createShelf(name: name) }
        } message: { Text("给这个书柜取一个名字。") }
    }
}

struct ShelfDetailView: View {
    let shelfID: UUID
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.komiicTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var rename = false
    @State private var deletion = false
    @State private var name = ""
    private var shelf: Bookshelf? { library.shelves.first { $0.id == shelfID } }

    var body: some View {
        ScrollView {
            if let shelf {
                if shelf.comics.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "书柜还空着", message: "在漫画详情中选择「加入书柜」，开始收集。")
                } else {
                    ComicGridLayout {
                        ForEach(shelf.comics.filter { !settings.shouldHide($0) && !library.isBlocked($0) }) { comic in
                            ComicActivation(comic: comic) { ComicCard(comic: comic) }.buttonStyle(.plain)
                                .contextMenu {
                                    RemoveRecentReadingButton(comicID: comic.id)
                                    Button("移出书柜", role: .destructive) { library.removeFromShelf(comicID: comic.id, shelfID: shelfID) }
                                }
                        }
                    }.padding(14)
                }
            }
        }
        .background(theme.canvas)
        .navigationTitle(shelf?.name ?? "书柜")
        .refreshable { await library.refreshOfficialLibrary() }
        .toolbar {
            Menu {
                Button("重命名", systemImage: "pencil") { name = shelf?.name ?? ""; rename = true }
                Button("删除书柜", systemImage: "trash", role: .destructive) { deletion = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .alert("重命名书柜", isPresented: $rename) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") { library.renameShelf(id: shelfID, name: name) }
        }
        .confirmationDialog("删除这个书柜？漫画和下载文件会保留。", isPresented: $deletion, titleVisibility: .visible) {
            Button("删除书柜", role: .destructive) { library.deleteShelf(id: shelfID); dismiss() }
        }
    }
}

struct HistoryView: View {
    let filter: ContentFilter
    let active: Bool
    let headerInset: CGFloat
    let onCollapse: (Bool) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var ratings: [String: Int] = [:]
    @State private var checkedRatingIDs: Set<String> = []
    @State private var loadingRatings = false
    @State private var refresh = 0

    private struct RatingRequest: Equatable {
        let comicIDs: [String]
        let refresh: Int
    }

    private var recentReading: [ReadingProgress] {
        library.recentReading.filter { !settings.shouldHide($0.comic) && !library.isBlocked($0.comic) }
    }

    var body: some View {
        let recent = recentReading
        let history = recent.compactMap { entry -> ReadingProgress? in
            var rated = entry
            rated.comic.sexyLevel = entry.comic.sexyLevel ?? ratings[entry.id]
            return filter.matches(sexyLevel: rated.comic.sexyLevel) ? rated : nil
        }
        let comicIDs = active && filter != .all ? recent.filter { $0.comic.sexyLevel == nil }.map(\.id) : []
        CatalogScrollView(headerInset: headerInset, onCollapse: onCollapse) {
            VStack(spacing: 18) {
                if recent.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "故事，从这里继续", message: "阅读漫画后，这里会自动记录你的进度。")
                } else if history.isEmpty && !loadingRatings {
                    EmptyState(symbol: "line.3.horizontal.decrease", title: "该分级暂无阅读记录",
                               message: "可以调整筛选，或下拉刷新分级。")
                } else {
                    ComicGridLayout {
                        ForEach(history) { progress in
                            ComicActivation(comic: progress.comic) {
                                ComicCard(comic: progress.comic, readingProgress: progress)
                            }
                            .contextMenu { ComicContextMenu(comic: progress.comic) }
                        }
                    }
                    if filter != .all && loadingRatings {
                        ProgressView("正在查询分级…").font(.caption).padding(16)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 1_400)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await library.refreshOfficialLibrary()
            checkedRatingIDs = Set(ratings.keys)
            refresh += 1
        }
        .task(id: RatingRequest(comicIDs: comicIDs, refresh: refresh)) {
            await loadRatings(for: comicIDs)
        }
    }

    private func loadRatings(for ids: [String]) async {
        let pending = ids.filter { !checkedRatingIDs.contains($0) }
        loadingRatings = !pending.isEmpty
        defer { if !Task.isCancelled { loadingRatings = false } }
        let api = KomiicAPI(mode: settings.contentMode)
        let batchSize = 12
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            do {
                try Task.checkCancellation()
                let result = try await api.contentRatings(comicIDs: batch)
                try Task.checkCancellation()
                ratings.merge(result) { _, latest in latest }
                checkedRatingIDs.formUnion(batch)
            } catch { return }
        }
    }
}

extension Chapter {
    var displayTitle: String {
        if !title.isEmpty { return title }
        return type.uppercased() == "BOOK" ? "第 \(serial) 卷" : "第 \(serial) 话"
    }
}
