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
    @Published private(set) var loadingQuota = false
    @Published private(set) var quotaRefreshFailed = false
    private(set) var hasLoaded = false
    private let mode: ComicContentMode
    private let fetchProfile: () async throws -> KomiicAccountProfile?
    private let statisticsAPI: KomiicAPI?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private let snapshots: AppSnapshotStore?
    private let sessionScope: () -> String?
    private var cachedScope: String?

    var imageSourceAccount: (owner: ImageSourceOwner, quota: ImageReadingQuota?)? {
        guard let profile, let cachedScope, sessionScope() == cachedScope else { return nil }
        return (ImageSourceOwner(id: profile.id, sessionScope: cachedScope), profile.imageQuota)
    }

    convenience init(mode: ComicContentMode, fetchProfile: (() async throws -> KomiicAccountProfile?)? = nil) {
        self.init(mode: mode, snapshots: nil, sessionScope: { nil }, fetchProfile: fetchProfile)
    }

    init(mode: ComicContentMode, snapshots: AppSnapshotStore?,
         sessionScope: @escaping () -> String?,
         api: KomiicAPI? = nil,
         fetchProfile: (() async throws -> KomiicAccountProfile?)? = nil) {
        let api = api ?? KomiicAPI(mode: mode)
        self.mode = mode
        self.snapshots = snapshots
        self.sessionScope = sessionScope
        cachedScope = sessionScope()
        self.fetchProfile = fetchProfile ?? { try await api.accountProfile() }
        statisticsAPI = fetchProfile == nil ? api : nil
        restore()
    }

    func load(force: Bool = false, refreshQuota: Bool = false) async {
        synchronizeSessionScope()
        if let request {
            let updatingQuota = !loading
            await request.value
            if force, updatingQuota, !Task.isCancelled { await load(force: true) }
            return
        }
        let missingStatistics = profile.map { $0.readingStats == nil || $0.imageQuota == nil || $0.messageStats == nil } ?? (error != nil)
        let needsProfile = force || !hasLoaded || (refreshQuota && statisticsAPI != nil && missingStatistics)
        guard needsProfile || (refreshQuota && profile != nil && statisticsAPI != nil) else { return }
        let id = generation
        if needsProfile {
            loading = true
            error = nil
        }
        let task = Task {
            if needsProfile {
                await loadProfile(generation: id)
            } else if let statisticsAPI {
                await loadImageQuota(using: statisticsAPI, generation: id)
            }
            if generation == id {
                request = nil
                if needsProfile { hasLoaded = true }
                loading = false
            }
        }
        request = task
        await task.value
    }

    private func loadProfile(generation id: UUID) async {
        do {
            let result = try await fetchProfile()
            guard isCurrent(id) else { return }
            guard var result else {
                profile = nil
                connected = false
                if let key = cacheKey { snapshots?.remove(key: key) }
                return
            }
            if let profile, profile.id == result.id {
                result.readingStats = result.readingStats ?? profile.readingStats
                result.imageQuota = result.imageQuota ?? profile.imageQuota
                result.messageStats = result.messageStats ?? profile.messageStats
            }
            profile = result
            connected = true
            saveProfile()

            if let statisticsAPI {
                async let reading: Void = loadReadingStats(using: statisticsAPI, generation: id)
                async let messages: Void = loadMessageStats(using: statisticsAPI, generation: id)
                async let quota: Void = loadImageQuota(using: statisticsAPI, generation: id)
                _ = await (reading, messages, quota)
                guard isCurrent(id) else { return }
                saveProfile()
            }
        } catch is CancellationError {
        } catch let problem as URLError where problem.code == .cancelled {
        } catch KomiicError.authenticationRequired {
            guard isCurrent(id) else { return }
            profile = nil
            connected = false
            if let key = cacheKey { snapshots?.remove(key: key) }
        } catch {
            guard isCurrent(id) else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadReadingStats(using api: KomiicAPI, generation id: UUID) async {
        guard let stats = try? await api.accountReadingStats(), isCurrent(id) else { return }
        profile?.readingStats = stats
    }

    private func loadMessageStats(using api: KomiicAPI, generation id: UUID) async {
        guard let stats = try? await api.accountMessageStats(), isCurrent(id) else { return }
        profile?.messageStats = stats
    }

    private func loadImageQuota(using api: KomiicAPI, generation id: UUID) async {
        guard isCurrent(id), let accountID = profile?.id else { return }
        loadingQuota = true
        defer { if generation == id { loadingQuota = false } }
        let quota = try? await api.imageReadingQuota(accountID: accountID)
        guard isCurrent(id) else { return }
        quotaRefreshFailed = quota == nil
        if let quota {
            profile?.imageQuota = quota
            saveProfile()
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && generation == id && sessionScope() == cachedScope
    }

    private func saveProfile() {
        if let profile, let key = cacheKey { snapshots?.save(profile, key: key) }
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
        loadingQuota = false
        quotaRefreshFailed = false
        hasLoaded = false
    }

    func synchronizeSessionScope() {
        let scope = sessionScope()
        guard scope != cachedScope else { return }
        generation = UUID(); request?.cancel(); request = nil
        profile = nil; connected = false; loading = false; error = nil; hasLoaded = false
        loadingQuota = false
        quotaRefreshFailed = false
        cachedScope = scope
        restore()
    }
    private var cacheKey: String? { cachedScope.map { "account:\(mode.rawValue):\($0)" } }
    private func restore() {
        guard let key = cacheKey, let saved = snapshots?.load(KomiicAccountProfile.self, key: key) else { return }
        profile = saved; connected = true; hasLoaded = true
    }
}
