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
                SectionHeading(title: "�ҵ�ϲ��", subtitle: "\(library.favorites.count) ������")
                Picker("�Ķ�״̬", selection: $selected) {
                    Text("ȫ��").tag(0); Text("δ��").tag(1); Text("�ڶ�").tag(2); Text("�����Ѷ�").tag(3)
                }.pickerStyle(.segmented)
                if comics.isEmpty {
                    EmptyState(symbol: "heart", title: "�ղ�ϲ���Ĺ���", message: "��������������㰮�ģ������������ҵ���")
                } else {
                    ComicGrid(comics: comics)
                }
            }.padding(16)
        }
        .refreshable { await library.refreshOfficialLibrary() }
    }
}

struct BookmarksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var launch: ReaderLaunch?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "�Ķ���ǩ", subtitle: "\(library.bookmarks.count) ��λ��")
                if library.bookmarks.isEmpty {
                    EmptyState(symbol: "bookmark", title: "��ס���ٿ�����һҳ", message: "�Ķ�ʱ�����ǩ��ť�����浱ǰҳ��")
                }
                ForEach(library.bookmarks.filter { !settings.shouldHide($0.comic) && !library.isBlocked($0.comic) }) { bookmark in
                    Button { launch = ReaderLaunch(comic: bookmark.comic, chapter: bookmark.chapter, page: bookmark.page) } label: {
                        HStack(spacing: 14) {
                            ComicCover(comic: bookmark.comic).frame(width: 58, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.comic.title).font(.subheadline.bold()).lineLimit(2)
                                Text("\(bookmark.chapter.displayTitle) �� �� \(bookmark.page + 1) ҳ")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(bookmark.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "bookmark.fill").foregroundStyle(KomiicTheme.accent)
                        }.padding(13).komiicCard()
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("ɾ����ǩ", role: .destructive) { library.removeBookmark(id: bookmark.id) }
                    }
                }
            }.padding(16)
        }
        .fullScreenCover(item: $launch) { item in ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page) }
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
                    SectionHeading(title: "�ҵ����", subtitle: "\(library.shelves.count) ��")
                    Button { name = ""; creating = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                        .accessibilityLabel("�������")
                }
                Text("��ϲ�����������������Լ���СС�鷿��")
                    .font(.subheadline).foregroundStyle(.secondary)
                if library.shelves.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "������һ�����", message: "����ġ�������Ķ��ƻ�����������",
                               actionTitle: "�������", action: { name = ""; creating = true })
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
                                Text("\(shelf.comics.count) ������").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).komiicCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }
        .alert("�������", isPresented: $creating) {
            TextField("�������", text: $name)
            Button("ȡ��", role: .cancel) {}
            Button("����") { library.createShelf(name: name) }
        } message: { Text("��������ȡһ�����֡�") }
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
                    EmptyState(symbol: "books.vertical", title: "��񻹿���", message: "������������ѡ�񡸼�����񡹣���ʼ�ռ���")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 170), spacing: 10)], spacing: 16) {
                        ForEach(shelf.comics.filter { !settings.shouldHide($0) && !library.isBlocked($0) }) { comic in
                            NavigationLink(value: comic) { ComicCard(comic: comic) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("�Ƴ����", role: .destructive) { library.removeFromShelf(comicID: comic.id, shelfID: shelfID) }
                                }
                        }
                    }.padding(14)
                }
            }
        }
        .background(KomiicTheme.canvas)
        .navigationTitle(shelf?.name ?? "���")
        .toolbar {
            Menu {
                Button("������", systemImage: "pencil") { name = shelf?.name ?? ""; rename = true }
                Button("ɾ�����", systemImage: "trash", role: .destructive) { deletion = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .alert("���������", isPresented: $rename) {
            TextField("����", text: $name)
            Button("ȡ��", role: .cancel) {}
            Button("����") { library.renameShelf(id: shelfID, name: name) }
        }
        .confirmationDialog("ɾ�������������������ļ��ᱣ����", isPresented: $deletion, titleVisibility: .visible) {
            Button("ɾ�����", role: .destructive) { library.deleteShelf(id: shelfID); dismiss() }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var launch: ReaderLaunch?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if library.history.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "���£����������", message: "�Ķ�������������Զ���¼��Ľ��ȡ�")
                }
                ForEach(library.history.filter { !settings.shouldHide($0.comic) && !library.isBlocked($0.comic) }) { progress in
                    Button { launch = ReaderLaunch(comic: progress.comic, chapter: progress.chapter, page: progress.page) } label: {
                        HStack(spacing: 14) {
                            ComicCover(comic: progress.comic).frame(width: 64, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(progress.comic.title).font(.subheadline.bold()).lineLimit(2)
                                Text(progress.totalPages > 0
                                     ? "\(progress.chapter.displayTitle) �� \(progress.page + 1)/\(progress.totalPages) ҳ"
                                     : "\(progress.chapter.displayTitle) �� �� \(progress.page + 1) ҳ")
                                    .font(.caption).foregroundStyle(.secondary)
                                if progress.totalPages > 0 { ProgressView(value: progress.fraction).tint(KomiicTheme.accent) }
                                Text(progress.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(13).komiicCard()
                    }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .refreshable { await library.refreshOfficialLibrary() }
        .fullScreenCover(item: $launch) { item in ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page) }
    }
}

extension Chapter {
    var displayTitle: String {
        if !title.isEmpty { return title }
        return type.uppercased() == "BOOK" ? "�� \(serial) ��" : "�� \(serial) ��"
    }
}
