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
    private let api = KomiicAPI()

    func load(feed: CatalogFeed, filter: ContentFilter, reset: Bool) async {
        if reset {
            generation = UUID()
            offset = 0
            comics = []
            hasMore = true
            loadedFilter = nil
        } else if loading || !hasMore { return }
        let requestID = generation
        loading = true
        error = nil
        defer { if generation == requestID { loading = false } }
        do {
            let results = try await api.catalog(feed: feed, offset: offset, filter: filter)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            offset += results.count
            var ids = Set(comics.map(\.id))
            let newComics = results.filter { ids.insert($0.id).inserted }
            comics.append(contentsOf: newComics)
            hasMore = !results.isEmpty && !newComics.isEmpty
            loadedFilter = filter
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            if generation == requestID { self.error = error.localizedDescription }
        }
    }
}

// The first primary category contains both update pages; the pager visits all five.
private enum CatalogPage: String, CaseIterable, Identifiable {
    case updated, newest, popular, recommended, history

    var id: String { rawValue }
    var isUpdates: Bool { self == .updated || self == .newest }
    var feed: CatalogFeed? {
        switch self {
        case .updated: return .updated
        case .newest: return .newest
        case .popular: return .popular
        case .recommended: return .recommended
        case .history: return nil
        }
    }
}

struct CatalogView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: CatalogPage = .updated
    @State private var filter: ContentFilter = .all
    @State private var showFilter = false

    private var pageSelection: Binding<CatalogPage> {
        Binding(get: { page }, set: { select($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PillButton(title: "最近更新", selected: page.isUpdates) { select(.updated) }
                PillButton(title: "当月最热", selected: page == .popular) { select(.popular) }
                PillButton(title: "推荐漫画", selected: page == .recommended) { select(.recommended) }
                PillButton(title: "最近阅读", selected: page == .history) { select(.history) }
            }
            .komiicGlassGroup(spacing: 6)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider().opacity(0.4)
            pageControls

            // Native paging tracks the drag continuously and settles onto the next page.
            TabView(selection: $page) {
                ForEach(CatalogPage.allCases) { item in
                    Group {
                        if let feed = item.feed {
                            CatalogFeedPage(feed: feed, filter: filter, active: page == item)
                        } else {
                            HistoryView()
                        }
                    }
                    .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet(selection: $filter)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            if page.isUpdates {
                Picker("更新方式", selection: pageSelection) {
                    Text("最近更新").tag(CatalogPage.updated)
                    Text("最近上架").tag(CatalogPage.newest)
                }
                .pickerStyle(.segmented).frame(maxWidth: 230)
            } else {
                Text(page == .popular ? "这个月，大家都在看" :
                     page == .recommended ? "发现下一部好漫画" : "从上次读到的地方继续")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if page != .history {
                Button { showFilter = true } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 19)).padding(9)
                }
                .komiicActionStyle()
                .accessibilityLabel("筛选选项")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14).padding(.vertical, 6)
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
    @StateObject private var model = CatalogModel()

    private var visibleComics: [Comic] {
        model.comics.filter { !library.blockedComicIDs.contains($0.id) }
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
                } else if model.hasMore {
                    Button("载入更多") { Task { await model.load(feed: feed, filter: filter, reset: false) } }
                        .buttonStyle(.bordered).padding(.bottom, 14)
                }
            }
            .padding(14)
            .frame(maxWidth: 1_400)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .task(id: active ? filter : nil) {
            guard active, model.loadedFilter != filter else { return }
            await reload()
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
                    Picker("色气程度", selection: $draft) {
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
    @State private var keyword = ""
    @State private var comics: [Comic] = []
    @State private var loading = false
    @State private var error: String?
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            if let error {
                EmptyState(symbol: "wifi.exclamationmark", title: "搜索失败", message: error)
            } else if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "找一本想看的漫画", message: "输入漫画名、作者或关键词。")
            } else if comics.isEmpty && !loading {
                EmptyState(symbol: "text.magnifyingglass", title: "没有找到相关漫画", message: "换一个名称或更短的关键词试试。")
            } else {
                ComicGrid(comics: comics.filter { !library.blockedComicIDs.contains($0.id) }).padding(14)
            }
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("搜索")
        .searchable(text: $keyword, prompt: "漫画名 / 作者")
        .task(id: keyword) {
            comics = []; error = nil
            let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                let result = try await KomiicAPI().search(keyword: query)
                try Task.checkCancellation()
                comics = result
            } catch is CancellationError { return
            } catch let urlError as URLError where urlError.code == .cancelled { return
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
