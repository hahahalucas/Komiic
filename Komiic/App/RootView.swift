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
    private let actionHeight: CGFloat = 48

    @EnvironmentObject private var content: AppContentStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var imageSources: ImageSourceStore
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
            SystemTabs(selected: selected, hideTopScrollEdge: landscape, select: selectSystemTab) {
                nativeContent(landscape: landscape, statusTop: insets.top)
                    .environmentObject(content)
                    .environmentObject(library)
                    .environmentObject(downloads)
                    .environmentObject(imageSources)
                    .environmentObject(settings)
                    .environment(\.scenePhase, scenePhase)
                    .environment(\.komiicTheme, theme)
                    .environment(\.comicGridColumns, ComicGridColumns.count(for: size, isPad: isPad))
                    .tint(theme.accent)
            }
            .ignoresSafeArea(.container)
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

    @ViewBuilder private func nativeContent(landscape: Bool, statusTop: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GeometryReader { safe in
                GeometryReader { expanded in
                    let inset = max(0, expanded.frame(in: .global).maxY - safe.frame(in: .global).maxY)
                    navigation(landscape: landscape, statusTop: statusTop, bottomInset: inset)
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            navigation(landscape: landscape, statusTop: statusTop, bottomInset: 0)
                .toolbarBackground(.hidden, for: .tabBar)
        }
    }

    private func navigation(landscape: Bool, statusTop: CGFloat, bottomInset: CGFloat) -> some View {
        NavigationStack(path: path) {
            rootPages(landscape: landscape, statusTop: statusTop, bottomInset: bottomInset)
                .background(theme.canvas)
                .toolbar(isAtRoot ? .hidden : .automatic, for: .navigationBar)
                .navigationDestination(for: Comic.self) { comic in
                    ComicDetailView(comic: comic, bottomInset: bottomInset, transparentHeader: landscape)
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
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
        .komiicScrollEdgeHidden(landscape, for: .top)
        .komiicScrollEdgeHidden(true, for: .bottom)
        .environment(\.openAuthor) { navigate(to: $0) }
        .environment(\.openComicDirectory) { navigate(to: $0) }
    }

    @ViewBuilder private func rootPages(landscape: Bool, statusTop: CGFloat, bottomInset: CGFloat) -> some View {
        if landscape {
            GeometryReader { safe in
                GeometryReader { expanded in
                    let safeTop = max(0, safe.frame(in: .global).minY - expanded.frame(in: .global).minY)
                    let actionsTop = statusTop + max(0, (safeTop - statusTop - actionHeight) / 2)
                    let contentTop = max(safeTop, actionsTop + actionHeight + 4)
                    pager(headerInset: contentTop, landscape: true, bottomInset: bottomInset)
                        .overlay(alignment: .topLeading) {
                            if selected == .home, !catalogSelection.isCollapsed(catalogPage) {
                                catalogSelector(collapsed: false)
                                    .frame(maxWidth: 360)
                                    .padding(.horizontal, 12)
                                    .padding(.top, contentTop)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            topActions(clear: true)
                                .padding(.trailing, 12)
                                .padding(.top, actionsTop)
                        }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        } else {
            pager(headerInset: headerHeight, landscape: false, bottomInset: bottomInset)
                .overlay(alignment: .top) { regularHeader }
        }
    }

    private func pager(headerInset: CGFloat, landscape: Bool, bottomInset: CGFloat) -> some View {
        SlidingTabs(scrollPage: $scrollPage, position: pagerPosition, didSettle: didSettle) { page in
            screen(page, headerInset: headerInset, landscape: landscape, bottomInset: bottomInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if selected == .home {
                CatalogFilterButton(selection: catalogSelection)
                    .padding(.trailing, CatalogFilterButton.inset)
                    .padding(.bottom, CatalogFilterButton.inset + bottomInset)
            }
        }
    }

    @ViewBuilder private func screen(_ page: AppPage, headerInset: CGFloat, landscape: Bool,
                                     bottomInset: CGFloat) -> some View {
        let visible = selected == page.tab && isAtRoot
        switch page {
        case .catalog(let item):
            CatalogPageContent(page: item, active: visible && catalogPage == item,
                               headerInset: headerInset + (landscape ? 44 : 0),
                               bottomInset: bottomInset, selection: catalogSelection)
        case .favorites:
            FavoritesView()
                .contentMargins(.top, headerInset, for: .scrollContent)
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
            .padding(.top, headerInset)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
        case .account:
            AccountView(onOpenFavorites: { open(.favorites) },
                        onOpenBookmarks: { librarySection = .bookmarks; open(.library) },
                        onOpenShelves: { librarySection = .shelves; open(.library) },
                        isVisible: visible)
                .contentMargins(.top, headerInset, for: .scrollContent)
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

    private func catalogSelector(collapsed: Bool) -> some View {
        CatalogPageSelector(page: catalogPage, position: pagerPosition, selection: catalogSelection,
                            collapsed: collapsed, select: { move(to: .catalog($0)) })
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
            .frame(width: 50, height: actionHeight)
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

    private func selectSystemTab(_ tab: AppTab) {
        guard tab != selected else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPage = page(for: tab)
            selected = tab
        }
    }

    private func page(for tab: AppTab) -> AppPage {
        switch tab {
        case .home: return .catalog(catalogPage)
        case .favorites: return .favorites
        case .library: return .library
        case .account: return .account
        }
    }

    private func open(_ tab: AppTab) {
        paths[tab] = NavigationPath()
        move(to: page(for: tab))
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
