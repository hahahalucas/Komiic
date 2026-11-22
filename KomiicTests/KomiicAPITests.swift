import XCTest
@testable import Komiic

final class KomiicAPITests: XCTestCase {
    private var session: URLSession!
    private var api: KomiicAPI!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        api = KomiicAPI(baseURL: URL(string: "https://example.invalid")!, session: session, imageSession: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        api = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testCatalogEncodesVariablesAndFiltersNullRows() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"comics":[null,{"id":"1","title":"测试"}]}}"#.utf8))
        }
        let comics = try await api.catalog(feed: .popular, offset: 30, filter: .general)
        XCTAssertEqual(comics.map(\.id), ["1"])
        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(request.url?.path, "/api/query")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        XCTAssertEqual(payload["operationName"] as? String, "hotComics")
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        let pagination = try XCTUnwrap(variables["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["offset"] as? Int, 30)
        XCTAssertEqual(pagination["sexyLevel"] as? Int, 0)
        XCTAssertEqual(pagination["orderBy"] as? String, "MONTH_VIEWS")
    }

    func testGraphQLErrorTakesPrecedenceOverPartialData() async {
        StubURLProtocol.handler = { _ in
            (200, "application/json", Data(#"{"data":{"comics":null},"errors":[{"message":"额度已用完","extensions":{"code":"QUOTA_EXCEEDED"}}]}"#.utf8))
        }
        do {
            _ = try await api.catalog(feed: .updated)
            XCTFail("Expected quota error")
        } catch KomiicError.imageQuotaExceeded {
            // Expected: a partial-data decode error must not obscure the quota error.
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSearchReturnsAllResultsBeyondThirtyAndSupportsOffset() async throws {
        let comics = (0..<47).map { ["id": String($0), "title": "结果 \($0)"] }
        let response: [String: Any] = ["data": ["searchComicsAndAuthors": ["comics": comics]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        StubURLProtocol.handler = { _ in (200, "application/json", data) }
        let all = try await api.search(keyword: "测试")
        XCTAssertEqual(all.count, 47)
        XCTAssertEqual(all.last?.id, "46")
        let suffix = try await api.search(keyword: "测试", offset: 31)
        XCTAssertEqual(suffix.count, 16)
        XCTAssertEqual(suffix.first?.id, "31")
    }

    func testHTTPRateLimitIsActionable() async {
        StubURLProtocol.handler = { _ in (429, "application/json", Data()) }
        do {
            _ = try await api.catalog(feed: .updated)
            XCTFail("Expected rate limit")
        } catch KomiicError.rateLimited { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAuthorWorksUsesAuthorIdentifierAndKeepsAllResults() async throws {
        let requests = LockedBox<[URLRequest]>([])
        var comics: [Any] = [NSNull()]
        comics.append(contentsOf: (0..<47).map { index -> [String: Any] in
            ["id": String(index), "title": "作品 \(index)", "authors": [["id": "7", "name": "作者"]]]
        })
        let data = try JSONSerialization.data(withJSONObject: ["data": ["comics": comics]])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", data)
        }
        let works = try await api.comics(authorID: "7")
        XCTAssertEqual(works.count, 47)
        XCTAssertEqual(works.last?.id, "46")
        XCTAssertEqual(works.first?.authorDetails, [ComicAuthor(id: "7", name: "作者")])
        let request = try XCTUnwrap(requests.value.first)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        XCTAssertEqual(payload["operationName"] as? String, "comicsByAuthor")
        XCTAssertTrue((payload["query"] as? String)?.contains("getComicsByAuthor(authorId: $authorId)") == true)
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["authorId"] as? String, "7")
    }

    func testComicDetailRequestsRatingAndRetainsAuthorIdentifiers() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"comicById":{"id":"1","title":"漫画","authors":[{"id":"7","name":"作者"}],"sexyLevel":3,"sexyLevelReason":"分级说明"}}}"#.utf8))
        }
        let comic = try await api.comic(id: "1")
        XCTAssertEqual(comic.sexyLevel, 3)
        XCTAssertEqual(comic.sexyLevelReason, "分级说明")
        XCTAssertEqual(comic.authorDetails, [ComicAuthor(id: "7", name: "作者")])
        let request = try XCTUnwrap(requests.value.first)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        let query = try XCTUnwrap(payload["query"] as? String)
        XCTAssertTrue(query.contains("description sexyLevel sexyLevelReason"))
    }

    func testAuthorSearchTrimsKeywordAndFiltersNullRows() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"searchComicsAndAuthors":{"authors":[null,{"id":"7","name":"作者"}]}}}"#.utf8))
        }
        let authors = try await api.searchAuthors(keyword: "  作者  ")
        XCTAssertEqual(authors, [ComicAuthor(id: "7", name: "作者")])
        let request = try XCTUnwrap(requests.value.first)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["keyword"] as? String, "作者")
        let empty = try await api.searchAuthors(keyword: " \n ")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(requests.value.count, 1)
    }

    func testInvalidJSONDoesNotBecomeAnEmptySuccess() async {
        StubURLProtocol.handler = { _ in (200, "text/html", Data("<html>unavailable</html>".utf8)) }
        do {
            _ = try await api.catalog(feed: .updated)
            XCTFail("Expected invalid response")
        } catch KomiicError.invalidResponse { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testImageUsesTicketHeaderAndRefreshesOneExpiredTicket() async throws {
        let imageRequests = LockedBox(0)
        let operations = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/query" {
                let payload = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                let operation = payload["operationName"] as! String
                operations.update { $0.append(operation) }
                let ticket = operation == "refreshImageTicket" ? "fresh-ticket" : "old-ticket"
                let body: [String: Any] = ["data": ["ticket": ["url": "https://images.example.invalid/page", "ticket": ticket, "kid": "page-key"]]]
                return (200, "application/json", try JSONSerialization.data(withJSONObject: body))
            }
            imageRequests.update { $0 += 1 }
            XCTAssertFalse(request.httpShouldHandleCookies)
            if imageRequests.value == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-Ticket"), "old-ticket")
                return (403, "application/json", Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-Ticket"), "fresh-ticket")
            return (200, "image/png", Data([137, 80, 78, 71]))
        }
        let bytes = try await api.imageData(for: ComicPage(id: "page", kid: "page-key"))
        XCTAssertEqual(bytes, Data([137, 80, 78, 71]))
        XCTAssertEqual(imageRequests.value, 2)
        XCTAssertEqual(operations.value, ["getImageTicket", "refreshImageTicket"])
    }

    func testChaptersUseNumericOrderWithinType() async throws {
        StubURLProtocol.handler = { _ in
            (200, "application/json", Data(#"{"data":{"chaptersByComicId":[{"id":"10","serial":"10","type":"chapter"},{"id":"2","serial":"2","type":"chapter"},{"id":"1","serial":"1","type":"book"}]}}"#.utf8))
        }
        let chapters = try await api.chapters(comicID: "comic")
        XCTAssertEqual(chapters.map(\.id), ["2", "10", "1"])
    }

    func testConcurrentRequestsShareOneExpiredSessionRefresh() async throws {
        let domain = "refresh-test-\(UUID().uuidString.lowercased()).invalid"
        let source = URL(string: "https://\(domain)")!
        func token(expiration: TimeInterval) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: ["exp": expiration]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).test-signature"
        }
        func cookie(value: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "komiic-access-token", .value: value, .secure: "TRUE", .expires: Date().addingTimeInterval(86_400)]))
        }
        let expired = try cookie(value: token(expiration: Date().timeIntervalSince1970 - 60))
        let fresh = try cookie(value: token(expiration: Date().timeIntervalSince1970 + 3600))
        HTTPCookieStorage.shared.setCookie(expired)
        defer {
            for cookie in HTTPCookieStorage.shared.cookies(for: source) ?? [] {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let refreshes = LockedBox(0)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                refreshes.update { $0 += 1 }
                // Keep the refresh pending while other callers reach the coordinator.
                Thread.sleep(forTimeInterval: 0.05)
                HTTPCookieStorage.shared.setCookie(fresh)
                return (200, "application/json", Data("{}".utf8))
            }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"1","title":"测试"}]}}"#.utf8))
        }
        let refreshingAPI = KomiicAPI(baseURL: source, session: session, imageSession: session)
        let resultCount = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 { group.addTask { try await refreshingAPI.catalog(feed: .updated).count } }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        XCTAssertEqual(resultCount, 6)
        XCTAssertEqual(refreshes.value, 1)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
            let (status, contentType, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}
