import XCTest
@testable import Komiic

final class ChapterDirectoryTests: XCTestCase {
    private func chapters(_ count: Int, type: String = "chapter") -> [Chapter] {
        (1...count).map { Chapter(id: "\(type)-\($0)", serial: String($0), type: type, size: 20) }
    }

    private func visibleChapters(_ items: [ChapterDirectoryItem]) -> [Chapter] {
        items.compactMap { if case .chapter(let chapter) = $0 { return chapter }; return nil }
    }

    private func hiddenChapters(_ items: [ChapterDirectoryItem]) -> [Chapter] {
        items.flatMap { if case .collapsed(let chapters) = $0 { return chapters }; return [] }
    }

    func testJumpToFifthMarksOnlyFifthAndCanRevealSkippedUnreadChapters() {
        let all = chapters(8)
        let readIDs: Set<String> = ["chapter-5"]
        let items = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: "chapter-5")
        XCTAssertEqual(hiddenChapters(items).map(\.id), Array(all.prefix(4)).map(\.id))
        XCTAssertEqual(visibleChapters(items).map(\.id), Array(all.dropFirst(4)).map(\.id))
        XCTAssertEqual(visibleChapters(items).filter { readIDs.contains($0.id) }.map(\.id), ["chapter-5"])
        let expanded = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: "chapter-5", expanded: true)
        XCTAssertEqual(visibleChapters(expanded), all)
        XCTAssertTrue(hiddenChapters(expanded).isEmpty)
        XCTAssertEqual(visibleChapters(expanded).filter { readIDs.contains($0.id) }.map(\.id), ["chapter-5"])
    }

    func testConsecutiveReadChaptersKeepOnlyTwoBesideLastReadChapter() {
        let all = chapters(15)
        let readIDs = Set(all.prefix(12).map(\.id))
        let items = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: "chapter-12")
        XCTAssertEqual(visibleChapters(items).filter { readIDs.contains($0.id) }.map(\.id), ["chapter-11", "chapter-12"])
        XCTAssertEqual(hiddenChapters(items).map(\.id), Array(all.prefix(10)).map(\.id))
        XCTAssertEqual(visibleChapters(items).suffix(3).map(\.id), ["chapter-13", "chapter-14", "chapter-15"])
    }

    func testUnreadEleventhDoesNotKeepTenthBesideReadTwelfth() {
        let all = chapters(14)
        var readIDs = Set(all.prefix(10).map(\.id))
        readIDs.insert("chapter-12")
        let items = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: "chapter-12")
        XCTAssertEqual(visibleChapters(items).filter { readIDs.contains($0.id) }.map(\.id), ["chapter-12"])
        XCTAssertEqual(hiddenChapters(items).map(\.id), Array(all.prefix(11)).map(\.id))
        XCTAssertFalse(readIDs.contains("chapter-11"))
    }

    func testReturningToAnEarlierChapterUsesLastReadInsteadOfLargestReadSerial() {
        let all = chapters(24)
        let readIDs: Set<String> = ["chapter-4", "chapter-5", "chapter-12", "chapter-24"]
        let items = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: "chapter-5")
        XCTAssertEqual(visibleChapters(items).filter { readIDs.contains($0.id) }.map(\.id), ["chapter-4", "chapter-5"])
        XCTAssertTrue(hiddenChapters(items).contains { $0.id == "chapter-24" })
        XCTAssertTrue(visibleChapters(items).contains { $0.id == "chapter-6" })
        XCTAssertTrue(visibleChapters(items).contains { $0.id == "chapter-23" })
        XCTAssertEqual(visibleChapters(items).count + hiddenChapters(items).count, all.count)
    }

    func testDifferentGroupDoesNotSelectItsHighestReadAsAnAnchor() {
        let books = chapters(4, type: "book")
        let readIDs: Set<String> = ["book-1", "book-3", "chapter-12"]
        let items = ChapterDirectory.items(chapters: books, readChapterIDs: readIDs, lastReadChapterID: "chapter-12")
        XCTAssertEqual(visibleChapters(items).map(\.id), ["book-2", "book-4"])
        XCTAssertEqual(hiddenChapters(items).map(\.id), ["book-1", "book-3"])
    }

    func testSortDirectionOnlyReversesPresentationAndExpandedListIncludesAllChapters() {
        let all = chapters(13).reversed()
        let readIDs: Set<String> = ["chapter-10", "chapter-11", "chapter-13"]
        let ascending = ChapterDirectory.items(chapters: Array(all), readChapterIDs: readIDs, lastReadChapterID: "chapter-11")
        let descending = ChapterDirectory.items(chapters: Array(all), readChapterIDs: readIDs, lastReadChapterID: "chapter-11", ascending: false)
        XCTAssertEqual(descending, Array(ascending.reversed()))
        XCTAssertEqual(visibleChapters(ascending).map(\.id), ["chapter-10", "chapter-11", "chapter-12"])
        let expanded = ChapterDirectory.items(chapters: Array(all), readChapterIDs: readIDs, lastReadChapterID: "chapter-11", expanded: true, ascending: false)
        XCTAssertEqual(visibleChapters(expanded), Array(all))
    }

    func testUnreadOrMissingAnchorCannotCreateAnIncorrectReadMarker() {
        let all = chapters(5)
        let readIDs: Set<String> = ["chapter-2"]
        let anchors: [String?] = [nil, "deleted", "chapter-5"]
        for anchor in anchors {
            let items = ChapterDirectory.items(chapters: all, readChapterIDs: readIDs, lastReadChapterID: anchor)
            XCTAssertTrue(visibleChapters(items).allSatisfy { !readIDs.contains($0.id) })
            XCTAssertEqual(hiddenChapters(items).map(\.id), ["chapter-2"])
        }
        XCTAssertTrue(ChapterDirectory.items(chapters: [], readChapterIDs: [], lastReadChapterID: nil).isEmpty)
    }
}
