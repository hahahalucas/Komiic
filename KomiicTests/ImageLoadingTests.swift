import XCTest
import UIKit
import ImageIO
@testable import Komiic

@MainActor
final class ImageLoadingTests: XCTestCase {
    private func png(size: CGSize = CGSize(width: 20, height: 10)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeCache() throws -> (PageImageDiskCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KomiicImageTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (PageImageDiskCache(directory: directory), directory)
    }

    func testFullPageDecodePreservesResolutionAndCoverDecodeDownsamples() async throws {
        let bytes = png(size: CGSize(width: 1200, height: 600))
        let page = try await ImageDecoding.image(from: bytes)
        let cover = try await ImageDecoding.image(from: bytes, maximumPixelSize: 640)
        XCTAssertEqual(page.cgImage?.width, 1200)
        XCTAssertEqual(page.cgImage?.height, 600)
        XCTAssertEqual(cover.cgImage?.width, 640)
        XCTAssertEqual(cover.cgImage?.height, 320)
    }

    func testInvalidImageCannotBeValidatedOrDecoded() async throws {
        let bytes = Data("<html>temporarily unavailable</html>".utf8)
        do {
            try await ImageDecoding.validate(bytes)
            XCTFail("HTML must not enter the page cache")
        } catch ImageStorageError.invalidImage {}
        do {
            _ = try await ImageDecoding.image(from: bytes)
            XCTFail("Invalid data must keep the page's retry state")
        } catch ImageStorageError.invalidImage {}
    }

    func testFullPageDecodeRetainsEXIFOrientation() async throws {
        let source = try XCTUnwrap(UIImage(data: png())?.cgImage)
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try await ImageDecoding.image(from: bytes as Data)
        XCTAssertEqual(image.imageOrientation, .right)
    }

    func testConcurrentCoversShareDownloadAndReuseDecodedThumbnail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverImageURLProtocol.self]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CoverImageURLProtocol.bytes = nil }
        CoverImageURLProtocol.bytes = png(size: CGSize(width: 1200, height: 600))
        CoverImageURLProtocol.resetCount()
        let loader = CoverImageLoader(session: session)
        let url = URL(string: "https://covers.example.invalid/cover.png")!
        async let first = loader.image(for: url)
        async let second = loader.image(for: url)
        let images = try await [first, second]
        let cached = try await loader.image(for: url)
        XCTAssertEqual(CoverImageURLProtocol.requestCount, 1)
        XCTAssertTrue(images[0] === images[1])
        XCTAssertTrue(images[0] === cached)
        XCTAssertEqual(cached.cgImage?.width, 640)
    }

    func testReplacingCachedPageUpdatesSizeWithoutDoubleCounting() async throws {
        let (cache, root) = try makeCache()
        let generation = UUID()
        cache.register(chapter: "chapter", generation: generation)
        let url = root.appendingPathComponent("chapter/page.image")
        let first = png()
        let second = png(size: CGSize(width: 40, height: 80))
        let initial = try await cache.write(first, to: url, chapter: "chapter", generation: generation)
        let replaced = try await cache.write(second, to: url, chapter: "chapter", generation: generation)
        XCTAssertEqual(initial.bytes, Int64(first.count))
        XCTAssertEqual(replaced.bytes, Int64(second.count))
        XCTAssertGreaterThan(replaced.revision, initial.revision)
        let restored = PageImageDiskCache(directory: root)
        XCTAssertEqual(try restored.maintain(maximumAge: nil).bytes, Int64(second.count))
    }

    func testLateWriteAfterClearCannotRecreateChapterOrIncreaseSize() async throws {
        let (cache, root) = try makeCache()
        let generation = UUID()
        cache.register(chapter: "chapter", generation: generation)
        let url = root.appendingPathComponent("chapter/page.image")
        _ = try await cache.write(png(), to: url, chapter: "chapter", generation: generation)
        let cleared = try cache.clear(chapter: "chapter")
        let late = try await cache.write(png(), to: url, chapter: "chapter", generation: generation)
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(late.bytes, 0)
        XCTAssertEqual(late.revision, cleared.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearingOneChapterPreservesOtherChapterAndNewGeneration() async throws {
        let (cache, root) = try makeCache()
        let firstGeneration = UUID()
        let otherGeneration = UUID()
        let bytes = png()
        cache.register(chapter: "first", generation: firstGeneration)
        cache.register(chapter: "other", generation: otherGeneration)
        let firstURL = root.appendingPathComponent("first/page.image")
        let otherURL = root.appendingPathComponent("other/page.image")
        _ = try await cache.write(bytes, to: firstURL, chapter: "first", generation: firstGeneration)
        _ = try await cache.write(bytes, to: otherURL, chapter: "other", generation: otherGeneration)
        XCTAssertEqual(try cache.clear(chapter: "first").bytes, Int64(bytes.count))
        let retained = await cache.read(from: otherURL, maximumAge: nil)
        XCTAssertEqual(retained, bytes)
        let nextGeneration = UUID()
        cache.register(chapter: "first", generation: nextGeneration)
        _ = try await cache.write(bytes, to: firstURL, chapter: "first", generation: nextGeneration)
        let stale = try await cache.write(Data(), to: firstURL, chapter: "first", generation: firstGeneration)
        XCTAssertEqual(stale.bytes, Int64(bytes.count * 2))
        let newData = await cache.read(from: firstURL, maximumAge: nil)
        XCTAssertEqual(newData, bytes)
    }

    func testExpiredCacheIsRejectedForOneDayPolicyAndMaintenanceCountsRemainingBytes() async throws {
        let (cache, root) = try makeCache()
        let generation = UUID()
        cache.register(chapter: "chapter", generation: generation)
        let url = root.appendingPathComponent("chapter/page.image")
        let bytes = png()
        _ = try await cache.write(bytes, to: url, chapter: "chapter", generation: generation)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: url.path)
        let expired = await cache.read(from: url, maximumAge: 86_400)
        let retained = await cache.read(from: url, maximumAge: nil)
        XCTAssertNil(expired)
        XCTAssertEqual(retained, bytes)
        XCTAssertEqual(try cache.maintain(maximumAge: 86_400).bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class CoverImageURLProtocol: URLProtocol {
    static var bytes: Data?
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func resetCount() { lock.lock(); defer { lock.unlock() }; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        guard let url = request.url, let data = Self.bytes else { return }
        if request.httpShouldHandleCookies || request.value(forHTTPHeaderField: "Cookie") != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
