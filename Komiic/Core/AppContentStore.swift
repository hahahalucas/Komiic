import SwiftUI

/// Kept above navigation and tab identities for the lifetime of this app window.
@MainActor
final class AppContentStore: ObservableObject {
    private var catalogs: [String: CatalogModel] = [:]
    private var accounts: [ComicContentMode: AccountProfileModel] = [:]

    func catalog(feed: CatalogFeed, mode: ComicContentMode) -> CatalogModel {
        let key = "\(mode.rawValue):\(feed.rawValue)"
        if let cached = catalogs[key] { return cached }
        let model = CatalogModel { feed, offset, filter in
            try await KomiicAPI(mode: mode).catalog(feed: feed, offset: offset, filter: filter)
        }
        catalogs[key] = model
        return model
    }

    func account(mode: ComicContentMode) -> AccountProfileModel {
        if let cached = accounts[mode] { return cached }
        let model = AccountProfileModel(mode: mode)
        accounts[mode] = model
        return model
    }

    func resetAccounts() {
        accounts.values.forEach { $0.reset() }
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

    init(mode: ComicContentMode, fetchProfile: (() async throws -> KomiicAccountProfile?)? = nil) {
        self.mode = mode
        self.fetchProfile = fetchProfile ?? { try await KomiicAPI(mode: mode).accountProfile() }
    }

    func load(force: Bool = false) async {
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
                guard generation == id else { return }
                profile = result
                connected = result != nil
            } catch is CancellationError {
            } catch let problem as URLError where problem.code == .cancelled {
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
        generation = UUID()
        request?.cancel()
        request = nil
        profile = nil
        connected = false
        loading = false
        error = nil
        hasLoaded = false
    }
}
