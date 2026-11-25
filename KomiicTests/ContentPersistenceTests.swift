import XCTest
@testable import Komiic

@MainActor
final class ContentPersistenceTests: XCTestCase {
    func testCatalogRestoresAfterRestartWithoutFetchingAndRefreshStillWorks() async throws {
        let directory = try temporaryDirectory()
        let cache = AppSnapshotStore(directory: directory)
        let initial = CatalogModel(snapshots: cache, cachePrefix: "general:updated:user") { _, _, _ in
            [Comic(id: "saved", title: "已保存")]
        }
        await initial.loadIfNeeded(feed: .updated, filter: .all)
        cache.flush()
        var requests = 0
        let restarted = CatalogModel(snapshots: AppSnapshotStore(directory: directory), cachePrefix: "general:updated:user") { _, _, _ in
            requests += 1
            return [Comic(id: "fresh", title: "新内容")]
        }
        XCTAssertEqual(restarted.comics.map(\.id), ["saved"])
        await restarted.loadIfNeeded(feed: .updated, filter: .all)
        XCTAssertEqual(requests, 0)
        await restarted.load(feed: .updated, filter: .all, reset: true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(restarted.comics.map(\.id), ["fresh"])
    }

    func testCatalogCacheKeepsFilterModeAndAccountSeparateAndRestoresPagination() async throws {
        let cache = AppSnapshotStore(directory: try temporaryDirectory())
        let model = CatalogModel(snapshots: cache, cachePrefix: "REGULAR:updated:A") { _, _, filter in
            filter == .all ? [Comic(id: "1", title: "一"), Comic(id: "2", title: "二")] : [Comic(id: "filtered", title: "筛选")]
        }
        await model.loadIfNeeded(feed: .updated, filter: .all)
        await model.loadIfNeeded(feed: .updated, filter: .general)
        await model.loadIfNeeded(feed: .updated, filter: .all)
        XCTAssertEqual(model.comics.map(\.id), ["1", "2"])
        var offset = -1
        let restarted = CatalogModel(snapshots: cache, cachePrefix: "REGULAR:updated:A") { _, start, _ in
            offset = start
            return [Comic(id: "3", title: "三")]
        }
        await restarted.load(feed: .updated, filter: .all, reset: false)
        XCTAssertEqual(offset, 2)
        XCTAssertEqual(restarted.comics.map(\.id), ["1", "2", "3"])
        XCTAssertTrue(CatalogModel(snapshots: cache, cachePrefix: "H_MANGA:updated:A").comics.isEmpty)
        XCTAssertTrue(CatalogModel(snapshots: cache, cachePrefix: "REGULAR:updated:B").comics.isEmpty)
    }

    func testAccountChangeDuringCatalogRequestCannotWriteItsResponse() async throws {
        let cache = AppSnapshotStore(directory: try temporaryDirectory())
        var current = true
        let model = CatalogModel(snapshots: cache, cachePrefix: "old-account", scopeIsCurrent: { current }) { _, _, _ in
            current = false
            return [Comic(id: "old", title: "旧账号")]
        }
        await model.loadIfNeeded(feed: .updated, filter: .all)
        cache.flush()
        XCTAssertTrue(model.comics.isEmpty)
        XCTAssertTrue(CatalogModel(snapshots: cache, cachePrefix: "old-account").comics.isEmpty)
    }

    func testCorruptCatalogCacheFallsBackToNetwork() async throws {
        let directory = try temporaryDirectory()
        let cache = AppSnapshotStore(directory: directory)
        cache.save(CatalogSnapshot(comics: [], offset: 0, hasMore: true), key: "catalog:key:-1")
        cache.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        var requests = 0
        let model = CatalogModel(snapshots: cache, cachePrefix: "key") { _, _, _ in
            requests += 1; return [Comic(id: "ok", title: "恢复")]
        }
        await model.loadIfNeeded(feed: .updated, filter: .all)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.comics.first?.id, "ok")
    }

