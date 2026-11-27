import SwiftUI
import UIKit
import UserNotifications

enum AppTab: String, CaseIterable, Identifiable {
    case home, favorites, library, account

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .favorites: return "喜爱"
        case .library: return "资料库"
        case .account: return "账号"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .favorites: return "heart"
        case .library: return "books.vertical"
        case .account: return "person.crop.circle"
        }
    }
}

private enum LibrarySection: String { case bookmarks, shelves }
private enum SearchRoute: Hashable { case results(String) }
private enum MenuRoute: Hashable { case blocked, warnings }

struct RootView: View {
    private let headerHeight: CGFloat = 58
    private let bottomBarInset: CGFloat = 64

    @EnvironmentObject private var content: AppContentStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.komiicTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionIconSize: CGFloat = 21
    @State private var selected: AppTab = .home
    @State private var catalogPage: CatalogPage = .all
    @State private var scrollPage: AppPage? = .catalog(.all)
    @State private var pagerPosition = AppPagerPosition()
    @State private var catalogSelection = CatalogSelection()
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var librarySection: LibrarySection = .shelves
    @State private var searchPrompt = false
    @State private var showingPalette = false
    @State private var seenCompleted: Set<String> = []
    @State private var started = false

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                              height: geometry.size.height + insets.top + insets.bottom)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let landscape = isPad && size.width > size.height
            let topTabs = landscape || usesTopTabs(isPad: isPad)
            navigation(landscape: landscape, topTabs: topTabs)
                .environment(\.comicGridColumns, ComicGridColumns.count(for: size, isPad: isPad))
        }
        .ignoresSafeArea(.keyboard)
        .id(settings.contentMode)
        .accessibilityHidden(searchPrompt)
        .overlay {
            if searchPrompt {
                SearchPromptView(onCancel: { searchPrompt = false }, onSearch: { keyword in
                    searchPrompt = false
                    navigate(to: SearchRoute.results(keyword))
                })
            }
        }
        .sheet(isPresented: $showingPalette) { ThemePaletteView() }
        .onChange(of: settings.contentMode) { _, mode in
            library.selectMode(mode)
            paths = [:]
            selected = .home
            catalogPage = .all
            scrollPage = .catalog(.all)
            pagerPosition = AppPagerPosition()
            catalogSelection = CatalogSelection()
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

    private var path: Binding<NavigationPath> {
        let tab = selected
        return Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }

    private var isAtRoot: Bool { path.wrappedValue.isEmpty }

    private func usesTopTabs(isPad: Bool) -> Bool {
        if #available(iOS 18.0, *) { return isPad }
        return false
    }

    private func navigation(landscape: Bool, topTabs: Bool) -> some View {
        let bottomInset = topTabs ? 0 : bottomBarInset
        return NavigationStack(path: path) {
            rootPages(landscape: landscape, bottomInset: bottomInset)
                .background(theme.canvas)
                .toolbar(isAtRoot ? .hidden : .automatic, for: .navigationBar)
                .navigationDestination(for: Comic.self) { comic in
                    ComicDetailView(comic: comic, bottomInset: bottomInset, transparentHeader: landscape)
                        .toolbar {
                            if landscape {
                                let tabs = ToolbarItem(placement: .principal) {
                                    tabBar(icons: false, clear: true).frame(width: 320)
                                }
                                if #available(iOS 26.0, *) { tabs.sharedBackgroundVisibility(.hidden) }
                                else { tabs }
                            }
                        }
                }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if topTabs && !landscape {
                tabBar(icons: false, clear: false)
                    .frame(maxWidth: 400)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.regularMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            if !topTabs {
                tabBar(icons: true, clear: false)
                    .frame(maxWidth: 490)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
        .komiicScrollEdgeHidden(landscape, for: .top)
        .komiicScrollEdgeHidden(!topTabs, for: .bottom)
        .environment(\.openAuthor) { navigate(to: $0) }
        .environment(\.openComicDirectory) { navigate(to: $0) }
    }

    private func rootPages(landscape: Bool, bottomInset: CGFloat) -> some View {
        SlidingTabs(scrollPage: $scrollPage, position: pagerPosition, didSettle: didSettle) { page in
            screen(page, landscape: landscape, bottomInset: bottomInset)
        }
        .overlay(alignment: .top) {
            if landscape {
                VStack(spacing: 0) {
                    landscapeHeader
                    if selected == .home, !catalogSelection.isCollapsed(catalogPage) {
                        catalogSelector(collapsed: false)
                            .frame(maxWidth: 360)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                }
            } else {
                regularHeader
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selected == .home {
                CatalogFilterButton(selection: catalogSelection)
                    .padding(.trailing, CatalogFilterButton.inset)
                    .padding(.bottom, CatalogFilterButton.inset + bottomInset)
            }
        }
    }

    @ViewBuilder private func screen(_ page: AppPage, landscape: Bool, bottomInset: CGFloat) -> some View {
        let visible = selected == page.tab && isAtRoot
        switch page {
        case .catalog(let item):
            CatalogPageContent(page: item, active: visible && catalogPage == item,
                               headerInset: headerHeight + (landscape ? 44 : 0),
                               bottomInset: bottomInset, selection: catalogSelection)
        case .favorites:
            FavoritesView()
                .contentMargins(.top, headerHeight, for: .scrollContent)
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
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
            .padding(.top, headerHeight)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
        case .account:
            AccountView(onOpenFavorites: { open(.favorites) },
                        onOpenBookmarks: { librarySection = .bookmarks; open(.library) },
                        onOpenShelves: { librarySection = .shelves; open(.library) },
                        isVisible: visible)
                .contentMargins(.top, headerHeight, for: .scrollContent)
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
        }
    }

    private var regularHeader: some View {
        let collapsed = catalogSelection.isCollapsed(catalogPage)
        return ZStack {
            if selected != .home {
                Text(settings.contentMode == .adult ? "H 漫画 · \(selected.title)" : selected.title)
                    .font(.tabHeader).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            } else if collapsed {
                catalogSelector(collapsed: true)
            }
            HStack(spacing: 8) {
                if selected == .home && !collapsed {
                    catalogSelector(collapsed: false)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                topActions(clear: false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
        .background {
            Rectangle().fill(.regularMaterial)
                .mask(alignment: .top) {
                    LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: collapsed)
    }

    private var landscapeHeader: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 650 {
                tabBar(icons: false, clear: true)
                    .frame(maxWidth: 400)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) { topActions(clear: true) }
            } else {
                HStack(spacing: 12) {
                    tabBar(icons: false, clear: true).frame(maxWidth: .infinity)
                    topActions(clear: true)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
    }

    private func catalogSelector(collapsed: Bool) -> some View {
        CatalogPageSelector(page: catalogPage, position: pagerPosition, selection: catalogSelection,
                            collapsed: collapsed, select: { move(to: .catalog($0)) })
    }

    private func tabBar(icons: Bool, clear: Bool) -> some View {
        AppTabBar(selected: selected, icons: icons, clear: clear, select: selectTab)
    }

    @ViewBuilder private func topActions(clear: Bool) -> some View {
        if clear {
            HStack(spacing: 8) {
                searchButton.komiicGlass(interactive: true, clear: true)
                avatarMenu.komiicGlass(interactive: true, clear: true)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 0) {
                searchButton
                avatarMenu
            }
            .buttonStyle(.plain)
            .komiicGlass(interactive: true)
        }
    }

    private var searchButton: some View {
        Button { searchPrompt = true } label: { actionIcon("magnifyingglass") }
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
            .foregroundStyle(theme.accent)
            .frame(width: 50, height: 48)
            .contentShape(Rectangle())
    }

    private func didSettle(_ page: AppPage) {
        guard isAtRoot else { return }
        if case .catalog(let item) = page, catalogPage != item { catalogPage = item }
        if selected != page.tab { selected = page.tab }
    }

    private func move(to page: AppPage) {
        guard scrollPage != page else { return }
        let nearby = abs(CGFloat(page.index) - pagerPosition.progress) <= 1.1
        withAnimation(!reduceMotion && nearby ? .easeInOut(duration: 0.28) : nil) {
            scrollPage = page
        }
    }

    private func selectTab(_ tab: AppTab) {
        guard tab != selected else { return }
        let target: AppPage
        switch tab {
        case .home: target = .catalog(catalogPage)
        case .favorites: target = .favorites
        case .library: target = .library
        case .account: target = .account
        }
        if isAtRoot { move(to: target) }
        else {
            scrollPage = target
            selected = tab
        }
    }

    private func open(_ tab: AppTab) {
        paths[tab] = NavigationPath()
        selectTab(tab)
    }

    private func navigate(to route: some Hashable) {
        var destination = path.wrappedValue
        destination.append(route)
        path.wrappedValue = destination
    }

    private func openSearchResult(_ comic: Comic) {
        paths[selected] = NavigationPath()
        scrollPage = .catalog(catalogPage)
        selected = .home
        var homePath = NavigationPath()
        homePath.append(comic)
        paths[.home] = homePath
    }
}

private struct AppTabBar: View {
    let selected: AppTab
    let icons: Bool
    let clear: Bool
    let select: (AppTab) -> Void
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button { select(tab) } label: {
                    VStack(spacing: 2) {
                        if icons {
                            Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                        }
                        Text(tab.title)
                            .font(icons ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(tab == selected ? theme.accent : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: icons ? 50 : 44)
                    .background(tab == selected ? theme.accentWash : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityAddTraits(tab == selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 28, interactive: true, clear: clear)
    }
}
