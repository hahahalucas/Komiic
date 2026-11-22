import XCTest
@testable import Komiic

final class ReaderNavigationTests: XCTestCase {
    func testDoublePagesFollowBothReadingDirectionsAndKeepOddLastPage() {
        let forward = ReaderSpreadLayout(pageCount: 5, doublePage: true, direction: .right)
        let backward = ReaderSpreadLayout(pageCount: 5, doublePage: true, direction: .left)
        XCTAssertEqual(forward.starts, [0, 2, 4])
        XCTAssertEqual(forward.slots(for: 0), [0, 1])
        XCTAssertEqual(backward.slots(for: 0), [1, 0])
        XCTAssertEqual(forward.slots(for: 4), [4, nil])
        XCTAssertEqual(backward.slots(for: 4), [nil, 4])
        XCTAssertEqual(forward.start(for: 3), 2)
        XCTAssertEqual(forward.next(from: 3), 4)
        XCTAssertEqual(forward.previous(from: 4), 2)
        XCTAssertEqual(forward.next(from: 4), 4)
    }

    func testSinglePagesAndEmptyChapterHaveSafeBounds() {
        let single = ReaderSpreadLayout(pageCount: 3, doublePage: false, direction: .left)
        XCTAssertEqual(single.slots(for: 1), [1])
        XCTAssertEqual(single.next(from: 0), 1)
        XCTAssertEqual(single.previous(from: 0), 0)
        let empty = ReaderSpreadLayout(pageCount: 0, doublePage: true, direction: .right)
        XCTAssertTrue(empty.starts.isEmpty)
        XCTAssertTrue(empty.slots(for: 0).isEmpty)
    }

    func testNearbyFiveChaptersAreCenteredAndFilledAtBothEnds() {
        let chapters = (1...9).reversed().map { Chapter(id: "\($0)", serial: "\($0)") }
        let current = Chapter(id: "5", serial: "5")
        XCTAssertEqual(ReaderChapterNavigation.nearby(chapters, current: current).map(\.id), ["3", "4", "5", "6", "7"])
        XCTAssertEqual(ReaderChapterNavigation.nearby(chapters, current: chapters.last!).map(\.id), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(ReaderChapterNavigation.nearby(chapters, current: chapters.first!).map(\.id), ["5", "6", "7", "8", "9"])
    }

    func testNextChapterUsesNumericOrderWithinTheSameDirectoryType() {
        let chapters = [Chapter(id: "10", serial: "10"), Chapter(id: "2", serial: "2"),
                        Chapter(id: "volume", serial: "3", type: "book"), Chapter(id: "3", serial: "3")]
        XCTAssertEqual(ReaderChapterNavigation.next(chapters, current: chapters[1])?.id, "3")
        XCTAssertEqual(ReaderChapterNavigation.next(chapters, current: chapters[3])?.id, "10")
        XCTAssertNil(ReaderChapterNavigation.next(chapters, current: chapters[0]))
        XCTAssertEqual(ReaderChapterNavigation.nearby(chapters, current: chapters[1]).count, 3)
    }
}
