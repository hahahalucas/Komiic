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

    init(fetchComics: @escaping (CatalogFeed, Int, ContentFilter) async throws -> [Comic] = { feed, offset, filter in
        try await KomiicAPI().catalog(feed: feed, offset: offset, filter: filter)
    }) {
        self.fetchComics = fetchComics
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
            guard generation == requestID else { return }
            offset = requestedOffset + results.count
            var ids = reset ? Set<String>() : Set(comics.map(\.id))
            let newComics = results.filter { ids.insert($0.id).inserted }
            if reset { comics = newComics }
            else { comics.append(contentsOf: newComics) }
            hasMore = !results.isEmpty && !newComics.isEmpty
            loadedFilter = filter
        } catch {
            // Only superseded requests are ignored. An active request that the network
            // cancels still needs a retry state instead of an endless initial spinner.
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
    @EnvironmentObject private var settings: ReaderSettings
    @State private var page: CatalogPage = .updated
    @State private var filter: ContentFilter = .all
    @State private var showFilter = false

    private var pageSelection: Binding<CatalogPage> {
        Binding(get: { page }, set: { select($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PillButton(title: "�������", selected: page.isUpdates) { select(.updated) }
                PillButton(title: "��������", selected: page == .popular) { select(.popular) }
                PillButton(title: "�Ƽ�����", selected: page == .recommended) { select(.recommended) }
                PillButton(title: "����Ķ�", selected: page == .history) { select(.history) }
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
                            CatalogFeedPage(feed: feed, filter: filter, active: page == item, mode: settings.contentMode)
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
                Picker("���·�ʽ", selection: pageSelection) {
                    Text("�������").tag(CatalogPage.updated)
                    Text("����ϼ�").tag(CatalogPage.newest)
                }
                .pickerStyle(.segmented).frame(maxWidth: 230)
            } else {
                Text(page == .popular ? "����£���Ҷ��ڿ�" :
                     page == .recommended ? "������һ��������" : "���ϴζ����ĵط�����")
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
                .accessibilityLabel("ɸѡѡ��")
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
    @EnvironmentObject private var settings: ReaderSettings
    @StateObject private var model: CatalogModel

    init(feed: CatalogFeed, filter: ContentFilter, active: Bool, mode: ComicContentMode) {
        self.feed = feed; self.filter = filter; self.active = active
        _model = StateObject(wrappedValue: CatalogModel { feed, offset, filter in
            try await KomiicAPI(mode: mode).catalog(feed: feed, offset: offset, filter: filter)
        })
    }

    private var visibleComics: [Comic] {
        model.comics.filter { !library.isBlocked($0) && !settings.shouldHide($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ComicGrid(comics: visibleComics)
                if let error = model.error {
                    EmptyState(symbol: "wifi.exclamationmark", title: "������ʱ������", message: error,
                               actionTitle: "��������", action: { Task { await reload() } })
                } else if model.loading || model.loadedFilter == nil {
                    ProgressView("��������������").font(.caption).padding(35)
                } else if visibleComics.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "��������", message: "���Ե���ɸѡ�����Ժ�ˢ�¡�")
                }
                if model.hasMore, !model.loading, model.loadedFilter != nil, model.error == nil {
                    Button("�������") { Task { await model.load(feed: feed, filter: filter, reset: false) } }
                        .buttonStyle(.bordered).padding(.bottom, 14)
                }
            }
            .padding(14)
            .frame(maxWidth: 1_400)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await reload() }
        .task(id: active ? filter : nil) {
            guard !Task.isCancelled, active, model.loadedFilter != filter else { return }
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
                Section("���ݷּ�") {
                    Picker("ɫ���̶�", selection: $draft) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }.pickerStyle(.menu)
                }
            }
            .navigationTitle("ɸѡѡ��").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("����") { draft = .all } }
                ToolbarItem(placement: .topBarTrailing) { Button("ȷ��") { selection = draft; dismiss() }.bold() }
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
    private var visibleComics: [Comic] { comics.filter { !library.isBlocked($0) && !settings.shouldHide($0) } }

    init(initialKeyword: String = "", onSelect: @escaping (Comic) -> Void) {
        self.onSelect = onSelect
        _keyword = State(initialValue: initialKeyword)
    }
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            if let error {
                EmptyState(symbol: "wifi.exclamationmark", title: "����ʧ��", message: error)
            } else if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "��һ���뿴������", message: "���������������߻�ؼ��ʡ�")
            } else if visibleComics.isEmpty && !loading {
                EmptyState(symbol: "text.magnifyingglass", title: "û���ҵ��������", message: "��һ�����ƻ���̵Ĺؼ������ԡ�")
            } else {
                ComicGrid(comics: visibleComics, onSelect: onSelect).padding(14)
            }
        }
        .background(KomiicTheme.canvas)
        .navigationTitle("����")
        .searchable(text: $keyword, isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "������ / ����")
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
