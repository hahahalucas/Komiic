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
                            Image(systemName: "bookmark.fill").foregroundStyle(KomiicTheme.accent)
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
                        NavigationLink { ShelfDetailView(shelfID: shelf.id) } label: {
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

private struct ShelfDetailView: View {
    let shelfID: UUID
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 170), spacing: 10)], spacing: 16) {
                        ForEach(shelf.comics.filter { !settings.shouldHide($0) && !library.isBlocked($0) }) { comic in
                            ComicActivation(comic: comic) { ComicCard(comic: comic) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("移出书柜", role: .destructive) { library.removeFromShelf(comicID: comic.id, shelfID: shelfID) }
                                }
                        }
                    }.padding(14)
                }
            }
        }
        .background(KomiicTheme.canvas)
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
    @Environment(\.openComicDirectory) private var openComicDirectory
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var launch: ReaderLaunch?
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if library.history.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "故事，从这里继续", message: "阅读漫画后，这里会自动记录你的进度。")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                    ForEach(library.history.filter { !settings.shouldHide($0.comic) && !library.isBlocked($0.comic) }) { progress in
                        ComicActivation(comic: progress.comic, action: {
                            launch = ReaderLaunch(comic: progress.comic, chapter: progress.chapter, page: progress.page)
                        }) {
                            ComicCard(comic: progress.comic, progressLabel: "第 \(progress.page + 1) 页")
                                .overlay(alignment: .bottom) {
                                    if progress.totalPages > 0 {
                                        ProgressView(value: progress.fraction).tint(KomiicTheme.accent)
                                    }
                                }
                        }
                        .contextMenu { ComicContextMenu(comic: progress.comic) }
                    }
                }
            }.padding(16)
        }
        .refreshable { await library.refreshOfficialLibrary() }
        .fullScreenCover(item: $launch) { item in
            ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page, onReturnToDirectory: openComicDirectory)
        }
    }
}

extension Chapter {
    var displayTitle: String {
        if !title.isEmpty { return title }
        return type.uppercased() == "BOOK" ? "第 \(serial) 卷" : "第 \(serial) 话"
    }
}
