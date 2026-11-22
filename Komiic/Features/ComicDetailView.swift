import SwiftUI

struct ComicDetailView: View {
    let comic: Comic
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @State private var detail: Comic?
    @State private var chapters: [Chapter] = []
    @State private var loading = true
    @State private var error: String?
    @State private var launch: ReaderLaunch?
    @State private var addingToShelf = false
    @State private var ascending = true
    @State private var scheduling: Set<String> = []
    @State private var retry = 0
    private var displayedComic: Comic { detail ?? comic }
    private var displayedChapters: [Chapter] { ascending ? chapters : Array(chapters.reversed()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    RemoteImage(url: displayedComic.imageUrl, aspectRatio: 0.72)
                        .frame(width: 128).clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayedComic.title).font(.title2.bold())
                        Text(displayedComic.authors.isEmpty ? "漫画作品" : displayedComic.authors.joined(separator: " / "))
                            .font(.subheadline).foregroundStyle(.secondary)
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
                LazyVStack(spacing: 0) {
                    ForEach(displayedChapters) { chapter in
                        HStack(spacing: 12) {
                            Button {
                                let progress = library.progress(for: comic.id)
                                launch = ReaderLaunch(comic: displayedComic, chapter: chapter,
                                                      page: progress?.chapter.id == chapter.id ? progress?.page ?? 0 : 0)
                            } label: {
                                HStack {
                                    Image(systemName: downloads.isDownloaded(chapterID: chapter.id) ? "checkmark.circle.fill" : "doc.text")
                                        .foregroundStyle(KomiicTheme.accent).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(chapter.displayTitle).font(.subheadline).foregroundStyle(.primary)
                                        Text("\(chapter.size) 页").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { scheduleDownload(chapter) } label: {
                                if scheduling.contains(chapter.id) { ProgressView().controlSize(.small) }
                                else { Image(systemName: downloads.isDownloaded(chapterID: chapter.id) ? "checkmark" : "arrow.down.circle") }
                            }
                            .frame(width: 40, height: 44)
                            .disabled(scheduling.contains(chapter.id) || downloads.isDownloaded(chapterID: chapter.id))
                            .accessibilityLabel("下载\(chapter.displayTitle)")
                        }.padding(.vertical, 8)
                        Divider().opacity(0.5)
                    }
                }
                Link(destination: URL(string: "https://komiic.cc/comic/\(comic.id)")!) {
                    Label("在 Komiic 官网查看", systemImage: "arrow.up.right.square").font(.caption)
                }.padding(.top, 8)
            }.padding(20).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("漫画详情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            Menu {
                ShareLink(item: URL(string: "https://komiic.cc/comic/\(comic.id)")!)
                Button("屏蔽漫画", systemImage: "eye.slash", role: .destructive) { library.toggleBlocked(comic) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .task(id: retry) { await load() }
        .fullScreenCover(item: $launch) { item in ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page) }
        .sheet(isPresented: $addingToShelf) { AddToShelfView(comic: displayedComic).presentationDetents([.medium, .large]) }
    }

    @MainActor private func load() async {
        loading = true; error = nil
        if chapters.isEmpty { chapters = downloads.items.filter { $0.comic.id == comic.id }.map(\.chapter) }
        do {
            async let comicResult = KomiicAPI().comic(id: comic.id)
            async let chapterResult = KomiicAPI().chapters(comicID: comic.id)
            let results = try await (comicResult, chapterResult)
            try Task.checkCancellation()
            detail = results.0; chapters = results.1
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func startReading() {
        if let progress = library.progress(for: comic.id) {
            launch = ReaderLaunch(comic: displayedComic, chapter: progress.chapter, page: progress.page)
        } else if let chapter = chapters.first {
            launch = ReaderLaunch(comic: displayedComic, chapter: chapter)
        }
    }
    private func scheduleDownload(_ chapter: Chapter) {
        scheduling.insert(chapter.id)
        Task {
            do {
                let pages = try await KomiicAPI().pages(chapterID: chapter.id)
                await downloads.download(comic: displayedComic, chapter: chapter, pages: pages, baseURL: URL(string: "https://komiic.cc")!)
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
