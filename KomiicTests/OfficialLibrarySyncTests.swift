import XCTest
@testable import Komiic

private actor OfficialLibraryStub {
    var identities: [ComicContentMode: String] = [.general: "general-account", .adult: "adult-account"]
    var favoritePages: [ComicContentMode: [Int: [Comic]]] = [:]
    var historyPages: [ComicContentMode: [Int: [OfficialReadingHistory]]] = [:]
    var failWrites = false
    var writes: [String] = []
    var shelfRows: [ComicContentMode: [Bookshelf]] = [:]
    var blockRows: [ComicContentMode: OfficialBlockedCollection] = [:]
    var identityRequests = 0
    var suspendNextFavorites = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?

    func client() -> OfficialLibraryClient {
        OfficialLibraryClient(accountID: { await self.identity($0) },
            favorites: { await self.favorites(mode: $0, offset: $1) },
            history: { await self.history(mode: $0, offset: $1) },
            setFavorite: { try await self.setFavorite(mode: $0, comicID: $1, favorite: $2) },
            recordProgress: { try await self.recordProgress(mode: $0, comicID: $1, chapterID: $2, page: $3) },
            shelves: { await self.shelves($0) },
            blockedComics: { await self.blocks($0) },
            createShelf: { try await self.createShelf($0, name: $1) },
            renameShelf: { try await self.renameShelf($0, id: $1, name: $2) },
            deleteShelf: { try await self.deleteShelf($0, id: $1) },
            setShelfComic: { try await self.setShelfComic($0, id: $1, comicID: $2, adding: $3) },
            setBlocked: { try await self.setBlocked($0, comicID: $1, blocked: $2) })
    }

    func identity(_ mode: ComicContentMode) -> String? { identityRequests += 1; return identities[mode] }
    func identityRequestCount() -> Int { identityRequests }
    func setCollections(mode: ComicContentMode, shelves: [Bookshelf], blocked: [Comic]) {
        shelfRows[mode] = shelves
        blockRows[mode] = OfficialBlockedCollection(ids: Set(blocked.map(\.id)), comics: blocked)
    }
    private func shelves(_ mode: ComicContentMode) -> [Bookshelf] { shelfRows[mode] ?? [] }
    private func blocks(_ mode: ComicContentMode) -> OfficialBlockedCollection { blockRows[mode] ?? OfficialBlockedCollection() }
    private func createShelf(_ mode: ComicContentMode, name: String) throws -> Bookshelf {
        if failWrites { throw URLError(.notConnectedToInternet) }
        let shelf = Bookshelf.official(id: "remote-\(name)", name: name)
        shelfRows[mode, default: []].append(shelf)
        writes.append("create:\(name)")
        return shelf
    }
    private func renameShelf(_ mode: ComicContentMode, id: String, name: String) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        if let index = shelfRows[mode]?.firstIndex(where: { $0.officialID == id }) { shelfRows[mode]?[index].name = name }
        writes.append("rename:\(id):\(name)")
    }
    private func deleteShelf(_ mode: ComicContentMode, id: String) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        shelfRows[mode]?.removeAll { $0.officialID == id }
        writes.append("delete:\(id)")
    }
    private func setShelfComic(_ mode: ComicContentMode, id: String, comicID: String, adding: Bool) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        if let index = shelfRows[mode]?.firstIndex(where: { $0.officialID == id }) {
            shelfRows[mode]?[index].comics.removeAll { $0.id == comicID }
            if adding { shelfRows[mode]?[index].comics.append(Comic(id: comicID, title: comicID)) }
        }
        writes.append("shelf:\(id):\(comicID):\(adding)")
    }
    private func setBlocked(_ mode: ComicContentMode, comicID: String, blocked: Bool) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        var collection = blockRows[mode] ?? OfficialBlockedCollection()
        collection.ids.remove(comicID)
        collection.comics.removeAll { $0.id == comicID }
        if blocked {
            collection.ids.insert(comicID)
            collection.comics.append(Comic(id: comicID, title: comicID))
        }
        blockRows[mode] = collection
        writes.append("block:\(comicID):\(blocked)")
    }
    func setIdentity(_ id: String?, mode: ComicContentMode) { identities[mode] = id }
    func setFavorites(_ comics: [Comic], mode: ComicContentMode, offset: Int = 0) {
        favoritePages[mode, default: [:]][offset] = comics
    }
    func setHistory(_ rows: [OfficialReadingHistory], mode: ComicContentMode) {
        historyPages[mode, default: [:]][0] = rows
    }
    func setFailingWrites(_ failing: Bool) { failWrites = failing }
    func successfulWrites() -> [String] { writes }
    func pauseNextFavoriteFetch() { suspendNextFavorites = true }
    func waitForPausedFetch() async {
        if suspended != nil { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }
    func resumeFavoriteFetch() { suspended?.resume(); suspended = nil }

    private func favorites(mode: ComicContentMode, offset: Int) async -> [Comic] {
        let result = favoritePages[mode]?[offset] ?? []
        if suspendNextFavorites && offset == 0 {
            suspendNextFavorites = false
            await withCheckedContinuation { continuation in
                suspended = continuation
                suspensionWaiter?.resume()
                suspensionWaiter = nil
            }
        }
        return result
    }
    private func history(mode: ComicContentMode, offset: Int) -> [OfficialReadingHistory] {
        historyPages[mode]?[offset] ?? []
    }
    private func setFavorite(mode: ComicContentMode, comicID: String, favorite: Bool) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        writes.append("\(mode.rawValue):\(identities[mode] ?? "nil"):favorite:\(comicID):\(favorite)")
        if !favorite {
            for offset in Array((favoritePages[mode] ?? [:]).keys) {
                favoritePages[mode]?[offset]?.removeAll { $0.id == comicID }
            }
        }
    }
    private func recordProgress(mode: ComicContentMode, comicID: String, chapterID: String, page: Int) throws {
        if failWrites { throw URLError(.notConnectedToInternet) }
        writes.append("\(mode.rawValue):\(identities[mode] ?? "nil"):progress:\(comicID):\(chapterID):\(page)")
    }
}

