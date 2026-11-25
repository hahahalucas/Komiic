import SwiftUI

/// Kept above navigation and tab identities for the lifetime of this app window.
@MainActor
final class AppContentStore: ObservableObject {
    private var catalogs: [String: CatalogModel] = [:]
    private var accounts: [ComicContentMode: AccountProfileModel] = [:]
    @Published private(set) var revision = 0
    private let snapshots: AppSnapshotStore?
    private let sessionScope: (ComicContentMode) -> String?
    private var scopes: [ComicContentMode: String] = [:]

    init(snapshots: AppSnapshotStore? = .shared,
         sessionScope: @escaping (ComicContentMode) -> String? = { SessionCookieStore.shared.scope(for: $0) }) {
        self.snapshots = snapshots
        self.sessionScope = sessionScope
        for mode in ComicContentMode.allCases { scopes[mode] = sessionScope(mode) ?? "guest" }
    }

    func catalog(feed: CatalogFeed, mode: ComicContentMode) -> CatalogModel {
        let key = "\(mode.rawValue):\(feed.rawValue):\(sessionScope(mode) ?? "guest")"
        if let cached = catalogs[key] { return cached }
        let expectedScope = sessionScope(mode)
        let scopeProvider = sessionScope
        let model = CatalogModel(snapshots: snapshots, cachePrefix: key,
            scopeIsCurrent: { scopeProvider(mode) == expectedScope }) { feed, offset, filter in
            try await KomiicAPI(mode: mode).catalog(feed: feed, offset: offset, filter: filter)
        }
        catalogs[key] = model
        return model
    }

    func account(mode: ComicContentMode) -> AccountProfileModel {
        if let cached = accounts[mode] { return cached }
        let scopeProvider = sessionScope
        let model = AccountProfileModel(mode: mode, snapshots: snapshots, sessionScope: { scopeProvider(mode) })
        accounts[mode] = model
        return model
    }

    func resetAccounts() {
        accounts.values.forEach { $0.reset() }
    }
    func flushSnapshots() { snapshots?.flush() }

    func synchronizeSessionScopes() {
        var changed = false
        for mode in ComicContentMode.allCases {
            let scope = sessionScope(mode) ?? "guest"
            guard scopes[mode] != scope else { continue }
            scopes[mode] = scope
            let keys = catalogs.keys.filter { $0.hasPrefix(mode.rawValue + ":") }
            for key in keys { catalogs.removeValue(forKey: key)?.cancel() }
            accounts[mode]?.synchronizeSessionScope()
            changed = true
        }
        if changed { revision += 1 }
    }
}

@MainActor
final class AccountProfileModel: ObservableObject {
    @Published private(set) var profile: KomiicAccountProfile?
    @Published private(set) var connected = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private(set) var hasLoaded = false
    private let mode: ComicContentMode
    private let fetchProfile: () async throws -> KomiicAccountProfile?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private let snapshots: AppSnapshotStore?
    private let sessionScope: () -> String?
    private var cachedScope: String?

    init(mode: ComicContentMode, snapshots: AppSnapshotStore? = nil,
         sessionScope: @escaping () -> String? = { nil },
         fetchProfile: (() async throws -> KomiicAccountProfile?)? = nil) {
        self.mode = mode
        self.snapshots = snapshots
        self.sessionScope = sessionScope
        cachedScope = sessionScope()
        self.fetchProfile = fetchProfile ?? { try await KomiicAPI(mode: mode).accountProfile() }
        restore()
    }

    func load(force: Bool = false) async {
        synchronizeSessionScope()
        if let request { await request.value; return }
        guard force || !hasLoaded else { return }
        let id = generation
        loading = true
        error = nil
        let task = Task {
            defer { if generation == id { loading = false; hasLoaded = true } }
            do {
                let result = try await fetchProfile()
                try Task.checkCancellation()
                guard generation == id, sessionScope() == cachedScope else { return }
                profile = result
                connected = result != nil
                if let key = cacheKey {
                    if let result { snapshots?.save(result, key: key) }
                    else { snapshots?.remove(key: key) }
                }
            } catch is CancellationError {
            } catch let problem as URLError where problem.code == .cancelled {
            } catch KomiicError.authenticationRequired {
                guard generation == id else { return }
                profile = nil; connected = false
                if let key = cacheKey { snapshots?.remove(key: key) }
            } catch {
                guard generation == id else { return }
                // A failed refresh leaves the already displayed profile in place.
                self.error = error.localizedDescription
            }
        }
        request = task
        await task.value
        if generation == id { request = nil }
    }

    func reset() {
        if let key = cacheKey { snapshots?.remove(key: key) }
        generation = UUID()
        request?.cancel()
        request = nil
        profile = nil
        connected = false
        loading = false
        error = nil
        hasLoaded = false
    }

    func synchronizeSessionScope() {
        let scope = sessionScope()
        guard scope != cachedScope else { return }
        generation = UUID(); request?.cancel(); request = nil
        profile = nil; connected = false; loading = false; error = nil; hasLoaded = false
        cachedScope = scope
        restore()
    }
    private var cacheKey: String? { cachedScope.map { "account:\(mode.rawValue):\($0)" } }
    private func restore() {
        guard let key = cacheKey, let saved = snapshots?.load(KomiicAccountProfile.self, key: key) else { return }
        profile = saved; connected = true; hasLoaded = true
    }
}
