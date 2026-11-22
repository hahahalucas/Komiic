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

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
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
}