@MainActor
final class OfficialLibrarySyncTests: XCTestCase {
    func testWebsiteShelvesAndBlocksReplaceCloudStateWithoutOverwritingLocalArchive() async throws {
        let server = OfficialLibraryStub()
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        let local = Comic(id: "local", title: "本机")
        let localShelf = try XCTUnwrap(store.createShelf(name: "本机书柜"))
        store.addToShelf(local, shelfID: localShelf.id)
        store.toggleBlocked(local)
        let remote = Comic(id: "remote", title: "官网")
        var shelf = Bookshelf.official(id: "7", name: "官网书柜")
        shelf.comics = [remote]
        await server.setCollections(mode: .general, shelves: [shelf], blocked: [remote])
        await store.refreshOfficialLibrary()
        XCTAssertEqual(store.shelves.first?.officialID, "7")
        XCTAssertEqual(store.shelves.first?.comics.map(\.id), ["remote"])
        XCTAssertEqual(store.blockedComicIDs, ["remote"])
        await server.setCollections(mode: .general, shelves: [], blocked: [])
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.shelves.isEmpty)
        XCTAssertTrue(store.blockedComicIDs.isEmpty)
        store.resetOfficialSession()
        XCTAssertEqual(store.shelves.first?.id, localShelf.id)
        XCTAssertEqual(store.blockedComicIDs, ["local"])
    }

    func testNewShelfKeepsIdentityWhileMembershipAndRenameWriteToItsOfficialID() async throws {
        let server = OfficialLibraryStub()
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        await store.refreshOfficialLibrary()
        let shelf = try XCTUnwrap(store.createShelf(name: "新柜"))
        let comic = Comic(id: "comic", title: "漫画")
        store.toggleShelfMembership(comic, shelfID: shelf.id)
        store.renameShelf(id: shelf.id, name: "改名")
        await store.retryPendingOfficialChanges()
        XCTAssertEqual(store.pendingOfficialChangeCount, 0)
        await store.refreshOfficialLibrary()
        XCTAssertEqual(store.shelves.first?.id, shelf.id)
        XCTAssertEqual(store.shelves.first?.name, "改名")
        XCTAssertEqual(store.shelves.first?.comics.map(\.id), ["comic"])
        store.toggleShelfMembership(comic, shelfID: shelf.id)
        XCTAssertTrue(store.shelves.first?.comics.isEmpty == true)
        await store.retryPendingOfficialChanges()
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.shelves.first?.comics.isEmpty == true)
        let writes = await server.successfulWrites()
        XCTAssertTrue(writes.contains("shelf:remote-新柜:comic:false"))
        store.deleteShelf(id: shelf.id)
        await store.retryPendingOfficialChanges()
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.shelves.isEmpty)
        store.resetOfficialSession()
    }

    func testBlockWriteSurvivesRestartAndNeverUploadsToAnotherAccount() async throws {
        let server = OfficialLibraryStub()
        let url = try directory()
        let store = LibraryStore(directoryURL: url, officialClient: await server.client())
        await store.refreshOfficialLibrary()
        await server.setFailingWrites(true)
        store.toggleBlocked(Comic(id: "blocked", title: "屏蔽"))
        await store.retryPendingOfficialChanges()
        XCTAssertEqual(store.pendingOfficialChangeCount, 1)
        XCTAssertNil(store.lastError)
        store.resetOfficialSession()
        let restored = LibraryStore(directoryURL: url, officialClient: await server.client())
        await server.setIdentity("other", mode: .general)
        await server.setFailingWrites(false)
        await restored.refreshOfficialLibrary()
        XCTAssertTrue(restored.blockedComicIDs.isEmpty)
        XCTAssertEqual(restored.pendingOfficialChangeCount, 1)
        await server.setIdentity("general-account", mode: .general)
        await restored.refreshOfficialLibrary()
        XCTAssertEqual(restored.blockedComicIDs, ["blocked"])
        XCTAssertEqual(restored.pendingOfficialChangeCount, 0)
        restored.unblock(comicID: "blocked")
        await restored.retryPendingOfficialChanges()
        await restored.refreshOfficialLibrary()
        XCTAssertTrue(restored.blockedComicIDs.isEmpty)
        restored.resetOfficialSession()
    }

    func testInitialLibraryLoadsOnceAndForegroundWithoutPendingEditsDoesNotQueryAccount() async throws {
        let server = OfficialLibraryStub()
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        await store.refreshOfficialLibrary(force: false)
        await store.refreshOfficialLibrary(force: false)
        await store.retryPendingOfficialChanges()
        let firstCount = await server.identityRequestCount()
        XCTAssertEqual(firstCount, 1)
        await store.refreshOfficialLibrary()
        let refreshedCount = await server.identityRequestCount()
        XCTAssertEqual(refreshedCount, 2)
        store.resetOfficialSession()
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KomiicSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSignedInCloudPagesAreAuthoritativeAndLocalArchiveSurvivesLogout() async throws {
        let url = try directory()
        let server = OfficialLibraryStub()
        let local = Comic(id: "local", title: "本机收藏")
        let cloud = Comic(id: "cloud", title: "官网收藏")
        await server.setFavorites([cloud], mode: .general)
        await server.setFavorites([Comic(id: "later-page", title: "后续页")], mode: .general, offset: 30)
        let store = LibraryStore(directoryURL: url, officialClient: await server.client())
        store.toggleFavorite(local)
        await store.refreshOfficialLibrary()
        XCTAssertEqual(Set(store.favorites.map(\.id)), ["cloud", "later-page"])
        XCTAssertEqual(store.officialAccountID, "general-account")

        store.resetOfficialSession()
        XCTAssertEqual(store.favorites.map(\.id), ["local"])
        XCTAssertEqual(LibraryStore(directoryURL: url).favorites.map(\.id), ["local"])
        await server.setIdentity("different-account", mode: .general)
        await server.setFavorites([], mode: .general)
        await server.setFavorites([], mode: .general, offset: 30)
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertEqual(store.officialAccountID, "different-account")
    }

    func testWebsiteFavoriteAndHistoryRemovalsDoNotReviveLocalCopies() async throws {
        let server = OfficialLibraryStub()
        let comic = Comic(id: "shared", title: "已移除")
        let chapter = Chapter(id: "chapter")
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        store.toggleFavorite(comic)
        store.recordProgress(comic: comic, chapter: chapter, page: 2, totalPages: 8)
        await server.setFavorites([comic], mode: .general)
        await server.setHistory([OfficialReadingHistory(comic: comic, chapters: [
            OfficialChapterProgress(chapterId: chapter.id, page: 5, updatedAt: "2026-11-22T06:30:00Z")
        ], lastDate: "2026-11-22T06:30:00Z")], mode: .general)
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.isFavorite(comic))
        XCTAssertEqual(store.history.first?.page, 5)
        await server.setFavorites([], mode: .general)
        await server.setHistory([], mode: .general)
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.readChapterIDs.isEmpty)
        store.toggleFavorite(Comic(id: "cloud-only", title: "仅官网"))
        store.recordProgress(comic: comic, chapter: chapter, page: 6, totalPages: 8)
        store.resetOfficialSession()
        XCTAssertEqual(store.favorites.map(\.id), [comic.id])
        XCTAssertEqual(store.history.first?.page, 2)
    }

    func testCloudHistoryUsesLatestChapterAndPreservesUnknownPageTotal() async throws {
        let server = OfficialLibraryStub()
        let comic = Comic(id: "history", title: "官网最近阅读")
        let history = OfficialReadingHistory(comic: comic, chapters: [
            OfficialChapterProgress(chapterId: "newest", page: 8, updatedAt: "2026-11-22T06:30:00.500Z"),
            OfficialChapterProgress(chapterId: "older", page: 3, updatedAt: "2026-11-20T06:30:00Z")
        ], lastDate: "2026-11-22T06:30:00.500Z")
        await server.setHistory([history], mode: .adult)
        let store = LibraryStore(directoryURL: try directory(), initialMode: .adult, officialClient: await server.client())
        await store.refreshOfficialLibrary()
        XCTAssertEqual(store.history.first?.chapter.id, "newest")
        XCTAssertEqual(store.history.first?.page, 8)
        XCTAssertEqual(store.history.first?.totalPages, 0)
        XCTAssertEqual(store.readChapterIDs, ["newest", "older"])
        store.selectMode(.general)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.readChapterIDs.isEmpty)
    }

    func testRecentReadingRemovalSurvivesCloudRefreshAndIsScopedToTheAccount() async throws {
        let url = try directory()
        let server = OfficialLibraryStub()
        let client = await server.client()
        let comic = Comic(id: "shared", title: "最近阅读")
        let chapter = Chapter(id: "chapter")
        await server.setHistory([OfficialReadingHistory(comic: comic, chapters: [
            OfficialChapterProgress(chapterId: chapter.id, page: 5, updatedAt: nil)
        ], lastDate: nil)], mode: .general)
        let store = LibraryStore(directoryURL: url, officialClient: client, sessionScope: { _ in "same-session" })
        await store.refreshOfficialLibrary()
        store.removeFromRecentReading(comicID: comic.id)
        XCTAssertTrue(store.recentReading.isEmpty)
        XCTAssertEqual(store.pendingOfficialChangeCount, 0)
        store.flushSnapshots()

        let restored = LibraryStore(directoryURL: url, officialClient: client, sessionScope: { _ in "same-session" })
        XCTAssertTrue(restored.recentReading.isEmpty)
        XCTAssertEqual(restored.progress(for: comic.id)?.page, 5)
        await restored.refreshOfficialLibrary()
        XCTAssertTrue(restored.recentReading.isEmpty)

        await server.setIdentity("other-account", mode: .general)
        await restored.refreshOfficialLibrary()
        XCTAssertTrue(restored.isInRecentReading(comicID: comic.id))
        await server.setIdentity("general-account", mode: .general)
        await restored.refreshOfficialLibrary()
        XCTAssertFalse(restored.isInRecentReading(comicID: comic.id))
        restored.recordProgress(comic: comic, chapter: chapter, page: 6, totalPages: 10)
        XCTAssertEqual(restored.recentReading.first?.page, 6)
        restored.resetOfficialSession()
    }

    func testFailedMutationSurvivesRestartAndNeverReplaysForAnotherAccount() async throws {
        let url = try directory()
        let server = OfficialLibraryStub()
        let comic = Comic(id: "retry", title: "待同步")
        let store = LibraryStore(directoryURL: url, officialClient: await server.client())
        await store.refreshOfficialLibrary()
        await server.setFailingWrites(true)
        store.toggleFavorite(comic)
        await store.retryPendingOfficialChanges()
        XCTAssertEqual(store.pendingOfficialChangeCount, 1)
        XCTAssertNotNil(store.officialSyncError)
        XCTAssertTrue(store.isFavorite(comic))
        store.resetOfficialSession()

        let restored = LibraryStore(directoryURL: url, officialClient: await server.client())
        await server.setFailingWrites(false)
        await server.setIdentity("another-account", mode: .general)
        await restored.refreshOfficialLibrary()
        XCTAssertEqual(restored.pendingOfficialChangeCount, 1)
        XCTAssertFalse(restored.isFavorite(comic))
        let writesForWrongAccount = await server.successfulWrites()
        XCTAssertTrue(writesForWrongAccount.isEmpty)
        await server.setIdentity("general-account", mode: .general)
        await restored.refreshOfficialLibrary()
        XCTAssertEqual(restored.pendingOfficialChangeCount, 0)
        let retried = await server.successfulWrites()
        XCTAssertEqual(retried, ["REGULAR:general-account:favorite:retry:true"])
    }

    func testProgressCoalescesAndUsesTheAccountOfItsCapturedMode() async throws {
        let server = OfficialLibraryStub()
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        await store.refreshOfficialLibrary()
        store.selectMode(.adult)
        await store.refreshOfficialLibrary()
        let comic = Comic(id: "general", title: "一般漫画")
        let chapter = Chapter(id: "chapter")
        store.recordProgress(comic: comic, chapter: chapter, page: 1, totalPages: 12, mode: .general)
        store.recordProgress(comic: comic, chapter: chapter, page: 7, totalPages: 12, mode: .general)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.pendingOfficialChangeCount, 1)
        await store.retryPendingOfficialChanges()
        let writes = await server.successfulWrites()
        XCTAssertEqual(writes, ["REGULAR:general-account:progress:general:chapter:7"])
        XCTAssertEqual(store.officialAccountID, "adult-account")
        store.resetOfficialSession()
    }

    func testCompletedFavoriteRemovalStillWinsOverAnOlderInFlightSnapshot() async throws {
        let server = OfficialLibraryStub()
        let comic = Comic(id: "cloud", title: "官网收藏")
        await server.setFavorites([comic], mode: .general)
        let store = LibraryStore(directoryURL: try directory(), officialClient: await server.client())
        await store.refreshOfficialLibrary()
        XCTAssertTrue(store.isFavorite(comic))
        await server.pauseNextFavoriteFetch()
        let refresh = Task { await store.refreshOfficialLibrary() }
        await server.waitForPausedFetch()
        store.toggleFavorite(comic)
        await store.retryPendingOfficialChanges()
        XCTAssertEqual(store.pendingOfficialChangeCount, 0)
        await server.resumeFavoriteFetch()
        await refresh.value
        XCTAssertFalse(store.isFavorite(comic))
        store.resetOfficialSession()
    }
}
