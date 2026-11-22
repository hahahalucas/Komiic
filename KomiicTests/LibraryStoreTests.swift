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
        let comic = Comic(id: "comic-1", title: "����")
        let chapter = Chapter(id: "chapter-1", serial: "1")
        let store = LibraryStore(directoryURL: url)
        store.toggleFavorite(comic)
        store.toggleBookmark(comic: comic, chapter: chapter, page: 3)
        let shelf = try XCTUnwrap(store.createShelf(name: "  ���ڿ�  "))
        store.addToShelf(comic, shelfID: shelf.id)
        store.addToShelf(comic, shelfID: shelf.id)
        store.recordProgress(comic: comic, chapter: chapter, page: 3, totalPages: 10)
        store.toggleBlocked(comic)

        let restored = LibraryStore(directoryURL: url)
        XCTAssertNil(restored.lastError)
        XCTAssertTrue(restored.isFavorite(comic))
        XCTAssertTrue(restored.isBookmarked(chapterID: chapter.id, page: 3))
        XCTAssertEqual(restored.shelves.first?.name, "���ڿ�")
        XCTAssertEqual(restored.shelves.first?.comics.count, 1)
        XCTAssertEqual(restored.progress(for: comic.id)?.page, 3)
        XCTAssertEqual(restored.readComicCount, 1)
        XCTAssertEqual(restored.readChapterCount, 1)
        XCTAssertTrue(restored.isBlocked(comic))
    }

    func testProgressClampsPagesAndCountsEachChapterOnce() throws {
        let store = LibraryStore(directoryURL: try directory())
        let comic = Comic(id: "comic", title: "����")
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
        let comic = Comic(id: "comic", title: "����")
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
        XCTAssertNil(store.createShelf(name: String(repeating: "��", count: 81)))
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
        store.toggleFavorite(Comic(id: "new", title: "����"))
        XCTAssertEqual(LibraryStore(directoryURL: url).favorites.map(\.id), ["new"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corruptData)
    }

    func testModesIsolateCollectionsEvenWhenComicAndChapterIDsMatch() throws {
        let url = try directory()
        let comic = Comic(id: "shared-id", title: "һ������")
        let chapter = Chapter(id: "shared-chapter", serial: "1")
        let store = LibraryStore(directoryURL: url)
        store.toggleFavorite(comic)
        store.toggleBookmark(comic: comic, chapter: chapter, page: 2)
        store.recordProgress(comic: comic, chapter: chapter, page: 2, totalPages: 12)
        store.toggleBlocked(comic)
        let shelf = try XCTUnwrap(store.createShelf(name: "�Ķ���"))
        store.addToShelf(comic, shelfID: shelf.id)

        store.selectMode(.adult)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(store.shelves.isEmpty)
        XCTAssertTrue(store.blockedComicIDs.isEmpty)
        XCTAssertTrue(store.blockedComics.isEmpty)
        XCTAssertFalse(store.isChapterRead(chapter.id))
        let adultComic = Comic(id: comic.id, title: "H ����")
        store.toggleFavorite(adultComic)
        store.recordProgress(comic: adultComic, chapter: chapter, page: 7, totalPages: 20)
        XCTAssertNotNil(store.createShelf(name: "�Ķ���"))

        let restored = LibraryStore(directoryURL: url, initialMode: .adult)
        XCTAssertEqual(restored.activeMode, .adult)
        XCTAssertEqual(restored.favorites.first?.title, "H ����")
        XCTAssertEqual(restored.history.first?.page, 7)
        XCTAssertTrue(restored.bookmarks.isEmpty)
        XCTAssertTrue(restored.blockedComics.isEmpty)
        restored.selectMode(.general)
        XCTAssertEqual(restored.favorites.first?.title, "һ������")
        XCTAssertEqual(restored.history.first?.page, 2)
        XCTAssertEqual(restored.bookmarks.first?.page, 2)
        XCTAssertEqual(restored.shelves.first?.comics.first?.title, "һ������")
        XCTAssertEqual(restored.blockedComics.first?.title, "һ������")
    }

    func testLegacyArchiveMigratesOnlyIntoGeneralAndRetainsBlockedMetadata() throws {
        let url = try directory()
        let legacy = #"{"version":1,"favorites":[{"id":"legacy","title":"���ղ�"}],"bookmarks":[],"shelves":[],"history":[],"blockedComicIDs":["legacy","unknown"],"readChapterIDs":["old-chapter"]}"#
        try Data(legacy.utf8).write(to: url.appendingPathComponent("library.json"))
        let store = LibraryStore(directoryURL: url, initialMode: .adult)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.blockedComicIDs.isEmpty)
        store.selectMode(.general)
        XCTAssertEqual(store.favorites.map(\.id), ["legacy"])
        XCTAssertEqual(store.blockedComics.map(\.title), ["���ղ�"])
        XCTAssertEqual(store.blockedComicIDs, ["legacy", "unknown"])
        XCTAssertTrue(store.isChapterRead("old-chapter"))
        store.toggleFavorite(Comic(id: "new", title: "���ղ�"))
        let persisted = LibraryStore(directoryURL: url)
        XCTAssertNil(persisted.lastError)
        XCTAssertEqual(Set(persisted.favorites.map(\.id)), ["legacy", "new"])
        persisted.selectMode(.adult)
        XCTAssertTrue(persisted.favorites.isEmpty)
    }

    func testDelayedProgressAndBlockedLookupKeepTheirCapturedMode() throws {
        let url = try directory()
        let store = LibraryStore(directoryURL: url)
        let general = Comic(id: "shared-id", title: "һ������")
        store.toggleBlocked(general)
        store.selectMode(.adult)
        let adult = Comic(id: general.id, title: "H ����")
        store.toggleBlocked(adult)
        store.cacheBlockedComic(Comic(id: general.id, title: "һ���������±���"), mode: .general)
        store.recordProgress(comic: general, chapter: Chapter(id: "late-chapter"), page: 4, totalPages: 9, mode: .general)
        XCTAssertEqual(store.blockedComics.first?.title, "H ����")
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isChapterRead("late-chapter"))
        store.selectMode(.general)
        XCTAssertEqual(store.blockedComics.first?.title, "һ���������±���")
        XCTAssertEqual(store.history.first?.page, 4)
        XCTAssertTrue(store.isChapterRead("late-chapter"))
        store.unblock(comicID: general.id)
        store.cacheBlockedComic(general, mode: .general)
        XCTAssertTrue(store.blockedComics.isEmpty)
        XCTAssertTrue(store.blockedComicIDs.isEmpty)
        let restored = LibraryStore(directoryURL: url, initialMode: .adult)
        XCTAssertEqual(restored.blockedComics.first?.title, "H ����")
        XCTAssertTrue(restored.history.isEmpty)
    }

    func testClearingOneModeLeavesTheOtherModeIntact() throws {
        let store = LibraryStore(directoryURL: try directory())
        let comic = Comic(id: "general", title: "����")
        store.toggleFavorite(comic)
        store.recordProgress(comic: comic, chapter: Chapter(id: "general-chapter"), page: 1, totalPages: 4)
        store.selectMode(.adult)
        store.toggleFavorite(Comic(id: "adult", title: "ɾ��"))
        store.clearLocalData()
        XCTAssertTrue(store.favorites.isEmpty)
        store.selectMode(.general)
        XCTAssertTrue(store.isFavorite(comic))
        XCTAssertEqual(store.history.first?.page, 1)
        XCTAssertTrue(store.isChapterRead("general-chapter"))
    }
}
