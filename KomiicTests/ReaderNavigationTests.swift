import Foundation
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

    func testLandscapePagingStartsAtTheReadingEdgeAndIncludesTheOddLastPage() {
        let right = ReaderSpreadLayout(pageCount: 5, doublePage: true, direction: .right)
        let left = ReaderSpreadLayout(pageCount: 5, doublePage: true, direction: .left)
        XCTAssertEqual((0..<right.count).map { right.page(atHorizontalIndex: $0) }, [0, 2, 4])
        XCTAssertEqual((0..<left.count).map { left.page(atHorizontalIndex: $0) }, [4, 2, 0])
        XCTAssertEqual(right.horizontalIndex(for: 0), 0)
        XCTAssertEqual(left.horizontalIndex(for: 0), 2)
        XCTAssertEqual(left.horizontalIndex(for: 3), 1)
        XCTAssertEqual(left.horizontalIndex(for: 4), 0)
    }

    func testLandscapeContinuationRequiresAForwardHorizontalSwipe() {
        let right = ReaderSpreadLayout(pageCount: 4, doublePage: true, direction: .right)
        let left = ReaderSpreadLayout(pageCount: 4, doublePage: true, direction: .left)
        XCTAssertTrue(right.isForwardSwipe(CGPoint(x: -100, y: 8)))
        XCTAssertTrue(left.isForwardSwipe(CGPoint(x: 100, y: 8)))
        XCTAssertFalse(right.isForwardSwipe(CGPoint(x: 100, y: 8)))
        XCTAssertFalse(left.isForwardSwipe(CGPoint(x: -100, y: 8)))
        XCTAssertFalse(left.isForwardSwipe(CGPoint(x: 90, y: -100)))
        XCTAssertFalse(left.isForwardSwipe(CGPoint(x: 20, y: 0)))
    }

    func testScrollableDirectoryContainsEveryEntryOfTheCurrentType() {
        let chapters = (1...8).reversed().map { Chapter(id: "chapter-\($0)", serial: "\($0)") }
        let volumes = (1...8).reversed().map { Chapter(id: "book-\($0)", serial: "\($0)", type: "book") }
        for group in [chapters, volumes] {
            let current = group[2]
            let directory = ReaderChapterNavigation.ordered(chapters + volumes, current: current)
            XCTAssertEqual(directory.map(\.id), group.reversed().map(\.id))
            let nearby = ReaderChapterNavigation.nearby(chapters + volumes, current: current)
            XCTAssertEqual(nearby.map(\.id), directory.suffix(5).map(\.id))
        }
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
