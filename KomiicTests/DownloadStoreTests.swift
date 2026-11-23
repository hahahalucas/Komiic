import XCTest
import UIKit
@testable import Komiic

@MainActor
final class DownloadStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KomiicDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await predicate()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for download state"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDownloadedChapterRestoresAndReadsWithoutNetwork() async throws {
        let root = try directory()
        let bytes = png()
        let page = ComicPage(id: "page", kid: "key", width: 2, height: 2)
        let chapter = Chapter(id: "chapter", serial: "1")
        let source = URL(string: "https://example.invalid")!
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"), imageLoader: { _, _ in bytes })
        await store.download(comic: Comic(id: "comic", title: "测试"), chapter: chapter, pages: [page], baseURL: source)
        try await eventually { store.isDownloaded(chapterID: chapter.id) }
        XCTAssertEqual(store.storageBytes, Int64(bytes.count))
        store.clearCache()

        let restored = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"), imageLoader: { _, _ in
            XCTFail("Completed offline chapters must not make a network request")
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertTrue(restored.isDownloaded(chapterID: chapter.id))
        let localData = try await restored.imageData(page: page, chapterID: chapter.id, baseURL: source, cachePolicy: .oneDay, allowNetwork: false)
        XCTAssertEqual(localData, bytes)
    }

    func testInvalidDownloadedImageFailsAndCanBeRetried() async throws {
        let root = try directory()
        let source = URL(string: "https://example.invalid")!
        let page = ComicPage(id: "page", kid: "key")
        let chapter = Chapter(id: "chapter", serial: "1")
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"), imageLoader: { _, _ in Data("not an image".utf8) })
        await store.download(comic: Comic(id: "comic", title: "测试"), chapter: chapter, pages: [page], baseURL: source)
        try await eventually { store.items.first?.status == .failed }
        XCTAssertFalse(store.isDownloaded(chapterID: chapter.id))
        XCTAssertNotNil(store.items.first?.errorMessage)
        XCTAssertEqual(store.items.first?.downloadedPageIDs.count, 0)

        let bytes = png()
        let retryStore = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"), imageLoader: { _, _ in bytes })
        retryStore.resume(id: chapter.id)
        try await eventually { retryStore.isDownloaded(chapterID: chapter.id) }
        XCTAssertEqual(retryStore.items.first?.downloadedPageIDs, [page.id])
    }

    func testRestoreMarksChapterIncompleteWhenImageFileIsMissing() async throws {
        let root = try directory()
        let bytes = png()
        let page = ComicPage(id: "page", kid: "key")
        let chapter = Chapter(id: "chapter", serial: "1")
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"), imageLoader: { _, _ in bytes })
        await store.download(comic: Comic(id: "comic", title: "测试"), chapter: chapter, pages: [page], baseURL: URL(string: "https://example.invalid")!)
        try await eventually { store.isDownloaded(chapterID: chapter.id) }
        let localURL = try XCTUnwrap(store.localImageURL(chapterID: chapter.id, pageID: page.id))
        try FileManager.default.removeItem(at: localURL)
        store.restore()
        XCTAssertFalse(store.isDownloaded(chapterID: chapter.id))
        XCTAssertEqual(store.items.first?.status, .paused)
        XCTAssertEqual(store.items.first?.downloadedPageIDs.count, 0)
    }

    func testPrefetchCachesEntireChapterWithoutCreatingOfflineDownload() async throws {
        let root = try directory()
        let bytes = png()
        let probe = ChapterImageProbe(bytes: bytes)
        let pages = (0..<9).map { ComicPage(id: "page-\($0)", kid: "key-\($0)") }
        let source = URL(string: "https://example.invalid")!
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        await store.prefetchChapter(pages: pages, chapterID: "chapter", baseURL: source, startingAt: 5, cachePolicy: .oneDay)

        let requested = await probe.requestedIDs
        let maximum = await probe.maximumConcurrentRequests
        XCTAssertEqual(Set(requested), Set(pages.map(\.id)))
        XCTAssertEqual(requested.count, pages.count)
        XCTAssertEqual(Set(requested.prefix(3)), Set(pages[5...7].map(\.id)))
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.cacheBytes, Int64(bytes.count * pages.count))
        for page in pages {
            let cached = try await store.imageData(page: page, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay, allowNetwork: false)
            XCTAssertEqual(cached, bytes)
        }
        await store.prefetchChapter(pages: pages, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        let repeated = await probe.requestedIDs
        XCTAssertEqual(repeated, requested)
    }

    func testVisiblePageAndPrefetchShareOneImageRequest() async throws {
        let root = try directory()
        let bytes = png()
        let probe = ChapterImageProbe(bytes: bytes)
        let page = ComicPage(id: "page", kid: "key")
        let source = URL(string: "https://example.invalid")!
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        async let first = store.imageData(page: page, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        async let second = store.imageData(page: page, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        await store.prefetchChapter(pages: [page], chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        let results = try await [first, second]

        XCTAssertEqual(results, [bytes, bytes])
        let requested = await probe.requestedIDs
        XCTAssertEqual(requested, [page.id])
    }

    func testFailedPrefetchPageDoesNotStopChapterAndCanBeRetried() async throws {
        let root = try directory()
        let bytes = png()
        let pages = (0..<7).map { ComicPage(id: "page-\($0)", kid: "key-\($0)") }
        let failedPage = pages[1]
        let probe = ChapterImageProbe(bytes: bytes, failingPageIDs: [failedPage.id])
        let source = URL(string: "https://example.invalid")!
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        await store.prefetchChapter(pages: pages, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        for page in pages where page.id != failedPage.id {
            let cached = try await store.imageData(page: page, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay, allowNetwork: false)
            XCTAssertEqual(cached, bytes)
        }
        do {
            _ = try await store.imageData(page: failedPage, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay, allowNetwork: false)
            XCTFail("Failed pages must not be stored as valid images")
        } catch ImageStorageError.missingOfflinePage {}

        await probe.allowPage(failedPage.id)
        let retried = try await store.imageData(page: failedPage, chapterID: "chapter", baseURL: source, cachePolicy: .oneDay)
        XCTAssertEqual(retried, bytes)
        let requested = await probe.requestedIDs
        XCTAssertEqual(requested.filter { $0 == failedPage.id }.count, 2)
    }

    func testCancelledPrefetchStopsOutstandingAndRemainingPages() async throws {
        let root = try directory()
        let probe = ChapterImageProbe(bytes: png(), delay: .seconds(10))
        let pages = (0..<9).map { ComicPage(id: "page-\($0)", kid: "key-\($0)") }
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        let prefetch = Task {
            await store.prefetchChapter(pages: pages, chapterID: "chapter", baseURL: URL(string: "https://example.invalid")!, cachePolicy: .afterReading)
        }
        try await eventually { await probe.requestedIDs.count == 3 }
        prefetch.cancel()
        await prefetch.value

        let requested = await probe.requestedIDs
        let cancelled = await probe.cancelledIDs
        XCTAssertEqual(requested.count, 3)
        XCTAssertEqual(cancelled, Set(requested))
        XCTAssertEqual(store.cacheBytes, 0)
    }

    func testClearingChapterCachePreventsPrefetchFromRecreatingIt() async throws {
        let root = try directory()
        let probe = ChapterImageProbe(bytes: png(), delay: .milliseconds(200))
        let pages = (0..<9).map { ComicPage(id: "page-\($0)", kid: "key-\($0)") }
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        let prefetch = Task {
            await store.prefetchChapter(pages: pages, chapterID: "chapter", baseURL: URL(string: "https://example.invalid")!, cachePolicy: .afterReading)
        }
        try await eventually { await probe.requestedIDs.count == 3 }
        store.clearCache(chapterID: "chapter")
        await prefetch.value

        let requested = await probe.requestedIDs
        XCTAssertEqual(requested.count, 3)
        XCTAssertEqual(store.cacheBytes, 0)
        let cachedFiles = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("cache").path)
        XCTAssertTrue(cachedFiles.isEmpty)
    }

    func testOfflineDownloadReusesInFlightChapterPrefetch() async throws {
        let root = try directory()
        let bytes = png()
        let probe = ChapterImageProbe(bytes: bytes, delay: .milliseconds(100))
        let pages = (0..<7).map { ComicPage(id: "page-\($0)", kid: "key-\($0)") }
        let chapter = Chapter(id: "chapter", serial: "1")
        let source = URL(string: "https://example.invalid")!
        let store = DownloadStore(directoryURL: root.appendingPathComponent("offline"), cacheDirectory: root.appendingPathComponent("cache"),
            imageLoader: { page, _ in try await probe.load(page) })

        let prefetch = Task {
            await store.prefetchChapter(pages: pages, chapterID: chapter.id, baseURL: source, cachePolicy: .oneDay)
        }
        try await eventually { await probe.requestedIDs.contains(pages[0].id) }
        await store.download(comic: Comic(id: "comic", title: "Test"), chapter: chapter, pages: pages, baseURL: source)
        await prefetch.value
        try await eventually { store.isDownloaded(chapterID: chapter.id) }
        store.clearCache()

        let requested = await probe.requestedIDs
        XCTAssertEqual(Set(requested), Set(pages.map(\.id)))
        XCTAssertEqual(requested.count, pages.count)
        for page in pages {
            let data = try await store.imageData(page: page, chapterID: chapter.id, baseURL: source, cachePolicy: .oneDay, allowNetwork: false)
            XCTAssertEqual(data, bytes)
        }
    }
}

private actor ChapterImageProbe {
    let bytes: Data
    let delay: Duration
    private var failingPageIDs: Set<String>
    private var activeRequests = 0
    private(set) var requestedIDs: [String] = []
    private(set) var cancelledIDs: Set<String> = []
    private(set) var maximumConcurrentRequests = 0

    init(bytes: Data, delay: Duration = .milliseconds(30), failingPageIDs: Set<String> = []) {
        self.bytes = bytes
        self.delay = delay
        self.failingPageIDs = failingPageIDs
    }

    func allowPage(_ id: String) { failingPageIDs.remove(id) }

    func load(_ page: ComicPage) async throws -> Data {
        requestedIDs.append(page.id)
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        defer { activeRequests -= 1 }
        do { try await Task.sleep(for: delay) }
        catch { cancelledIDs.insert(page.id); throw error }
        if failingPageIDs.contains(page.id) { throw URLError(.cannotLoadFromNetwork) }
        return bytes
    }
}
