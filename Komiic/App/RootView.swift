import SwiftUI
import UserNotifications

enum AppTab: String, CaseIterable, Identifiable {
    case home, favorites, library, account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"; case .favorites: return "喜爱"; case .library: return "资料库"
        case .account: return "账号"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"; case .favorites: return "heart"
        case .library: return "books.vertical"
        case .account: return "person.crop.circle"
        }
    }
}

enum BrowsePage: String, CaseIterable, Identifiable {
    case updated, newest, popular, recommended, history, favorites, library, account

    var id: String { rawValue }

    var tab: AppTab {
        switch self {
        case .updated, .newest, .popular, .recommended, .history: return .home
        case .favorites: return .favorites
        case .library: return .library
        case .account: return .account
        }
    }
}

private enum LibrarySection: String {
    case bookmarks, shelves
}

private enum SearchRoute: Hashable {
    case results(String)
}

private enum MenuRoute: Hashable { case blocked, warnings }

struct RootView: View {
    @EnvironmentObject private var content: AppContentStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.komiicTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: BrowsePage = .updated
    @State private var homePage: BrowsePage = .updated
    @State private var path = NavigationPath()
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var librarySection: LibrarySection = .shelves
    @State private var filter: ContentFilter = .all
    @State private var showFilter = false
    @State private var showingPalette = false
    @State private var searchPrompt = false
    @State private var seenCompleted: Set<String> = []
    @State private var started = false

