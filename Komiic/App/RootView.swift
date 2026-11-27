import SwiftUI
import UIKit
import UserNotifications

enum AppTab: String, CaseIterable, Identifiable {
    case home, favorites, library, account

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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
    private let phoneTabPadding: CGFloat = 6

    @EnvironmentObject private var content: AppContentStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.komiicTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionIconSize: CGFloat = 21
    @SceneStorage("reader.position.v1") private var readerPositionData: Data?
    @State private var activePage: AppPage = .catalog(.all)
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
    @State private var reader: ReaderLaunch?
    @State private var readerDismissal: (() -> Void)?

    private var selected: AppTab { activePage.tab }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                              height: geometry.size.height + insets.top + insets.bottom)
            let landscape = isPad && size.width > size.height
            let wideHeader = landscape && geometry.size.width >= 620
            let bottomInset = isPad ? 0 : AppTabBar.phoneHeight + phoneTabPadding
            navigation(landscape: landscape, wideHeader: wideHeader, bottomInset: bottomInset)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if isPad { tabletTabBar(showActions: wideHeader && isAtRoot) }
                }
                .overlay(alignment: .bottom) {
                    if !isPad {
                        AppTabBar(selected: selected, position: pagerPosition, isPad: false, select: selectTab)
                            .padding(.horizontal, 16)
                            .padding(.bottom, phoneTabPadding)
                    }
                }
                .environment(\.comicGridColumns, ComicGridColumns.count(for: size, isPad: isPad))
                .id(settings.contentMode)
        }
        .ignoresSafeArea(.keyboard)
        .background(theme.canvas.ignoresSafeArea())
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
        .fullScreenCover(item: $reader, onDismiss: readerDidDismiss) { launch in
            ReaderView(comic: launch.comic, chapter: launch.chapter, initialPage: launch.page,
                       chapterDirectory: launch.chapterDirectory,
                       onClose: { finished in closeReader(launch, finished: finished) },
                       onPositionChange: { chapter, page in saveReaderPosition(launch, chapter: chapter, page: page) })
                .interactiveDismissDisabled()
        }
        .onChange(of: settings.contentMode) { _, mode in
            library.selectMode(mode)
            paths = [:]
            activePage = .catalog(.all)
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
        .onChange(of: scenePhase, initial: true) { previous, phase in
            if phase == .background {
                content.flushSnapshots()
                library.flushSnapshots()
                SessionCookieStore.shared.capture()
            }
            if phase == .active {
                restoreReaderIfNeeded()
                if let page = pagerPosition.settledPage { didSettle(page) }
                if previous != .active {
                    Task { await library.retryPendingOfficialChanges() }
                    downloads.applyCachePolicy(settings.cachePolicy)
                }
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

    private func tabletTabBar(showActions: Bool) -> some View {
        AppTabBar(selected: selected, position: pagerPosition, isPad: true, select: selectTab)
            .padding(.horizontal, showActions ? 116 : 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if showActions { topActions(clear: true).padding(.trailing, 12) }
            }
    }

    private func navigation(landscape: Bool, wideHeader: Bool, bottomInset: CGFloat) -> some View {
        NavigationStack(path: path) {
            rootPages(wideHeader: wideHeader, bottomInset: bottomInset)
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
        .environment(\.openReader) { presentReader($0) }
    }

    private func rootPages(wideHeader: Bool, bottomInset: CGFloat) -> some View {
        SlidingTabs(scrollPage: $scrollPage, position: pagerPosition, didSettle: didSettle) { page in
            let headerInset: CGFloat = wideHeader ? (page.tab == .home ? 44 : 0) : headerHeight
            screen(page, headerInset: headerInset, bottomInset: bottomInset)
                .accessibilityHidden(activePage != page)
        }
        .overlay(alignment: .top) {
            header(wide: wideHeader)
        }
        .overlay(alignment: .bottomTrailing) {
            PagerFilterButton(selection: catalogSelection, position: pagerPosition)
                .padding(.trailing, CatalogFilterButton.inset)
                .padding(.bottom, CatalogFilterButton.inset + bottomInset)
        }
    }

    @ViewBuilder private func screen(_ page: AppPage, headerInset: CGFloat, bottomInset: CGFloat) -> some View {
        let visible = activePage == page && isAtRoot && reader == nil
        switch page {
        case .catalog(let item):
            CatalogPageContent(page: item, active: visible, headerInset: headerInset,
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

    private func header(wide: Bool) -> some View {
        PagerHeader(catalogPage: catalogPage, position: pagerPosition, selection: catalogSelection,
                    wide: wide, adult: settings.contentMode == .adult, select: { move(to: .catalog($0)) })
            .padding(.horizontal, 12)
            .frame(height: wide ? 44 : headerHeight)
            .overlay(alignment: .trailing) {
                if !wide { topActions(clear: false).padding(.trailing, 12) }
            }
            .background {
                if !wide {
                    Rectangle().fill(.regularMaterial)
                        .mask(alignment: .top) {
                            LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                }
            }
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
            Button { navigate(to: MenuRoute.blocked) } label: { Label("屏蔽漫画", systemImage: "eye.slash") }
            Button { navigate(to: MenuRoute.warnings) } label: { Label("内容警告偏好", systemImage: "shield") }
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
        guard isAtRoot, reader == nil, scenePhase == .active, page != activePage else { return }
        activate(page)
    }

    private func move(to page: AppPage) {
        guard page != activePage || scrollPage != page else { return }
        if reduceMotion || !isAtRoot || paths[page.tab]?.isEmpty == false {
            jump(to: page)
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { scrollPage = page }
        }
    }

    private func activate(_ page: AppPage) {
        if case .catalog(let item) = page { catalogPage = item }
        activePage = page
    }

    private func jump(to page: AppPage) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPage = page
            pagerPosition.progress = CGFloat(page.index)
            activate(page)
        }
    }

    private func selectTab(_ tab: AppTab) {
        guard tab != selected else { return }
        move(to: page(for: tab))
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
        jump(to: .catalog(catalogPage))
        var homePath = NavigationPath()
        homePath.append(comic)
        paths[.home] = homePath
    }

    private func presentReader(_ launch: ReaderLaunch) {
        guard reader == nil, readerDismissal == nil else { return }
        reader = launch
        saveReaderPosition(launch, chapter: launch.chapter, page: launch.page)
    }

    private func saveReaderPosition(_ launch: ReaderLaunch, chapter: Chapter, page: Int) {
        guard isPad, reader?.id == launch.id else { return }
        let position = ReaderPosition(mode: settings.contentMode, comic: launch.comic, chapter: chapter, page: page)
        if let data = try? JSONEncoder().encode(position) { readerPositionData = data }
    }

    private func restoreReaderIfNeeded() {
        guard isPad, reader == nil, readerDismissal == nil, let data = readerPositionData else { return }
        guard let position = try? JSONDecoder().decode(ReaderPosition.self, from: data),
              position.mode == settings.contentMode else {
            readerPositionData = nil
            return
        }
        if selected == .home, isAtRoot { navigate(to: position.comic) }
        reader = ReaderLaunch(comic: position.comic, chapter: position.chapter, page: position.page)
    }

    private func closeReader(_ launch: ReaderLaunch, finished: Bool) {
        guard reader?.id == launch.id else { return }
        readerPositionData = nil
        readerDismissal = { launch.onDismiss?(finished) }
        reader = nil
    }

    private func readerDidDismiss() {
        let dismissal = readerDismissal
        readerDismissal = nil
        dismissal?()
        if scenePhase == .active { restoreReaderIfNeeded() }
    }
}

private struct PagerHeader: View {
    let catalogPage: CatalogPage
    let position: AppPagerPosition
    let selection: CatalogSelection
    let wide: Bool
    let adult: Bool
    let select: (CatalogPage) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let collapsed = selection.isCollapsed(catalogPage)
        let homeOpacity = position.homeOpacity
        ZStack {
            if !wide {
                ForEach(AppTab.allCases.dropFirst()) { tab in
                    let opacity = position.opacity(for: tab)
                    Text(adult ? "H 漫画 · \(tab.title)" : tab.title)
                        .font(.tabHeader).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 90)
                        .opacity(opacity)
                        .animation(nil, value: position.progress)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHidden(opacity < 0.5)
                }
            }
            if !wide || !collapsed {
                CatalogPageSelector(page: catalogPage, position: position, selection: selection,
                                    collapsed: collapsed, select: select)
                    .frame(maxWidth: collapsed ? nil : 360)
                    .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                    .padding(.trailing, wide || collapsed ? 0 : 108)
                    .opacity(homeOpacity)
                    .animation(nil, value: position.progress)
                    .allowsHitTesting(homeOpacity > 0.5)
                    .accessibilityHidden(homeOpacity <= 0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: collapsed)
    }
}

private struct PagerFilterButton: View {
    let selection: CatalogSelection
    let position: AppPagerPosition

    var body: some View {
        let opacity = position.homeOpacity
        CatalogFilterButton(selection: selection)
            .opacity(opacity)
            .animation(nil, value: position.progress)
            .allowsHitTesting(opacity > 0.5)
            .accessibilityHidden(opacity <= 0.5)
    }
}
