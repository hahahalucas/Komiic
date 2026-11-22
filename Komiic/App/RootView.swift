import SwiftUI
import UserNotifications

enum AppTab: String, CaseIterable, Identifiable {
    case home, favorites, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"; case .favorites: return "喜爱"; case .library: return "资料库"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"; case .favorites: return "heart"
        case .library: return "books.vertical"
        }
    }
}

private enum LibrarySection: String {
    case bookmarks, shelves
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: AppTab = .home
    @State private var librarySection: LibrarySection = .bookmarks
    @State private var account = false
    @State private var notifications = false
    @State private var seenCompleted: Set<String> = []
    @State private var started = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                modernTabs.tabBarMinimizeBehavior(.onScrollDown)
            } else if #available(iOS 18.0, *) {
                modernTabs
            } else {
                classicTabs
            }
        }
        .sheet(isPresented: $account) { AccountView() }
        .sheet(isPresented: $notifications) { ActivityView() }
        .alert("未能完成操作", isPresented: Binding(get: { library.lastError != nil || downloads.lastError != nil }, set: { visible in
            if !visible { library.lastError = nil; downloads.lastError = nil }
        })) {
            Button("知道了") { library.lastError = nil; downloads.lastError = nil }
        } message: { Text(library.lastError ?? downloads.lastError ?? "请稍后重试。") }
        .task { seenCompleted = completedIDs; started = true }
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
            if phase == .active {
                Task { await WebCookieBridge.synchronize() }
                downloads.applyCachePolicy(settings.cachePolicy)
            }
        }
    }

    // System navigation adopts Liquid Glass when linked with the iOS 26 SDK.
    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selected) {
            Tab("首页", systemImage: AppTab.home.symbol, value: AppTab.home) { screen(.home) }
            Tab("喜爱", systemImage: AppTab.favorites.symbol, value: AppTab.favorites) { screen(.favorites) }
            Tab("资料库", systemImage: AppTab.library.symbol, value: AppTab.library) { screen(.library) }
        }
        .tabViewStyle(.tabBarOnly)
    }

    private var classicTabs: some View {
        TabView(selection: $selected) {
            ForEach(AppTab.allCases) { tab in
                screen(tab).tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
            }
        }
    }

    private var completedIDs: Set<String> { Set(downloads.items.filter { $0.status == .completed }.map(\.id)) }
    private func screen(_ tab: AppTab) -> some View {
        TabRootScreen(tab: tab, librarySection: $librarySection,
                      showAccount: { account = true }, showNotifications: { notifications = true })
    }
}

private struct TabRootScreen: View {
    let tab: AppTab
    @Binding var librarySection: LibrarySection
    let showAccount: () -> Void
    let showNotifications: () -> Void
    @State private var path: [Comic] = []
    @State private var search = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KomiicTheme.canvas)
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { search = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索漫画")
                        Button(action: showNotifications) { Image(systemName: "bell") }.accessibilityLabel("阅读动态")
                        Button(action: showAccount) { Image(systemName: "person.crop.circle") }.accessibilityLabel("账号与设置")
                    }
                }
                .navigationDestination(for: Comic.self) { ComicDetailView(comic: $0) }
                .navigationDestination(isPresented: $search) { SearchView() }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .home: CatalogView()
        case .favorites: FavoritesView()
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
