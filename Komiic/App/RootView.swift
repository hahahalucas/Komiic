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
    @State private var selected: AppTab = .home
    @State private var catalogPage: CatalogPage = .all
    @State private var catalogPosition = CatalogPagerPosition()
    @State private var gridColumns = UIDevice.current.userInterfaceIdiom == .pad ? 5 : 3
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var librarySection: LibrarySection = .shelves
    @State private var searchPrompt = false
    @State private var seenCompleted: Set<String> = []
    @State private var started = false

    var body: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        SlidingTabs(selection: $selected, swipeTargets: swipeTargets, prepareSwipe: prepareSwipe) { tab in
            screen(tab)
                .environmentObject(content)
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(settings)
                .environment(\.scenePhase, scenePhase)
                .environment(\.komiicTheme, theme)
                .environment(\.comicGridColumns, gridColumns)
                .tint(theme.accent)
        }
        .ignoresSafeArea(.container)
        .onGeometryChange(for: Int.self) { geometry in
            let height = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            let viewport = CGSize(width: geometry.size.width, height: height)
            return ComicGridColumns.count(for: viewport, isPad: isPad)
        } action: { gridColumns = $0 }
        .accessibilityHidden(searchPrompt)
        .overlay {
            if searchPrompt {
                SearchPromptView(onCancel: { searchPrompt = false }, onSearch: { keyword in
                    searchPrompt = false
                    var path = paths[selected] ?? NavigationPath()
                    path.append(SearchRoute.results(keyword))
                    paths[selected] = path
                })
            }
        }
        .id(settings.contentMode)
        .onChange(of: settings.contentMode) { _, mode in
            library.selectMode(mode)
            paths = [:]
            selected = .home
            catalogPage = .all
            catalogPosition.progress = 0
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

    private var completedIDs: Set<String> { Set(downloads.items.filter { $0.status == .completed }.map(\.id)) }

    @MainActor private func refreshOfficialData() async {
        let mode = settings.contentMode
        await WebCookieBridge.synchronize()
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        await library.refreshOfficialLibrary(force: false)
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        await settings.syncWarningPreferences(mode: mode)
    }

    private func screen(_ tab: AppTab) -> some View {
        TabRootScreen(tab: tab, isSelected: selected == tab, catalogPage: $catalogPage, catalogPosition: catalogPosition,
                      librarySection: $librarySection,
                      path: Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 }),
                      openSearchResult: { comic in
                          paths[tab] = NavigationPath()
                          var homePath = NavigationPath()
                          homePath.append(comic)
                          paths[.home] = homePath
                          selected = .home
                      },
                      openFavorites: { paths[.favorites] = NavigationPath(); selected = .favorites },
                      openBookmarks: { paths[.library] = NavigationPath(); librarySection = .bookmarks; selected = .library },
                      openShelves: { paths[.library] = NavigationPath(); librarySection = .shelves; selected = .library },
                      showSearch: { searchPrompt = true })
    }

    private func swipeTargets(for tab: AppTab) -> TabSwipeTargets? {
        guard tab == selected, !searchPrompt, paths[tab]?.isEmpty != false else { return nil }
        switch tab {
        case .home: return TabSwipeTargets(next: catalogPosition.nearestPage == .history ? .favorites : nil)
        case .favorites: return TabSwipeTargets(previous: .home, next: .library)
        case .library: return TabSwipeTargets(previous: .favorites, next: .account)
        case .account: return TabSwipeTargets(previous: .library)
        }
    }

    private func prepareSwipe(to tab: AppTab) -> (() -> Void)? {
        guard tab == .home, catalogPage != .history else { return nil }
        let previousPage = catalogPage
        catalogPage = .history
        return { catalogPage = previousPage }
    }
}

private struct TabRootScreen: View {
    let tab: AppTab
    let isSelected: Bool
    @Binding var catalogPage: CatalogPage
    let catalogPosition: CatalogPagerPosition
    @Binding var librarySection: LibrarySection
    @Binding var path: NavigationPath
    let openSearchResult: (Comic) -> Void
    let openFavorites: () -> Void
    let openBookmarks: () -> Void
    let openShelves: () -> Void
    let showSearch: () -> Void
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.komiicTheme) private var theme
    @ScaledMetric(relativeTo: .headline) private var actionIconSize: CGFloat = 19
    @State private var showingPalette = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GeometryReader { viewport in
                    GeometryReader { expanded in
                        // Keep the scroll viewport behind the tab bar and inset only its contents.
                        let bottomInset = max(0, expanded.size.height - viewport.size.height)
                        navigation(bottomInset: bottomInset)
                            .contentMargins(.bottom, bottomInset, for: .scrollContent)
                            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
                            .scrollEdgeEffectHidden(true, for: .bottom)
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            } else {
                navigation(bottomInset: 0)
                    .toolbarBackground(.hidden, for: .tabBar)
            }
        }
        .sheet(isPresented: $showingPalette) { ThemePaletteView() }
        .environment(\.openAuthor) { path.append($0) }
        .environment(\.openComicDirectory) { path.append($0) }
    }

    private var tabTitle: String {
        settings.contentMode == .adult ? "H 漫画 · \(tab.title)" : tab.title
    }

    private func navigation(bottomInset: CGFloat) -> some View {
        NavigationStack(path: $path) {
            content(bottomInset: bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
                .navigationTitle(tabTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(tab == .home && path.isEmpty ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    if tab != .home {
                        if path.isEmpty {
                            let title = ToolbarItem(placement: .principal) {
                                Text(tabTitle)
                                    .font(.tabHeader)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            if #available(iOS 26.0, *) {
                                title.sharedBackgroundVisibility(.hidden)
                            } else {
                                title
                            }
                        }
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarTrailing) { topActions }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarTrailing) { topActions }
                        }
                    }
                }
                .navigationDestination(for: Comic.self) { ComicDetailView(comic: $0, bottomInset: bottomInset) }
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
    }

    private var topActions: some View {
        HStack(spacing: 0) {
            searchButton
            avatarMenu
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 24, interactive: true)
    }

    private var searchButton: some View {
        Button(action: showSearch) { actionIcon("magnifyingglass") }
            .accessibilityLabel("搜索漫画")
    }

    private var avatarMenu: some View {
        Menu {
            Button { showingPalette = true } label: { Label("调色盘", systemImage: "paintpalette") }
            Divider()
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
        } label: { actionIcon("person.crop.circle") }
        .accessibilityLabel("更多功能")
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: min(actionIconSize, 34), weight: .medium))
            .imageScale(.medium)
            .foregroundStyle(theme.accent)
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder private func content(bottomInset: CGFloat) -> some View {
        switch tab {
        case .home:
            CatalogView(page: $catalogPage, position: catalogPosition, active: isSelected && path.isEmpty,
                        bottomInset: bottomInset) {
                topActions
            }
        case .favorites: FavoritesView()
        case .account: AccountView(onOpenFavorites: openFavorites, onOpenBookmarks: openBookmarks,
                                  onOpenShelves: openShelves, isVisible: isSelected && path.isEmpty)
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
}
