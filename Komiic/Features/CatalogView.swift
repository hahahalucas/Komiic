import SwiftUI

@MainActor
final class CatalogModel: ObservableObject {
    @Published var comics: [Comic] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    @Published private(set) var loadedFilter: ContentFilter?
    private var generation = UUID()
    private var offset = 0
    private let fetchComics: (CatalogFeed, Int, ContentFilter) async throws -> [Comic]
    private var requestTask: Task<[Comic], Error>?
    private var requestedFilter: ContentFilter?
    private var retryFromFirstPage = true
    private let snapshots: AppSnapshotStore?
    private let cachePrefix: String
    private let scopeIsCurrent: () -> Bool

    func loadIfNeeded(feed: CatalogFeed, filter: ContentFilter) async {
        guard loadedFilter != filter, !(loading && requestedFilter == filter) else { return }
        if restore(filter: filter) { return }
        guard error == nil || requestedFilter != filter else { return }
        await load(feed: feed, filter: filter, reset: true)
    }

    init(snapshots: AppSnapshotStore? = nil, cachePrefix: String = "",
         scopeIsCurrent: @escaping () -> Bool = { true },
         fetchComics: @escaping (CatalogFeed, Int, ContentFilter) async throws -> [Comic] = { feed, offset, filter in
        try await KomiicAPI().catalog(feed: feed, offset: offset, filter: filter)
    }) {
        self.fetchComics = fetchComics
        self.snapshots = snapshots
        self.cachePrefix = cachePrefix
        self.scopeIsCurrent = scopeIsCurrent
        _ = restore(filter: .all)
    }

    func load(feed: CatalogFeed, filter: ContentFilter, reset: Bool) async {
        guard scopeIsCurrent() else { return }
        if reset {
            generation = UUID()
            requestTask?.cancel()
            // Keep a loaded page in place while refreshing, including when nothing changed.
            if loadedFilter != filter {
                offset = 0
                comics = []
                hasMore = true
                loadedFilter = nil
            }
        } else {
            guard !loading, hasMore, loadedFilter == filter else { return }
        }
        let requestID = generation
        let requestedOffset = reset ? 0 : offset
        loading = true
        requestedFilter = filter
        retryFromFirstPage = reset
        error = nil
        // A collapsing refresh control or a pager transition must not cancel the request.
        // A newer reset explicitly cancels and supersedes it instead.
        let request = Task {
            let results = try await fetchComics(feed, requestedOffset, filter)
            try Task.checkCancellation()
            return results
        }
        requestTask = request
        defer {
            if generation == requestID {
                loading = false
                requestTask = nil
            }
        }
        do {
            let results = try await request.value
            guard generation == requestID, scopeIsCurrent() else { return }
            offset = requestedOffset + results.count
            var ids = reset ? Set<String>() : Set(comics.map(\.id))
            let newComics = results.filter { ids.insert($0.id).inserted }
            if reset { comics = newComics }
            else { comics.append(contentsOf: newComics) }
            hasMore = feed.supportsPagination && !newComics.isEmpty
            loadedFilter = filter
            let saved = Array(comics.prefix(90))
            snapshots?.save(CatalogSnapshot(comics: saved, offset: comics.count > 90 ? saved.count : offset,
                hasMore: comics.count > 90 || hasMore), key: cacheKey(filter))
        } catch {
            // Only superseded requests are ignored. An active request that the network
            // cancels still needs a retry state instead of an endless initial spinner.
            if generation == requestID { self.error = error.localizedDescription }
        }
    }

    func retry(feed: CatalogFeed, filter: ContentFilter) async {
        guard error != nil else { return }
        await load(feed: feed, filter: filter, reset: retryFromFirstPage || requestedFilter != filter)
    }

    func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil; loading = false
    }
    private func cacheKey(_ filter: ContentFilter) -> String { "catalog:\(cachePrefix):\(filter.rawValue)" }
    private func restore(filter: ContentFilter) -> Bool {
        guard let cached = snapshots?.load(CatalogSnapshot.self, key: cacheKey(filter)) else { return false }
        cancel()
        comics = cached.comics; offset = cached.offset; hasMore = cached.hasMore
        loadedFilter = filter; requestedFilter = filter; error = nil
        return true
    }
}

enum CatalogPage: String, CaseIterable, Identifiable {
    case all, popular, recommended, history

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .popular: return "最热"
        case .recommended: return "推荐"
        case .history: return "最近"
        }
    }

    var feed: CatalogFeed? {
        switch self {
        case .all: return .all
        case .popular: return .popular
        case .recommended: return .recommended
        case .history: return nil
        }
    }
}

@Observable
final class CatalogPagerPosition {
    var progress: CGFloat = 0

    var isAtEnd: Bool { progress >= CGFloat(CatalogPage.allCases.count - 1) - 0.005 }

    var nearestPage: CatalogPage { CatalogPage.allCases[Int(progress.rounded())] }
}

struct CatalogView<Actions: View>: View {
    private let filterButtonSize: CGFloat = 48
    private let filterButtonInset: CGFloat = 14

