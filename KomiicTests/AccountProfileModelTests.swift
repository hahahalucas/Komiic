import XCTest
@testable import Komiic

@MainActor
final class AccountProfileModelTests: XCTestCase {
    func testRevisitingAccountDoesNotFetchUntilExplicitRefresh() async {
        var requests = 0
        let model = AccountProfileModel(mode: .general) { requests += 1; return nil }
        await model.load()
        await model.load()
        await model.load()
        XCTAssertEqual(requests, 1)
        await model.load(force: true)
        XCTAssertEqual(requests, 2)
        model.reset()
        await model.load()
        XCTAssertEqual(requests, 3)
    }

    func testFailedAccountLoadWaitsForPullToRefreshAndHasNoEndlessSpinner() async {
        var requests = 0
        let model = AccountProfileModel(mode: .general) {
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        await model.load()
        await model.load()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.error)
        await model.load(force: true)
        XCTAssertEqual(requests, 2)
    }

    func testTabModelsRetainIdentityAndKeepContentModesSeparate() {
        let content = AppContentStore()
        XCTAssertTrue(content.catalog(feed: .updated, mode: .general) === content.catalog(feed: .updated, mode: .general))
        XCTAssertFalse(content.catalog(feed: .updated, mode: .adult) === content.catalog(feed: .updated, mode: .general))
        XCTAssertTrue(content.account(mode: .general) === content.account(mode: .general))
        XCTAssertFalse(content.account(mode: .general) === content.account(mode: .adult))
    }
}
