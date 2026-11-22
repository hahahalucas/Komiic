import XCTest
@testable import Komiic

@MainActor
final class CatalogModelTests: XCTestCase {
    func testRepeatedRefreshRequestsFirstPageEvenWhenResultsAreUnchanged() async {
        let loader = ControlledCatalogLoader()
        let model = CatalogModel { _, offset, filter in try await loader.fetch(offset: offset, filter: filter) }
        let comics = [Comic(id: "same", title: "没有更新的漫画")]

        let initial = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(1)
        await loader.complete(0, with: .success(comics))
        await initial.value

        let refresh = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(2)
        XCTAssertTrue(model.loading)
        XCTAssertEqual(model.comics, comics)
        await loader.complete(1, with: .success(comics))
        await refresh.value

        let offsets = await loader.offsets
        XCTAssertEqual(offsets, [0, 0])
        XCTAssertEqual(model.comics, comics)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.loadedFilter, .all)
        XCTAssertNil(model.error)
    }

    func testFailedRefreshKeepsPreviouslyLoadedComicsAndCanRetry() async {
        let loader = ControlledCatalogLoader()
        let model = CatalogModel { _, offset, filter in try await loader.fetch(offset: offset, filter: filter) }
        let comics = [Comic(id: "old", title: "已有漫画")]
        let initial = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(1)
        await loader.complete(0, with: .success(comics))
        await initial.value

        let refresh = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(2)
        await loader.complete(1, with: .failure(URLError(.timedOut)))
        await refresh.value
        XCTAssertEqual(model.comics, comics)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.loading)

        let retry = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(3)
        await loader.complete(2, with: .success(comics))
        await retry.value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.comics, comics)
    }

    func testRefreshSurvivesCancellationOfTheScrollViewTask() async {
        let loader = ControlledCatalogLoader()
        let model = CatalogModel { _, offset, filter in try await loader.fetch(offset: offset, filter: filter) }
        let request = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(1)
        request.cancel()
        await loader.complete(0, with: .success([Comic(id: "loaded", title: "正常载入")]))
        await request.value
        XCTAssertEqual(model.comics.map(\.id), ["loaded"])
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
    }

    func testNewerFilterSupersedesAnOlderRefreshResponse() async {
        let loader = ControlledCatalogLoader()
        let model = CatalogModel { _, offset, filter in try await loader.fetch(offset: offset, filter: filter) }
        let old = Task { await model.load(feed: .updated, filter: .all, reset: true) }
        await loader.waitForRequestCount(1)
        let newest = Task { await model.load(feed: .updated, filter: .general, reset: true) }
        await loader.waitForRequestCount(2)
        await loader.complete(1, with: .success([Comic(id: "new", title: "新筛选")]))
        await newest.value
        await loader.complete(0, with: .success([Comic(id: "old", title: "过期筛选")]))
        await old.value
        XCTAssertEqual(model.comics.map(\.id), ["new"])
        XCTAssertEqual(model.loadedFilter, .general)
        XCTAssertFalse(model.loading)
    }

    func testNetworkCancellationOffersRetryInsteadOfAnEndlessInitialSpinner() async {
        let model = CatalogModel { _, _, _ in throw URLError(.cancelled) }
        await model.load(feed: .updated, filter: .all, reset: true)
        XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.loadedFilter)
    }
}

private actor ControlledCatalogLoader {
    private(set) var offsets: [Int] = []
    private var pending: [CheckedContinuation<[Comic], Error>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func fetch(offset: Int, filter: ContentFilter) async throws -> [Comic] {
        try await withCheckedThrowingContinuation { continuation in
            offsets.append(offset)
            pending.append(continuation)
            let ready = waiters.filter { $0.0 <= pending.count }
            waiters.removeAll { $0.0 <= pending.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with result: Result<[Comic], Error>) {
        pending[index]?.resume(with: result)
        pending[index] = nil
    }
}
