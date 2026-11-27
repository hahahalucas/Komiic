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

    var feedOptions: [CatalogFeed] {
        switch self {
        case .popular: return [.popular, .monthlyPopular]
        case .recommended: return [.recommended, .readerWeekly, .readerMonthly, .readerYearly]
        default: return []
        }
    }
}

@Observable
final class CatalogSelection {
    var filter: ContentFilter = .all
    private var popular: CatalogFeed = .popular
    private var recommended: CatalogFeed = .recommended
    private var collapsedPages: Set<CatalogPage> = []

    func feed(for page: CatalogPage) -> CatalogFeed? {
        switch page {
        case .all: return .all
        case .popular: return popular
        case .recommended: return recommended
        case .history: return nil
        }
    }

    func select(_ feed: CatalogFeed, on page: CatalogPage) {
        guard page.feedOptions.contains(feed), self.feed(for: page) != feed else { return }
        if page == .popular { popular = feed } else { recommended = feed }
        collapsedPages.remove(page)
    }

    func isCollapsed(_ page: CatalogPage) -> Bool { collapsedPages.contains(page) }

    func setCollapsed(_ collapsed: Bool, on page: CatalogPage) {
        guard collapsed != isCollapsed(page) else { return }
        if collapsed { collapsedPages.insert(page) } else { collapsedPages.remove(page) }
    }
}

private enum CatalogScrollSpace { case feed }

struct CatalogPageContent: View {
    let page: CatalogPage
    let active: Bool
    let headerInset: CGFloat
    let bottomInset: CGFloat
    let selection: CatalogSelection
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore

    var body: some View {
        Group {
            if let feed = selection.feed(for: page) {
                CatalogFeedPage(feed: feed, filter: selection.filter, active: active, headerInset: headerInset,
                                onCollapse: onCollapse, model: content.catalog(feed: feed, mode: settings.contentMode))
                    .id(feed)
            } else {
                HistoryView(filter: selection.filter, active: active, headerInset: headerInset, onCollapse: onCollapse)
                    .id(content.revision)
            }
        }
        .contentMargins(.bottom, bottomInset + CatalogFilterButton.size + CatalogFilterButton.inset, for: .scrollContent)
    }

    private func onCollapse(_ collapsed: Bool) { selection.setCollapsed(collapsed, on: page) }
}

struct CatalogPageSelector: View {
    let page: CatalogPage
    let position: AppPagerPosition
    let selection: CatalogSelection
    let collapsed: Bool
    let select: (CatalogPage) -> Void
    @Environment(\.komiicTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Group {
            if collapsed {
                if page.feedOptions.isEmpty {
                    Text(page.title)
                        .font(.tabHeader)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    pageMenu(page, expanded: false)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(CatalogPage.allCases) { item in
                        if page == item, !item.feedOptions.isEmpty {
                            pageMenu(item, expanded: true)
                        } else {
                            Button { select(item) } label: { pageLabel(item, expanded: true) }
                                .accessibilityAddTraits(page == item ? [.isSelected] : [])
                        }
                    }
                }
                .overlay(alignment: .bottom) { underline }
            }
        }
        .buttonStyle(.plain)
    }

    private func pageMenu(_ item: CatalogPage, expanded: Bool) -> some View {
        Menu {
            ForEach(item.feedOptions) { feed in
                Button { selection.select(feed, on: item) } label: {
                    if selection.feed(for: item) == feed { Label(feed.title, systemImage: "checkmark") }
                    else { Text(feed.title) }
                }
            }
        } label: {
            pageLabel(item, expanded: expanded, showsMenu: true)
        }
        .accessibilityAddTraits(.isSelected)
        .accessibilityValue(selection.feed(for: item)?.title ?? "")
    }

    private func pageLabel(_ item: CatalogPage, expanded: Bool, showsMenu: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(item.title)
                .font(.tabHeader.weight(page == item ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if showsMenu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundStyle(page == item ? theme.accent : Color.secondary)
        .frame(maxWidth: expanded ? .infinity : nil, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var underline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(CatalogPage.allCases.count)
            let progress = min(position.progress, CGFloat(CatalogPage.allCases.count - 1))
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            Capsule().fill(theme.accent)
                .frame(width: min(32, width * 0.6), height: 3)
                .frame(width: width)
                .offset(x: progress * width * direction)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct CatalogFilterButton: View {
    static let size: CGFloat = 48
    static let inset: CGFloat = 14

    @Bindable var selection: CatalogSelection
    @State private var showFilter = false
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        Button { showFilter = true } label: {
            Image(systemName: selection.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(selection.filter == .all ? Color.primary : theme.accent)
                .frame(width: Self.size, height: Self.size)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 14, interactive: true)
        .accessibilityLabel("筛选选项")
        .accessibilityValue(selection.filter.title)
        .sheet(isPresented: $showFilter) {
            FilterSheet(selection: $selection.filter)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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
