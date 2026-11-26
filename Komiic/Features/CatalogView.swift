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
        } else if loading || !hasMore { return }
        let requestID = generation
        let requestedOffset = reset ? 0 : offset
        loading = true
        requestedFilter = filter
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
    var title: String { feed?.title ?? "最近阅读" }

    var feed: CatalogFeed? {
        switch self {
        case .all: return .all
        case .popular: return .popular
        case .recommended: return .recommended
        case .history: return nil
        }
    }
}

struct CatalogView: View {
    private static let filterButtonSize: CGFloat = 48
    private static let filterButtonInset: CGFloat = 14

    @Binding var page: CatalogPage
    let active: Bool
    let bottomInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.komiicTheme) private var theme
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var content: AppContentStore
    @State private var filter: ContentFilter = .all
    @State private var showFilter = false
    @State private var visiblePage: CatalogPage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(CatalogPage.allCases) { item in
                    PillButton(title: item.title, selected: page == item) { select(item) }
                }
            }
            .komiicGlassGroup(spacing: 6)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider().opacity(0.4)
            pager
        }
        .overlay(alignment: .bottomTrailing) {
            filterButton.padding([.trailing, .bottom], Self.filterButtonInset)
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet(selection: $filter)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private var pager: some View {
        if #available(iOS 26.0, *) {
            // A page-style TabView clips its hosted pages to the tab bar's safe area.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(CatalogPage.allCases) { item in
                        pageContent(item)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden, axes: .horizontal)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $visiblePage, anchor: .center)
            .onScrollPhaseChange { _, phase in
                // Commit the tab selection after the drag has settled.
                if phase == .idle, let visiblePage, page != visiblePage {
                    page = visiblePage
                }
            }
            .onChange(of: page, initial: true) { _, destination in
                guard visiblePage != destination else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    visiblePage = destination
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            TabView(selection: $page) {
                ForEach(CatalogPage.allCases) { item in
                    pageContent(item).tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func pageContent(_ item: CatalogPage) -> some View {
        Group {
            if let feed = item.feed {
                CatalogFeedPage(feed: feed, filter: filter, active: active && page == item,
                                model: content.catalog(feed: feed, mode: settings.contentMode))
            } else {
                HistoryView(filter: filter, active: active && page == item)
                    .id(content.revision)
            }
        }
        .contentMargins(.bottom, bottomInset + Self.filterButtonSize + Self.filterButtonInset, for: .scrollContent)
    }

    private var filterButton: some View {
        Button { showFilter = true } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(filter == .all ? Color.primary : theme.accent)
                .frame(width: Self.filterButtonSize, height: Self.filterButtonSize)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 14, interactive: true)
        .accessibilityLabel("筛选选项")
        .accessibilityValue(filter.title)
    }

    private func select(_ destination: CatalogPage) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            page = destination
        }
    }
}

private struct CatalogFeedPage: View {
    let feed: CatalogFeed
    let filter: ContentFilter
    let active: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReaderSettings
    @ObservedObject var model: CatalogModel

    private var visibleComics: [Comic] {
        model.comics.filter { !library.isBlocked($0) && !settings.shouldHide($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ComicGrid(comics: visibleComics)
                if let error = model.error {
                    EmptyState(symbol: "wifi.exclamationmark", title: "连接暂时不可用", message: error,
                               actionTitle: "重新连接", action: { Task { await reload() } })
                } else if model.loading || model.loadedFilter == nil {
                    ProgressView("正在载入漫画…").font(.caption).padding(35)
                } else if visibleComics.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "暂无漫画", message: "尝试调整筛选，或稍后刷新。")
                }
                if feed.supportsPagination, model.hasMore, !model.loading, model.loadedFilter != nil, model.error == nil {
                    Button("载入更多") { Task { await model.load(feed: feed, filter: filter, reset: false) } }
                        .buttonStyle(.bordered).padding(.bottom, 14)
                }
            }
            .padding(14)
            .frame(maxWidth: 1_400)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await reload() }
        .task(id: "\(ObjectIdentifier(model)):\(active):\(filter.rawValue)") {
            guard !Task.isCancelled, active, model.loadedFilter != filter else { return }
            await model.loadIfNeeded(feed: feed, filter: filter)
        }
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
