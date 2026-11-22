import XCTest
@testable import Komiic

final class ModelTests: XCTestCase {
    func testComicDecodesFirstPartyAndLocalArchiveShapes() throws {
        let data = Data(#"{"id":42,"title":"测试漫画","imageUrl":"https://public.komiic.com/cover.jpg","status":"ONGOING","authors":[{"id":"7","name":"作者"}],"categories":[{"id":"2","name":"冒险"}],"views":"1200","lastChapterUpdate":12.5}"#.utf8)
        let comic = try JSONDecoder().decode(Comic.self, from: data)
        XCTAssertEqual(comic.id, "42")
        XCTAssertEqual(comic.authors, ["作者"])
        XCTAssertEqual(comic.authorDetails, [ComicAuthor(id: "7", name: "作者")])
        XCTAssertEqual(comic.categories, ["冒险"])
        XCTAssertEqual(comic.views, 1200)
        XCTAssertEqual(comic.lastChapterUpdate, "12.5")
        XCTAssertEqual(try JSONDecoder().decode(Comic.self, from: JSONEncoder().encode(comic)), comic)
    }

    func testLegacyComicArchiveWithoutAuthorIDsOrRatingRemainsReadable() throws {
        let data = Data(#"{"id":"42","title":"旧记录","authors":["作者"],"categories":["冒险"]}"#.utf8)
        let comic = try JSONDecoder().decode(Comic.self, from: data)
        XCTAssertEqual(comic.authors, ["作者"])
        XCTAssertTrue(comic.authorDetails.isEmpty)
        XCTAssertNil(comic.sexyLevel)
        XCTAssertNil(comic.sexyLevelReason)
        XCTAssertEqual(comic.contentMode, .general)
        XCTAssertTrue(comic.warnings.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(Comic.self, from: JSONEncoder().encode(comic)), comic)
    }

    func testRatingDistinguishesZeroFromMissingAndPreservesReason() throws {
        let data = Data(#"{"id":"1","title":"分级","authors":[{"id":7,"name":"作者"}],"sexyLevel":"0","sexyLevelReason":"无性内容"}"#.utf8)
        let comic = try JSONDecoder().decode(Comic.self, from: data)
        XCTAssertEqual(comic.sexyLevel, 0)
        XCTAssertEqual(comic.sexyLevelReason, "无性内容")
        XCTAssertEqual(comic.authorDetails.first?.id, "7")
        XCTAssertEqual(try JSONDecoder().decode(Comic.self, from: JSONEncoder().encode(comic)), comic)

        let unclassified = try JSONDecoder().decode(Comic.self, from: Data(#"{"id":"2","title":"未分级","sexyLevel":null}"#.utf8))
        XCTAssertNil(unclassified.sexyLevel)
    }

    func testMissingIdentifierIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Comic.self, from: Data(#"{"title":"没有编号"}"#.utf8)))
    }

    func testChapterSerialAndPageDimensionsDecodeWithoutLosingDecimalSerial() throws {
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(#"{"id":91,"serial":"12.5","type":"chapter","size":20}"#.utf8))
        XCTAssertEqual(chapter.id, "91")
        XCTAssertEqual(chapter.serial, "12.5")
        XCTAssertEqual(chapter.title, "第 12.5 话")
        let page = try JSONDecoder().decode(ComicPage.self, from: Data(#"{"kid":"image-key","width":"1200","height":1800}"#.utf8))
        XCTAssertEqual(page.id, "image-key")
        XCTAssertEqual(page.width, 1200)
        XCTAssertEqual(page.height, 1800)
    }
}
