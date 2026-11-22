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
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore

    var body: some View {
        AccountContentView(onOpenFavorites: onOpenFavorites, onOpenBookmarks: onOpenBookmarks,
                           onOpenShelves: onOpenShelves, model: content.account(mode: settings.contentMode))
    }
}

private struct AccountContentView: View {
    var onOpenFavorites: (() -> Void)?
    var onOpenBookmarks: (() -> Void)?
    var onOpenShelves: (() -> Void)?
    @ObservedObject var model: AccountProfileModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore
    @State private var website: WebDestination?
    private var profile: KomiicAccountProfile? { model.profile }
    private var connected: Bool { model.connected }
    private var loading: Bool { model.loading }
    @State private var signingOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileHeader
                if loading { ProgressView("正在读取账号资料…").frame(maxWidth: .infinity) }
                if let error = model.error {
                    Text(error + " 下拉可刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let profile {
                    officialStats(profile)
                    if !profile.topCategories.isEmpty { categorySummary(profile.topCategories) }
                    collectionLinks(profile)
                    Button { openWebsite("/settings", title: "账号资料") } label: {
                        Text("如需更改账号信息，请到 Komiic 官网设定进行操作。")
                            .font(.caption).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                } else if !loading {
                    localSummary
                }
                if connected {
                    Button(role: .destructive) { signingOut = true } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
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
        .navigationTitle("账号").navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadProfile() }
        .task(id: settings.contentMode) { await loadProfile(force: false) }
        .sheet(item: $website) { destination in
            WebsiteView(url: destination.url, title: destination.title, onClose: {
                Task { await loadProfile() }
            })
        }
        .confirmationDialog("退出此 App 中的 Komiic 官网会话？本机阅读资料会保留。", isPresented: $signingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                content.resetAccounts()
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
                Text(profile?.username ?? (connected ? "Komiic 账号" : "欢迎来到 Komiic"))
                    .font(.title2.bold()).lineLimit(2)
                if let profile {
                    Text(profile.email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("加入于 \(String(profile.dateCreated.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(connected ? "下拉可重新读取官网资料" : "登录后查看账号资料和阅读统计")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(connected ? "打开官网账号" : "登录 Komiic") {
                        openWebsite(connected ? "/profile" : "/login", title: "Komiic 账号")
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
            stat("漫画已读", value: String(profile.readComicCount), symbol: "book.fill")
            stat("章节已读", value: String(profile.readChapterCount), symbol: "book.pages")
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "photo").font(.title3).foregroundStyle(KomiicTheme.accent)
                Text("\(profile.imageReadCount)/\(profile.imageReadLimit)")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("图片读取").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0, Double(profile.imageReadCount) / Double(max(1, profile.imageReadLimit)))))
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(resetDescription(at: profile.resetAt, now: context.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18).komiicCard()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "bubble.left").font(.title3).foregroundStyle(KomiicTheme.accent)
                Text(String(profile.commentCount)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("留言").font(.caption).foregroundStyle(.secondary)
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
            Label("最常阅读分类", systemImage: "square.grid.2x2").font(.headline)
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
            collectionButton("收藏", value: profile.favoriteCount, symbol: "heart.fill") {
                if let onOpenFavorites { onOpenFavorites() }
                else { openWebsite("/favorite", title: "官网收藏") }
            }
            collectionButton("书签", value: profile.bookmarkCount, symbol: "bookmark.fill") { openWebsite("/bookmarks", title: "官网书签") }
            collectionButton("书柜", value: library.shelves.count, symbol: "folder.fill") {
                if let onOpenShelves { onOpenShelves() }
                else { openWebsite("/folder", title: "官网书柜") }
            }
            collectionButton("追踪书柜", value: profile.followedFolderCount, symbol: "bookmark") { openWebsite("/folder?tab=followed", title: "追踪书柜") }
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
            SectionHeading(title: "本机阅读", subtitle: settings.contentMode.title)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                stat("漫画已读", value: String(library.readComicCount), symbol: "book.fill")
                stat("章节已读", value: String(library.readChapterCount), symbol: "book.pages")
            }
            HStack(spacing: 10) {
                collectionButton("收藏", value: library.favorites.count, symbol: "heart.fill") { onOpenFavorites?() }
                collectionButton("书签", value: library.bookmarks.count, symbol: "bookmark.fill") { onOpenBookmarks?() }
                collectionButton("书柜", value: library.shelves.count, symbol: "folder.fill") { onOpenShelves?() }
            }
        }
    }

    @MainActor private func loadProfile(force: Bool = true) async {
        guard force || !model.hasLoaded else { return }
        let mode = settings.contentMode
        await WebCookieBridge.synchronize()
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        async let profileLoad: Void = model.load(force: force)
        await library.refreshOfficialLibrary(force: force)
        await profileLoad
        if settings.contentMode == mode, let profile = model.profile {
            settings.applyWarningPreferences(profile.warningPreferences)
        }
    }

    private func openWebsite(_ path: String, title: String) {
        website = WebDestination(path: path, title: title, mode: settings.contentMode)
    }

    private func resetDescription(at date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes == 0 { return "额度即将重置" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours) 小时 \(minutes % 60) 分钟后重置" : "\(minutes) 分钟后重置"
    }
}

struct BlockedComicsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var loadErrors: Set<String> = []

    var body: some View {
        List {
            if let error = library.officialSyncError {
                Text(error).font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            if library.blockedComicIDs.isEmpty {
                ContentUnavailableView("没有屏蔽的漫画", systemImage: "eye.slash",
                                       description: Text("屏蔽的漫画会显示在这里，可以随时解除。"))
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
                            Text("漫画 #\(id)").font(.subheadline)
                            if loadErrors.contains(id) {
                                Text("暂时无法取得漫画资料").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("解除屏蔽") { library.unblock(comicID: id) }
                        .font(.caption).buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("屏蔽漫画").navigationBarTitleDisplayMode(.inline)
        .task(id: library.activeMode) {
            await library.refreshOfficialLibrary(force: false)
            await loadMissingMetadata()
        }
        .refreshable {
            await library.refreshOfficialLibrary()
            await loadMissingMetadata()
        }
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