    @Binding private var page: CatalogPage
    private let position: CatalogPagerPosition
    private let active: Bool
    private let bottomInset: CGFloat
    private let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.komiicTheme) private var theme
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore
    @State private var filter: ContentFilter = .all
    @State private var showFilter = false
    @State private var scrollPage: CatalogPage?
    @State private var collapsedPages: Set<CatalogPage> = []
    @State private var headerInset: CGFloat = 52

    init(page: Binding<CatalogPage>, position: CatalogPagerPosition, active: Bool, bottomInset: CGFloat,
         @ViewBuilder actions: () -> Actions) {
        _page = page
        _scrollPage = State(initialValue: page.wrappedValue)
        self.position = position
        self.active = active
        self.bottomInset = bottomInset
        self.actions = actions()
    }

    var body: some View {
        pager
            .overlay(alignment: .top) {
                CatalogHeader(position: position, collapsed: collapsedPages.contains(page), select: select, actions: actions)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerInset = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                filterButton.padding([.trailing, .bottom], filterButtonInset)
            }
            .sheet(isPresented: $showFilter) {
                FilterSheet(selection: $filter)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder private var pager: some View {
        if #available(iOS 26.0, *) {
            pagerViewport.ignoresSafeArea(.container, edges: .bottom)
        } else {
            pagerViewport
        }
    }

    private var pagerViewport: some View {
        GeometryReader { viewport in
            let width = viewport.size.width
            let rightToLeft = layoutDirection == .rightToLeft
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(CatalogPage.allCases) { item in
                        pageContent(item)
                            .frame(width: width, height: viewport.size.height)
                            .clipped()
                            .id(item)
                    }
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { geometry in
                    let frame = geometry.frame(in: .named(CatalogScrollSpace.pages))
                    let offset = rightToLeft ? frame.maxX - width : -frame.minX
                    return min(max(0, offset / max(1, width)), CGFloat(CatalogPage.allCases.count - 1))
                } action: { position.progress = $0 }
            }
            .coordinateSpace(.named(CatalogScrollSpace.pages))
            .scrollIndicators(.hidden, axes: .horizontal)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: pageLimit))
            .scrollPosition(id: $scrollPage, anchor: .center)
            .onChange(of: scrollPage) { _, current in
                if let current, page != current { page = current }
            }
            .onChange(of: page) { _, destination in
                if scrollPage != destination { scrollPage = destination }
            }
            // Each page and the clip share the safe-area width, including on notched iPhones.
            .frame(width: width, height: viewport.size.height)
            .clipped()
        }
    }

    private var pageLimit: ViewAlignedScrollTargetBehavior.LimitBehavior {
        if #available(iOS 26.0, *) { return .alwaysByOne }
        return .always
    }

    private func pageContent(_ item: CatalogPage) -> some View {
        let onCollapse: (Bool) -> Void = { collapsed in
            if collapsed {
                collapsedPages.insert(item)
            } else {
                collapsedPages.remove(item)
            }
        }
        return Group {
            if let feed = item.feed {
                CatalogFeedPage(feed: feed, filter: filter, active: active && page == item, headerInset: headerInset,
                                onCollapse: onCollapse, model: content.catalog(feed: feed, mode: settings.contentMode))
            } else {
                HistoryView(filter: filter, active: active && page == item, headerInset: headerInset, onCollapse: onCollapse)
                    .id(content.revision)
            }
        }
        .contentMargins(.bottom, bottomInset + filterButtonSize + filterButtonInset, for: .scrollContent)
    }

    private var filterButton: some View {
        Button { showFilter = true } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(filter == .all ? Color.primary : theme.accent)
                .frame(width: filterButtonSize, height: filterButtonSize)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 14, interactive: true)
        .accessibilityLabel("筛选选项")
        .accessibilityValue(filter.title)
    }

    private func select(_ destination: CatalogPage) {
        guard scrollPage != destination else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            scrollPage = destination
        }
    }
}

private enum CatalogScrollSpace { case pages, feed }