    var body: some View {
        GeometryReader { geometry in
            navigation
                .environment(\.comicGridColumns, ComicGridColumns.count(for: geometry.size, isPad: UIDevice.current.userInterfaceIdiom == .pad))
        }
        .accessibilityHidden(searchPrompt)
        .overlay {
            if searchPrompt {
                SearchPromptView(onCancel: { searchPrompt = false }, onSearch: { keyword in
                    searchPrompt = false
                    path.append(SearchRoute.results(keyword))
                })
            }
        }
        .id(settings.contentMode)
        .onChange(of: settings.contentMode) { _, mode in
            library.selectMode(mode)
            paths = [:]
            path = NavigationPath()
            homePage = .updated
            page = .updated
            filter = .all
            searchPrompt = false
        }
        .task { seenCompleted = completedIDs; started = true }
        .task(id: settings.contentMode) { await refreshOfficialData() }
        .onChange(of: completedIDs) { _, ids in
            guard started else { return }
            let newIDs = ids.subtracting(seenCompleted)
            seenCompleted = ids
            guard settings.notificationsEnabled, !newIDs.isEmpty else { return }
            for id in newIDs {
                guard let item = downloads.items.first(where: { $0.id == id }) else { continue }
                let content = UNMutableNotificationContent()
                content.title = "章节下载完成"
                content.body = "\(item.comic.title) · \(item.chapter.displayTitle)"
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-\(id)", content: content, trigger: nil)) { _ in }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                content.flushSnapshots()
                library.flushSnapshots()
                SessionCookieStore.shared.capture()
            }
            if phase == .active {
                Task { await library.retryPendingOfficialChanges() }
                downloads.applyCachePolicy(settings.cachePolicy)
            }
        }
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            pager
                .background(theme.canvas)
                .navigationTitle(settings.contentMode == .adult ? "H 漫画 · \(page.tab.title)" : page.tab.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { rootToolbar }
                .navigationDestination(for: Comic.self) { ComicDetailView(comic: $0) }
                .navigationDestination(for: BookshelfRoute.self) { ShelfDetailView(shelfID: $0.id) }
                .navigationDestination(for: ComicAuthor.self) { AuthorView(author: $0) }
                .navigationDestination(for: SearchRoute.self) { route in
                    switch route {
                    case .results(let keyword): SearchView(initialKeyword: keyword, onSelect: openSearchResult)
                    }
                }
                .navigationDestination(for: MenuRoute.self) { route in
                    switch route {
                    case .blocked: BlockedComicsView()
                    case .warnings: ContentWarningPreferencesView()
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .background(theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showingPalette) { ThemePaletteView() }
        .sheet(isPresented: $showFilter) {
            FilterSheet(selection: $filter)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .environment(\.openAuthor) { path.append($0) }
        .environment(\.openComicDirectory) { path.append($0) }
    }

    private var pager: some View {
        TabView(selection: Binding(get: { page }, set: { switchPage(to: $0) })) {
            ForEach(BrowsePage.allCases) { item in
                screen(item).tag(item)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases) { tab in
                PillButton(title: tab.title, symbol: tab.symbol, selected: page.tab == tab) {
                    switch tab {
                    case .home: goToPage(homePage)
                    case .favorites: goToPage(.favorites)
                    case .library: goToPage(.library)
                    case .account: goToPage(.account)
                    }
                }
            }
        }
        .komiicGlassGroup(spacing: 4)
        .frame(maxWidth: 440)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var rootToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { searchPrompt = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("搜索漫画")
            Button { showingPalette = true } label: { Image(systemName: "paintpalette") }
                .accessibilityLabel("调色盘")
            Menu {
                NavigationLink(value: MenuRoute.blocked) { Label("屏蔽漫画", systemImage: "eye.slash") }
                NavigationLink(value: MenuRoute.warnings) { Label("内容警告偏好", systemImage: "shield") }
                Divider()
                Button {
                    let mode: ComicContentMode = settings.contentMode == .general ? .adult : .general
                    library.selectMode(mode)
                    settings.contentMode = mode
                } label: {
                    Label(settings.contentMode == .general ? "切换到 H 漫画 · 18+" : "切换到一般漫画", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: { Image(systemName: "person.crop.circle") }
            .accessibilityLabel("更多功能")
        }
    }

    @ViewBuilder private func screen(_ item: BrowsePage) -> some View {
        switch item.tab {
        case .home:
            CatalogView(page: item, active: page == item && path.isEmpty, filter: filter,
                        onSelect: { goToPage($0) }, onFilter: { showFilter = true })
        case .favorites: FavoritesView()
        case .account:
            AccountView(onOpenFavorites: { goToPage(.favorites, opening: NavigationPath()) },
                        onOpenBookmarks: { librarySection = .bookmarks; goToPage(.library, opening: NavigationPath()) },
                        onOpenShelves: { librarySection = .shelves; goToPage(.library, opening: NavigationPath()) },
                        isVisible: page == item && path.isEmpty)
        case .library:
            VStack(spacing: 0) {
                Picker("资料库", selection: $librarySection) {
                    Text("书签").tag(LibrarySection.bookmarks)
                    Text("书柜").tag(LibrarySection.shelves)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18).padding(.vertical, 12)
                if librarySection == .shelves { ShelvesView() } else { BookmarksView() }
            }
        }
    }

    private func switchPage(to destination: BrowsePage, opening newPath: NavigationPath? = nil) {
        if page.tab != destination.tab {
            paths[page.tab] = path
            path = newPath ?? paths[destination.tab] ?? NavigationPath()
        } else if let newPath {
            path = newPath
        }
        page = destination
        if destination.tab == .home { homePage = destination }
    }

    private func goToPage(_ destination: BrowsePage, opening newPath: NavigationPath? = nil) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            switchPage(to: destination, opening: newPath)
        }
    }

    private func openSearchResult(_ comic: Comic) {
        path = NavigationPath()
        var homePath = NavigationPath()
        homePath.append(comic)
        goToPage(homePage, opening: homePath)
    }

    private var completedIDs: Set<String> { Set(downloads.items.filter { $0.status == .completed }.map(\.id)) }

    @MainActor private func refreshOfficialData() async {
        let mode = settings.contentMode
        await WebCookieBridge.synchronize()
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        await library.refreshOfficialLibrary(force: false)
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        await settings.syncWarningPreferences(mode: mode)
    }
}
