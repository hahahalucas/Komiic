import SwiftUI

private struct WebDestination: Identifiable {
    let path: String
    let title: String
    let mode: ComicContentMode
    var id: String { "\(mode.rawValue):\(path)" }
    var url: URL { URL(string: path, relativeTo: mode.baseURL)!.absoluteURL }
}

struct AccountView: View {
    var onOpenFavorites: (() -> Void)? = nil
    var onOpenBookmarks: (() -> Void)? = nil
    var onOpenShelves: (() -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @State private var website: WebDestination?
    @State private var profile: KomiicAccountProfile?
    @State private var connected = false
    @State private var loading = false
    @State private var error: String?
    @State private var signingOut = false
    @State private var requestID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileHeader
                if loading { ProgressView("���ڶ�ȡ�˺����ϡ�").frame(maxWidth: .infinity) }
                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("���¶�ȡ") { Task { await loadProfile() } }.font(.subheadline)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).komiicCard()
                }
                if let profile {
                    officialStats(profile)
                    if !profile.topCategories.isEmpty { categorySummary(profile.topCategories) }
                    collectionLinks(profile)
                    Button { openWebsite("/settings", title: "�˺�����") } label: {
                        Text("��������˺���Ϣ���뵽 Komiic �����趨���в�����")
                            .font(.caption).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                } else if !loading {
                    localSummary
                }
                if connected {
                    Button(role: .destructive) { signingOut = true } label: {
                        Label("�˳���¼", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).tint(.red).clipShape(Capsule())
                    .padding(.top, 10)
                }
            }
            .padding(18).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("�˺�").navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadProfile() }
        .task(id: settings.contentMode) { await loadProfile() }
        .sheet(item: $website) { destination in
            WebsiteView(url: destination.url, title: destination.title, onClose: {
                Task { await loadProfile() }
            })
        }
        .confirmationDialog("�˳��� App �е� Komiic �����Ự�������Ķ����ϻᱣ����", isPresented: $signingOut, titleVisibility: .visible) {
            Button("�˳���¼", role: .destructive) {
                requestID = UUID()
                profile = nil
                connected = false
                settings.cancelWarningSync()
                library.resetOfficialSession()
                Task {
                    await WebCookieBridge.clear()
                    await loadProfile()
                }
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(KomiicTheme.accent)
                if let url = profile?.profileImageURL {
                    RemoteImage(url: url).clipShape(Circle())
                } else if let profile {
                    Text(String(profile.username.prefix(2)).uppercased()).font(.title2.bold()).foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill").font(.title).foregroundStyle(.white)
                }
            }
            .frame(width: 76, height: 76).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile?.username ?? (connected ? "Komiic �˺�" : "��ӭ���� Komiic"))
                    .font(.title2.bold()).lineLimit(2)
                if let profile {
                    Text(profile.email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("������ \(String(profile.dateCreated.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(connected ? "���������¶�ȡ��������" : "��¼��鿴�˺����Ϻ��Ķ�ͳ��")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(connected ? "�򿪹����˺�" : "��¼ Komiic") {
                        openWebsite(connected ? "/profile" : "/login", title: "Komiic �˺�")
                    }.font(.subheadline.bold())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(KomiicTheme.softBlue, in: RoundedRectangle(cornerRadius: 20))
    }

    private func officialStats(_ profile: KomiicAccountProfile) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
            stat("�����Ѷ�", value: String(profile.readComicCount), symbol: "book.fill")
            stat("�½��Ѷ�", value: String(profile.readChapterCount), symbol: "book.pages")
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "photo").font(.title3).foregroundStyle(KomiicTheme.accent)
                Text("\(profile.imageReadCount)/\(profile.imageReadLimit)")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("ͼƬ��ȡ").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0, Double(profile.imageReadCount) / Double(max(1, profile.imageReadLimit)))))
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(resetDescription(at: profile.resetAt, now: context.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18).komiicCard()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "bubble.left").font(.title3).foregroundStyle(KomiicTheme.accent)
                Text(String(profile.commentCount)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("����").font(.caption).foregroundStyle(.secondary)
                Label(String(profile.commentLikes), systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18).komiicCard()
        }
    }

    private func stat(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(KomiicTheme.accent)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(18).komiicCard()
    }

    private func categorySummary(_ categories: [ProfileCategoryCount]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("��Ķ�����", systemImage: "square.grid.2x2").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(categories.prefix(5))) { category in
                    HStack(spacing: 6) {
                        Text(category.name).lineLimit(1)
                        Text(String(category.count)).fontWeight(.semibold)
                    }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 9)
                    .frame(maxWidth: .infinity).background(KomiicTheme.softBlue, in: Capsule())
                }
            }
        }
        .padding(18).komiicCard()
    }

    private func collectionLinks(_ profile: KomiicAccountProfile) -> some View {
        HStack(spacing: 9) {
            collectionButton("�ղ�", value: profile.favoriteCount, symbol: "heart.fill") {
                if let onOpenFavorites { onOpenFavorites() }
                else { openWebsite("/favorite", title: "�����ղ�") }
            }
            collectionButton("��ǩ", value: profile.bookmarkCount, symbol: "bookmark.fill") { openWebsite("/bookmarks", title: "������ǩ") }
            collectionButton("���", value: profile.folderCount, symbol: "folder.fill") { openWebsite("/folder", title: "�������") }
            collectionButton("׷�����", value: profile.followedFolderCount, symbol: "bookmark") { openWebsite("/folder?tab=followed", title: "׷�����") }
        }
    }

    private func collectionButton(_ title: String, value: Int, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(KomiicTheme.accent)
                Text(String(value)).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 98).padding(.vertical, 10).komiicCard()
        }.buttonStyle(.plain)
    }

    private var localSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "�����Ķ�", subtitle: settings.contentMode.title)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                stat("�����Ѷ�", value: String(library.readComicCount), symbol: "book.fill")
                stat("�½��Ѷ�", value: String(library.readChapterCount), symbol: "book.pages")
            }
            HStack(spacing: 10) {
                collectionButton("�ղ�", value: library.favorites.count, symbol: "heart.fill") { onOpenFavorites?() }
                collectionButton("��ǩ", value: library.bookmarks.count, symbol: "bookmark.fill") { onOpenBookmarks?() }
                collectionButton("���", value: library.shelves.count, symbol: "folder.fill") { onOpenShelves?() }
            }
        }
    }

    @MainActor private func loadProfile() async {
        let mode = settings.contentMode
        let id = UUID()
        requestID = id
        profile = nil
        loading = true
        error = nil
        await WebCookieBridge.synchronize()
        guard requestID == id, !Task.isCancelled else { return }
        connected = OfficialAccountSession.isConnected(mode: mode)
        guard connected else {
            loading = false
            await library.refreshOfficialLibrary()
            return
        }
        do {
            let fetched = try await KomiicAPI(mode: mode).accountProfile()
            try Task.checkCancellation()
            guard requestID == id, settings.contentMode == mode else { return }
            profile = fetched
            connected = fetched != nil
        } catch is CancellationError {
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if requestID == id { loading = false }
        if requestID == id {
            await settings.syncWarningPreferences(mode: mode)
            await library.refreshOfficialLibrary()
        }
    }

    private func openWebsite(_ path: String, title: String) {
        website = WebDestination(path: path, title: title, mode: settings.contentMode)
    }

    private func resetDescription(at date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes == 0 { return "��ȼ�������" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours) Сʱ \(minutes % 60) ���Ӻ�����" : "\(minutes) ���Ӻ�����"
    }
}

