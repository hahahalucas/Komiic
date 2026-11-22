import XCTest
@testable import Komiic

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KomiicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFavoritesBookmarksShelvesAndProgressSurviveReload() throws {
        let url = try directory()
        let comic = Comic(id: "comic-1", title: "测试")
        let chapter = Chapter(id: "chapter-1", serial: "1")
        let store = LibraryStore(directoryURL: url)
        store.toggleFavorite(comic)
        store.toggleBookmark(comic: comic, chapter: chapter, page: 3)
        let shelf = try XCTUnwrap(store.createShelf(name: "  正在看  "))
        store.addToShelf(comic, shelfID: shelf.id)
        store.addToShelf(comic, shelfID: shelf.id)
        store.recordProgress(comic: comic, chapter: chapter, page: 3, totalPages: 10)
        store.toggleBlocked(comic)

        let restored = LibraryStore(directoryURL: url)
        XCTAssertNil(restored.lastError)
        XCTAssertTrue(restored.isFavorite(comic))
        XCTAssertTrue(restored.isBookmarked(chapterID: chapter.id, page: 3))
        XCTAssertEqual(restored.shelves.first?.name, "正在看")
        XCTAssertEqual(restored.shelves.first?.comics.count, 1)
        XCTAssertEqual(restored.progress(for: comic.id)?.page, 3)
        XCTAssertEqual(restored.readComicCount, 1)
        XCTAssertEqual(restored.readChapterCount, 1)
        XCTAssertTrue(restored.isBlocked(comic))
    }

    func testProgressClampsPagesAndCountsEachChapterOnce() throws {
        let store = LibraryStore(directoryURL: try directory())
        let comic = Comic(id: "comic", title: "测试")
        let chapter = Chapter(id: "chapter", serial: "1")
        store.recordProgress(comic: comic, chapter: chapter, page: -100, totalPages: 5)
        XCTAssertEqual(store.progress(for: comic.id)?.page, 0)
        store.recordProgress(comic: comic, chapter: chapter, page: 100, totalPages: 5)
        XCTAssertEqual(store.progress(for: comic.id)?.page, 4)
        XCTAssertEqual(store.progress(for: comic.id)?.isFinished, true)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.readChapterCount, 1)
        store.recordProgress(comic: comic, chapter: chapter, page: 0, totalPages: 0)
        XCTAssertEqual(store.progress(for: comic.id)?.page, 4)
    }

    func testJumpedReadChaptersAndLastRevisitedChapterSurviveReload() throws {
        let url = try directory()
        let comic = Comic(id: "comic", title: "测试")
        let fifth = Chapter(id: "fifth", serial: "5")
        let twelfth = Chapter(id: "twelfth", serial: "12")
        let store = LibraryStore(directoryURL: url)
        store.recordProgress(comic: comic, chapter: twelfth, page: 8, totalPages: 20)
        store.recordProgress(comic: comic, chapter: fifth, page: 3, totalPages: 20)

        let restored = LibraryStore(directoryURL: url)
        XCTAssertEqual(restored.readChapterIDs, [fifth.id, twelfth.id])
        XCTAssertTrue(restored.isChapterRead(fifth.id))
        XCTAssertTrue(restored.isChapterRead(twelfth.id))
        XCTAssertFalse(restored.isChapterRead("eleventh"))
        XCTAssertEqual(restored.progress(for: comic.id)?.chapter.id, fifth.id)
        XCTAssertEqual(restored.progress(for: comic.id)?.page, 3)
        restored.clearHistory()
        XCTAssertTrue(restored.readChapterIDs.isEmpty)
        XCTAssertNil(LibraryStore(directoryURL: url).progress(for: comic.id))
        XCTAssertFalse(LibraryStore(directoryURL: url).isChapterRead(fifth.id))
    }

    func testShelfNamesRejectEmptyDuplicateAndOverlongNames() throws {
        let store = LibraryStore(directoryURL: try directory())
        XCTAssertNil(store.createShelf(name: "   "))
        XCTAssertNotNil(store.createShelf(name: "Reading"))
        XCTAssertNil(store.createShelf(name: "reading"))
        XCTAssertNil(store.createShelf(name: String(repeating: "字", count: 81)))
        XCTAssertEqual(store.shelves.count, 1)
    }

    func testCorruptedArchiveIsPreservedBeforeNewChangesAreSaved() throws {
        let url = try directory()
        let corruptData = Data("broken archive".utf8)
        try corruptData.write(to: url.appendingPathComponent("library.json"))
        let store = LibraryStore(directoryURL: url)
        XCTAssertNotNil(store.lastError)
        let backups = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("library-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corruptData)
        store.toggleFavorite(Comic(id: "new", title: "新增"))
        XCTAssertEqual(LibraryStore(directoryURL: url).favorites.map(\.id), ["new"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corruptData)
    }
}
