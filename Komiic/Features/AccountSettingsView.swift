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
    var isVisible = true
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore

    var body: some View {
        AccountContentView(onOpenFavorites: onOpenFavorites, onOpenBookmarks: onOpenBookmarks,
                           onOpenShelves: onOpenShelves, isVisible: isVisible,
                           model: content.account(mode: settings.contentMode))
    }
}

private struct AccountContentView: View {
    private enum ImageSheet: String, Identifiable {
        case accounts, quotas
        var id: Self { self }
    }

    var onOpenFavorites: (() -> Void)?
    var onOpenBookmarks: (() -> Void)?
    var onOpenShelves: (() -> Void)?
    var isVisible: Bool
    @ObservedObject var model: AccountProfileModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore
    @EnvironmentObject private var imageSources: ImageSourceStore
    @Environment(\.komiicTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var website: WebDestination?
    @State private var imageSheet: ImageSheet?
    @State private var showingMessages = false
    @State private var messagesRefresh = 0
    @State private var signingOut = false
    private var profile: KomiicAccountProfile? { model.profile }
    private var connected: Bool { model.connected }
    private var loading: Bool { model.loading }
    private var dashboardActive: Bool { isVisible && scenePhase == .active && website == nil }
    private var statColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileHeader
                if loading && profile == nil { ProgressView("正在读取账号资料…").frame(maxWidth: .infinity) }
                if let error = model.error {
                    Text(error + " 下拉可刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let profile {
                    officialStats(profile)
                    if showingMessages {
                        MyCommentsSection(mode: settings.contentMode, refresh: messagesRefresh)
                            .id("\(profile.id):\(content.revision)")
                    }
                    collectionLinks(profile)
                    Button { openWebsite("/settings", title: "账号资料") } label: {
                        Label("在 Komiic 官网修改账号资料", systemImage: "arrow.up.right.square")
                            .font(.caption).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                } else if !loading && !connected {
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
        .background(theme.canvas)
        .navigationTitle("账号").navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await loadDashboard()
            messagesRefresh += 1
        }
        .task(id: "\(settings.contentMode.rawValue):\(content.revision):\(dashboardActive)") {
            if dashboardActive { await loadDashboard(force: false) }
        }
        .onChange(of: content.revision) { _, _ in showingMessages = false }
        .sheet(item: $website) { destination in
            WebsiteView(url: destination.url, title: destination.title, onClose: {
                Task { await loadDashboard() }
            })
        }
        .sheet(item: $imageSheet) { sheet in
            if let profile {
                switch sheet {
                case .accounts: ImageAccountManagementView(mode: settings.contentMode, ownerID: profile.id)
                case .quotas: ImageQuotaDetailsView(mode: settings.contentMode, ownerID: profile.id, model: model)
                }
            }
        }
        .confirmationDialog("退出此 App 中的 Komiic 官网会话？本机阅读资料会保留。", isPresented: $signingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                content.resetAccounts()
                imageSources.clear()
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
            KomiicAvatar(name: profile?.username ?? "", profileText: profile?.profileText,
                         url: profile?.profileImageURL, size: dynamicTypeSize.isAccessibilitySize ? 52 : 72,
                         profileTextColor: profile?.profileTextColor, profileBackgroundColor: profile?.profileBackgroundColor)
            VStack(alignment: .leading, spacing: 6) {
                if let profile {
                    Text(profile.username.isEmpty ? "Komiic 账号" : profile.username).font(.title2.bold())
                    Text("ID \(profile.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let email = profile.email, !email.isEmpty {
                        Text(email).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let joined = profile.dateCreated, !joined.isEmpty {
                        Text("加入于 \(joined.prefix(10))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Komiic 账号").font(.title2.bold())
                    if !loading {
                        Button(connected ? "打开官网账号" : "登录 Komiic") {
                            openWebsite(connected ? "/profile" : "/login", title: "Komiic 账号")
                        }.font(.subheadline.bold())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentWash, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        .onLongPressGesture(perform: openImageAccounts)
        .accessibilityAction(named: Text("管理副账号"), openImageAccounts)
    }

    private func officialStats(_ profile: KomiicAccountProfile) -> some View {
        LazyVGrid(columns: statColumns, alignment: .leading, spacing: 12) {
            stat("漫画已读", value: profile.readingStats?.comicsRead, symbol: "book.fill")
            stat("章节已读", value: profile.readingStats?.chaptersRead, symbol: "book.pages")
            quotaCard(totalQuota(for: profile))
            messagesCard(profile.messageStats)
        }
    }

    private func quotaCard(_ quota: ImageReadingQuota?) -> some View {
        Button(action: { imageSheet = .quotas }) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "photo").font(.title3).foregroundStyle(theme.accent)
                Text(quota.map { "\($0.usage)/\($0.limit)" } ?? "—")
                    .font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                Text("图片读取").font(.subheadline).foregroundStyle(.secondary)
                if let quota {
                    ProgressView(value: quota.fractionUsed).tint(theme.accent).accessibilityHidden(true)
                    ImageQuotaResetText(date: quota.resetAt)
                } else if loading || model.loadingQuota {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).komiicCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("图片读取")
        .accessibilityValue(quota.map { "已读取 \($0.usage) 页，共 \($0.limit) 页" } ?? "—")
    }

    private func totalQuota(for profile: KomiicAccountProfile) -> ImageReadingQuota? {
        let secondary = ImageAccountSlot.allCases.compactMap { slot in
            imageSources.status(for: slot, mode: settings.contentMode, ownerID: profile.id).quota
        }
        return ImageReadingQuota.combined([profile.imageQuota].compactMap { $0 } + secondary)
    }

    private func openImageAccounts() {
        if model.imageSourceAccount != nil { imageSheet = .accounts }
    }

    private func messagesCard(_ stats: AccountMessageStats?) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { showingMessages.toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title3).foregroundStyle(theme.accent)
                    Spacer(minLength: 4)
                    Image(systemName: showingMessages ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(stats?.totalMessages.formatted() ?? "—").font(.title2.bold().monospacedDigit())
                Text("我的留言").font(.subheadline).foregroundStyle(.secondary)
                if let stats {
                    Label(stats.totalUpvotes.formatted(), systemImage: "hand.thumbsup")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("获赞 \(stats.totalUpvotes)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16).komiicCard()
        }
        .buttonStyle(.plain)
        .accessibilityValue(showingMessages ? "已展开" : "已收起")
    }

    private func stat(_ title: String, value: Int?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(theme.accent)
            Text(value?.formatted() ?? "—").font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(16).komiicCard()
    }

    private func collectionLinks(_ profile: KomiicAccountProfile) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9),
                                count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 9) {
            collectionButton("收藏", value: profile.readingStats?.favoriteCount, symbol: "heart.fill") {
                if let onOpenFavorites { onOpenFavorites() }
                else { openWebsite("/favorite", title: "官网收藏") }
            }
            collectionButton("书签", value: profile.readingStats?.bookmarkCount, symbol: "bookmark.fill") { openWebsite("/bookmarks", title: "官网书签") }
            let folderCount = library.officialAccountID == profile.id && !library.syncingOfficial
                ? library.shelves.count : profile.readingStats?.folderCount
            collectionButton("书柜", value: folderCount, symbol: "folder.fill") {
                if let onOpenShelves { onOpenShelves() }
                else { openWebsite("/folder", title: "官网书柜") }
            }
            collectionButton("追踪书柜", value: profile.readingStats?.followingFolderCount, symbol: "bookmark") { openWebsite("/folder?tab=followed", title: "追踪书柜") }
        }
    }

    private func collectionButton(_ title: String, value: Int?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(theme.accent)
                Text(value?.formatted() ?? "—").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 98).padding(.vertical, 10).komiicCard()
        }.buttonStyle(.plain)
    }

    private var localSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "本机阅读", subtitle: settings.contentMode.title)
            LazyVGrid(columns: statColumns, spacing: 14) {
                stat("漫画已读", value: library.readComicCount, symbol: "book.fill")
                stat("章节已读", value: library.readChapterCount, symbol: "book.pages")
            }
            HStack(spacing: 10) {
                collectionButton("收藏", value: library.favorites.count, symbol: "heart.fill") { onOpenFavorites?() }
                collectionButton("书签", value: library.bookmarks.count, symbol: "bookmark.fill") { onOpenBookmarks?() }
                collectionButton("书柜", value: library.shelves.count, symbol: "folder.fill") { onOpenShelves?() }
            }
        }
    }

    @MainActor private func loadDashboard(force: Bool = true) async {
        let mode = settings.contentMode
        async let secondary: Void = imageSources.refresh(mode: mode)
        await loadProfile(force: force)
        await secondary
    }

    @MainActor private func loadProfile(force: Bool = true) async {
        guard force || !model.hasLoaded else {
            await model.load(refreshQuota: true)
            return
        }
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

}

struct BlockedComicsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.komiicTheme) private var theme
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
                .listRowBackground(theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
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