struct BlockedComicsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var loadErrors: Set<String> = []

    var body: some View {
        List {
            if library.blockedComicIDs.isEmpty {
                ContentUnavailableView("û�����ε�����", systemImage: "eye.slash",
                                       description: Text("���ε���������ʾ�����������ʱ�����"))
                    .listRowBackground(Color.clear)
            }
            ForEach(library.blockedComicIDs.sorted(), id: \.self) { id in
                HStack(spacing: 14) {
                    if let comic = library.blockedComics.first(where: { $0.id == id }) {
                        ComicCover(comic: comic)
                            .frame(width: 48, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(comic.title).font(.subheadline).lineLimit(2)
                    } else {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                            .frame(width: 48, height: 66)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("���� #\(id)").font(.subheadline)
                            if loadErrors.contains(id) {
                                Text("��ʱ�޷�ȡ����������").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("�������") { library.unblock(comicID: id) }
                        .font(.caption).buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("��������").navigationBarTitleDisplayMode(.inline)
        .task(id: library.activeMode) { await loadMissingMetadata() }
    }

    @MainActor private func loadMissingMetadata() async {
        let mode = library.activeMode
        let known = Set(library.blockedComics.map(\.id))
        let missing = library.blockedComicIDs.subtracting(known)
        loadErrors = []
        for id in missing.sorted() {
            guard !Task.isCancelled else { return }
            do {
                let comic = try await KomiicAPI(mode: mode).comic(id: id)
                try Task.checkCancellation()
                library.cacheBlockedComic(comic, mode: mode)
            } catch is CancellationError { return
            } catch {
                guard library.activeMode == mode, !Task.isCancelled else { return }
                loadErrors.insert(id)
            }
        }
    }
}