private struct CatalogHeader<Actions: View>: View {
    let position: CatalogPagerPosition
    let collapsed: Bool
    let select: (CatalogPage) -> Void
    let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if collapsed {
                CatalogPageTitle(position: position)
            }
            HStack(spacing: 8) {
                if collapsed {
                    Spacer(minLength: 0)
                } else {
                    CatalogPageSelector(position: position, select: select)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
}

private struct CatalogPageTitle: View {
    let position: CatalogPagerPosition

    var body: some View {
        Text(position.nearestPage.title)
            .font(.headline)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CatalogPageSelector: View {
    let position: CatalogPagerPosition
    let select: (CatalogPage) -> Void
    @Environment(\.komiicTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let current = position.nearestPage
        HStack(spacing: 0) {
            ForEach(CatalogPage.allCases) { item in
                Button { select(item) } label: {
                    Text(item.title)
                        .font(.subheadline.weight(current == item ? .semibold : .regular))
                        .foregroundStyle(current == item ? theme.accent : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == item ? [.isSelected] : [])
            }
        }
        .overlay {
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(CatalogPage.allCases.count)
                let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
                Capsule().fill(theme.accent)
                    .frame(width: min(32, width * 0.6), height: 3)
                    .frame(width: width)
                    .offset(x: position.progress * width * direction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct CatalogScrollView<Content: View>: View {
    let headerInset: CGFloat
    let onCollapse: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                ScrollView { content() }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top >= 28
                    } action: { _, collapsed in onCollapse(collapsed) }
            } else {
                ScrollView {
                    content()
                        .onGeometryChange(for: Bool.self) { geometry in
                            geometry.frame(in: .named(CatalogScrollSpace.feed)).minY <= headerInset - 28
                        } action: { onCollapse($0) }
                }
                .coordinateSpace(.named(CatalogScrollSpace.feed))
            }
        }
        .contentMargins(.top, headerInset, for: .scrollContent)
        .contentMargins(.top, headerInset, for: .scrollIndicators)
        .scrollBounceBehavior(.always, axes: .vertical)
    }
}

private struct CatalogFeedPage: View {
    private let paginationLeadDistance: CGFloat = 160

    let feed: CatalogFeed
    let filter: ContentFilter
    let active: Bool
    let headerInset: CGFloat
    let onCollapse: (Bool) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @ObservedObject var model: CatalogModel

    private var visibleComics: [Comic] {
        model.comics.filter { !library.isBlocked($0) && !settings.shouldHide($0) }
    }

    var body: some View {
        CatalogScrollView(headerInset: headerInset, onCollapse: onCollapse) {
            VStack(spacing: 18) {
                ComicGrid(comics: visibleComics)
                if let error = model.error {
                    EmptyState(symbol: "wifi.exclamationmark", title: "连接暂时不可用", message: error,
                               actionTitle: "重新连接", action: {
                                   Task { await model.retry(feed: feed, filter: filter) }
                               })
                } else if model.loading || model.loadedFilter != filter {
                    ProgressView("正在载入漫画…").font(.caption).padding(35)
                } else if feed.supportsPagination, model.hasMore {
                    if active { paginationMarker }
                } else if visibleComics.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "暂无漫画", message: "尝试调整筛选，或稍后刷新。")
                }
            }
            .padding(14)
            .frame(maxWidth: 1_400)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .task(id: "\(ObjectIdentifier(model)):\(active):\(filter.rawValue)") {
            guard !Task.isCancelled, active, model.loadedFilter != filter else { return }
            await model.loadIfNeeded(feed: feed, filter: filter)
        }
    }

    private var paginationMarker: some View {
        Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: Bool.self) { geometry in
                guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return false }
                return viewport.maxY >= -paginationLeadDistance
            } action: { nearEnd in
                guard nearEnd else { return }
                Task {
                    guard model.error == nil else { return }
                    await model.load(feed: feed, filter: filter, reset: false)
                }
            }
            .id(model.comics.count)
    }

    private func reload() async {
        await model.load(feed: feed, filter: filter, reset: true)
    }
}

private struct FilterSheet: View {
    @Binding var selection: ContentFilter
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ContentFilter = .all
    var body: some View {
        NavigationStack {
            Form {
                Section("内容分级") {
                    Picker("色气指数", selection: $draft) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }.pickerStyle(.menu)
                }
            }
            .navigationTitle("筛选选项").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("重置") { draft = .all } }
                ToolbarItem(placement: .topBarTrailing) { Button("确定") { selection = draft; dismiss() }.bold() }
            }
        }
        .onAppear { draft = selection }
    }
}

struct SearchView: View {
    let onSelect: (Comic) -> Void
    @State private var keyword = ""
    @State private var searchPresented = false
    @State private var comics: [Comic] = []
    @State private var loading = false
    @State private var error: String?
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.komiicTheme) private var theme
    private var visibleComics: [Comic] { comics.filter { !library.isBlocked($0) && !settings.shouldHide($0) } }

    init(initialKeyword: String = "", onSelect: @escaping (Comic) -> Void) {
        self.onSelect = onSelect
        _keyword = State(initialValue: initialKeyword)
    }
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            if let error {
                EmptyState(symbol: "wifi.exclamationmark", title: "搜索失败", message: error)
            } else if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "找一本想看的漫画", message: "输入漫画名、作者或关键词。")
            } else if visibleComics.isEmpty && !loading {
                EmptyState(symbol: "text.magnifyingglass", title: "没有找到相关漫画", message: "换一个名称或更短的关键词试试。")
            } else {
                ComicGrid(comics: visibleComics, onSelect: onSelect).padding(14)
            }
        }
        .background(theme.canvas)
        .navigationTitle("搜索")
        .searchable(text: $keyword, isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "漫画名 / 作者")
        .onAppear { searchPresented = true }
        .task(id: keyword) {
            comics = []; error = nil
            let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                let result = try await KomiicAPI(mode: settings.contentMode).search(keyword: query)
                try Task.checkCancellation()
                comics = result
            } catch is CancellationError { return
            } catch let urlError as URLError where urlError.code == .cancelled { return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