    func testAccountRestoresOfflineAndLogoutDeletesItsSnapshot() async throws {
        let cache = AppSnapshotStore(directory: try temporaryDirectory())
        let saved = profile("user-A")
        let initial = AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "scope-A" }) { saved }
        await initial.load()
        cache.flush()
        var requests = 0
        let restarted = AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "scope-A" }) {
            requests += 1; throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(restarted.profile?.id, "user-A")
        XCTAssertTrue(restarted.connected)
        await restarted.load()
        XCTAssertEqual(requests, 0)
        await restarted.load(force: true)
        XCTAssertNotNil(restarted.error)
        XCTAssertEqual(restarted.profile?.id, "user-A")
        restarted.reset()
        XCTAssertNil(AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "scope-A" }).profile)
    }

    func testAccountCacheDoesNotCrossSessionsOrContentModes() async throws {
        let cache = AppSnapshotStore(directory: try temporaryDirectory())
        let saved = profile("A")
        let initial = AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "A" }) { saved }
        await initial.load()
        cache.flush()
        XCTAssertNil(AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "B" }).profile)
        XCTAssertNil(AccountProfileModel(mode: .adult, snapshots: cache, sessionScope: { "A" }).profile)
        XCTAssertNil(AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { nil }).profile)
    }

    func testDelayedResponseFromPreviousAccountCannotRestoreIt() async throws {
        let cache = AppSnapshotStore(directory: try temporaryDirectory())
        let gate = ProfileGate()
        var scope: String? = "old"
        let model = AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { scope }) { await gate.fetch() }
        let pending = Task { await model.load() }
        await gate.waitUntilStarted()
        scope = "new"
        model.synchronizeSessionScope()
        await gate.finish(profile("old-account"))
        await pending.value
        XCTAssertNil(model.profile)
        XCTAssertFalse(model.connected)
        XCTAssertNil(AccountProfileModel(mode: .general, snapshots: cache, sessionScope: { "new" }).profile)
    }

    func testOfficialCollectionsRestoreWithoutWaitingForNetworkAndClearOnLogout() async throws {
        let directory = try temporaryDirectory()
        var identityRequests = 0
        let client = OfficialLibraryClient(accountID: { _ in identityRequests += 1; return "account" },
            favorites: { _, offset in offset == 0 ? [Comic(id: "favorite", title: "收藏")] : [] },
            history: { _, _ in [] }, setFavorite: { _, _, _ in }, recordProgress: { _, _, _, _ in })
        let first = LibraryStore(directoryURL: directory, officialClient: client, sessionScope: { _ in "same-session" })
        await first.refreshOfficialLibrary(force: true)
        first.flushSnapshots()
        let restarted = LibraryStore(directoryURL: directory, officialClient: client, sessionScope: { _ in "same-session" })
        XCTAssertEqual(restarted.favorites.map(\.id), ["favorite"])
        await restarted.refreshOfficialLibrary(force: false)
        XCTAssertEqual(identityRequests, 1)
        XCTAssertTrue(LibraryStore(directoryURL: directory, officialClient: client, sessionScope: { _ in "other-session" }).favorites.isEmpty)
        restarted.resetOfficialSession()
        XCTAssertTrue(LibraryStore(directoryURL: directory, officialClient: client, sessionScope: { _ in "same-session" }).favorites.isEmpty)
    }

    private func profile(_ id: String) -> KomiicAccountProfile {
        KomiicAccountProfile(id: id, username: id, email: "test@example.invalid", dateCreated: "2026-01-01",
            profileImageURL: nil, profileText: nil, readComicCount: 2, readChapterCount: 3,
            imageReadCount: 4, imageReadLimit: 100, resetAt: Date(), commentCount: 0, commentLikes: 0,
            favoriteCount: 1, bookmarkCount: 0, folderCount: 0, followedFolderCount: 0,
            topCategories: [], warningPreferences: [])
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KomiicContentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor ProfileGate {
    private var continuation: CheckedContinuation<KomiicAccountProfile?, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func fetch() async -> KomiicAccountProfile? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ profile: KomiicAccountProfile) { continuation?.resume(returning: profile); continuation = nil }
}
