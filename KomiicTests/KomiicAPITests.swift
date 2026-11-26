import XCTest
@testable import Komiic

final class KomiicAPITests: XCTestCase {
    func testOfficialFoldersKeepServerIdentityAndResolveTheirComics() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            switch payload["operationName"] as? String {
            case "myFolder":
                return (200, "application/json", Data(#"{"data":{"folders":[{"id":"7","name":"官网书柜"}]}}"#.utf8))
            case "folderComicIds":
                return (200, "application/json", Data(#"{"data":{"folderComicIds":{"comicIds":["2","1"]}}}"#.utf8))
            default:
                return (200, "application/json", Data(#"{"data":{"comics":[{"id":"1","title":"一"},{"id":"2","title":"二"}]}}"#.utf8))
            }
        }
        let shelves = try await api.bookshelves()
        XCTAssertEqual(shelves.first?.officialID, "7")
        XCTAssertEqual(shelves.first?.comics.map(\.id), ["2", "1"])
        XCTAssertEqual(shelves.first?.id, Bookshelf.official(id: "7", name: "另一个名称").id)
    }

    func testOfficialBlockIDsSurviveMissingMetadataAndMutationsUseVerifiedOperations() async throws {
        let calls = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let operation = payload["operationName"] as? String ?? ""
            calls.update { $0.append(operation) }
            switch operation {
            case "blockedComicIds":
                return (200, "application/json", Data(#"{"data":{"blockedComicIds":["8","deleted"]}}"#.utf8))
            case "comicByIds":
                return (200, "application/json", Data(#"{"data":{"comics":[{"id":"8","title":"屏蔽漫画"}]}}"#.utf8))
            default:
                return (200, "application/json", Data("{\"data\":{\"\(operation)\":true}}".utf8))
            }
        }
        let blocks = try await api.blockedCollection()
        XCTAssertEqual(blocks.ids, ["8", "deleted"])
        XCTAssertEqual(blocks.comics.map(\.id), ["8"])
        try await api.setBlocked(comicID: "8", blocked: true)
        try await api.setBlocked(comicID: "8", blocked: false)
        try await api.renameBookshelf(id: "7", name: "新名字")
        XCTAssertEqual(calls.value, ["blockedComicIds", "comicByIds", "blockComic", "unblockComic", "updateFolderName"])
    }

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

    func testAdultRecommendationsUseOfficialOriginAndExplicitContentType() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"h1","title":"分区测试","contentType":"H_MANGA","warnings":["獵奇"]}]}}"#.utf8))
        }
        let adultAPI = KomiicAPI(mode: .adult, session: session, imageSession: session)
        let result = try await adultAPI.catalog(feed: .recommended)
        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(request.url?.host, "h.komiic.cc")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["adult"] as? Bool, true)
        XCTAssertEqual(variables["contentType"] as? String, "H_MANGA")
        XCTAssertEqual(result.first?.contentMode, .adult)
        XCTAssertEqual(result.first?.warnings, ["獵奇"])
    }

    func testShowWarningPreferenceSendsNullRatherThanUnsupportedEnum() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"setWarningPreference":{"warningPreferences":[]}}}"#.utf8))
        }
        let preferences = try await api.setWarningPreference(tag: "血腥", action: .show)
        XCTAssertTrue(preferences.isEmpty)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(XCTUnwrap(requests.value.first))) as? [String: Any])
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertTrue(variables["action"] is NSNull)
        XCTAssertEqual(variables["tag"] as? String, "血腥")
    }

    func testOfficialFavoritesResolveMetadataAndPreserveCollectionOrder() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            if payload["operationName"] as? String == "favoritesQuery" {
                return (200, "application/json", Data(#"{"data":{"favoritesV2":[{"comicId":"2"},null,{"comicId":"1"}]}}"#.utf8))
            }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"1","title":"一","contentType":"REGULAR"},{"id":"2","title":"二","contentType":"REGULAR"}]}}"#.utf8))
        }
        let favorites = try await api.favorites()
        XCTAssertEqual(favorites.map(\.id), ["2", "1"])
    }

    func testOfficialHistoryKeepsSavedZeroBasedChapterPage() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            if payload["operationName"] as? String == "readComicHistory" {
                return (200, "application/json", Data(#"{"data":{"readComicHistory":[{"comicId":"2","lastDate":"2026-11-22T10:00:00Z","chapters":[{"chapterId":"7","page":8,"updatedAt":"2026-11-22T10:00:00Z"}]}]}}"#.utf8))
            }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"2","title":"二","contentType":"H_MANGA"}]}}"#.utf8))
        }
        let history = try await api.readingHistory()
        XCTAssertEqual(history.first?.comic.id, "2")
        XCTAssertEqual(history.first?.chapters.first?.chapterId, "7")
        XCTAssertEqual(history.first?.chapters.first?.page, 8)
        XCTAssertEqual(history.first?.comic.contentMode, .adult)
    }

    @MainActor
    func testAccountProfileLoadsOfficialStatisticsAndRefreshesQuotaIndependently() async throws {
        let calls = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let operation = try XCTUnwrap(payload["operationName"] as? String)
            calls.update { $0.append(operation) }
            let body: String
            switch operation {
            case "accountQuery":
                body = #"{"data":{"account":{"id":"7","nickname":"测试","email":"test@example.invalid","dateCreated":"2026-01-01","warningPreferences":[{"tag":"血腥","action":"WARN"}]}}}"#
            case "readingStats":
                body = #"{"data":{"readingStats":{"comicsRead":9,"chaptersRead":42,"favoriteCount":3,"bookmarkCount":2,"folderCount":1,"followingFolderCount":5,"topCategories":[{"id":"1","name":"冒险","count":7}]}}}"#
            case "getImageLimit":
                body = #"{"data":{"account":{"id":"7"},"getImageLimit":{"limit":800,"usage":195,"resetInSeconds":"5700"}}}"#
            case "messageStats":
                body = #"{"data":{"messageStats":{"totalMessages":4,"totalUpvotes":18}}}"#
            default: throw URLError(.badServerResponse)
            }
            return (200, "application/json", Data(body.utf8))
        }
        let model = AccountProfileModel(mode: .general, snapshots: nil, sessionScope: { nil }, api: api)
        await model.load()
        let profile = try XCTUnwrap(model.profile)
        let quota = try XCTUnwrap(profile.imageQuota)
        XCTAssertEqual(profile.username, "测试")
        XCTAssertEqual(profile.readingStats?.comicsRead, 9)
        XCTAssertEqual(quota.usage, 195)
        XCTAssertEqual(quota.limit, 800)
        XCTAssertEqual(quota.fractionUsed, 195.0 / 800.0, accuracy: 0.0001)
        XCTAssertEqual(profile.messageStats?.totalUpvotes, 18)
        XCTAssertEqual(profile.readingStats?.topCategories.first?.name, "冒险")
        XCTAssertEqual(profile.warningPreferences.first?.action, .warn)
        XCTAssertEqual(quota.resetAt.timeIntervalSinceNow, 5700, accuracy: 5)
        calls.update { $0.removeAll() }
        await model.load(refreshQuota: true)
        XCTAssertEqual(calls.value, ["getImageLimit"])
    }

    @MainActor
    func testUnavailableStatisticsKeepAccountIdentityAndImageQuotaVisible() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let body: String
            switch payload["operationName"] as? String {
            case "accountQuery":
                body = #"{"data":{"account":{"id":"7","nickname":"测试","email":"test@example.invalid"}}}"#
            case "getImageLimit":
                body = #"{"data":{"account":{"id":"7"},"getImageLimit":{"limit":800,"usage":11,"resetInSeconds":5600}}}"#
            default:
                body = #"{"data":null,"errors":[{"message":"Service unavailable"}]}"#
            }
            return (200, "application/json", Data(body.utf8))
        }
        let model = AccountProfileModel(mode: .general, snapshots: nil, sessionScope: { nil }, api: api)
        await model.load()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.profile?.id, "7")
        XCTAssertEqual(model.profile?.email, "test@example.invalid")
        XCTAssertEqual(model.profile?.imageQuota?.usage, 11)
        XCTAssertNil(model.profile?.readingStats)
        XCTAssertNil(model.profile?.messageStats)
    }

    func testComicAndPersonalCommentsDecodeQuotesAndUseOfficialPagination() async throws {
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
            let body: String
            switch payload["operationName"] as? String {
            case "getMessagesByComicId":
                XCTAssertEqual(variables["comicId"] as? String, "book")
                let pagination = try XCTUnwrap(variables["pagination"] as? [String: Any])
                XCTAssertEqual(pagination["orderBy"] as? String, "DATE_UPDATED")
                XCTAssertEqual(pagination["asc"] as? Bool, false)
                XCTAssertEqual(pagination["offset"] as? Int, 30)
                body = #"{"data":{"getMessagesByComicId":[null,{"id":"a","comicId":"book","message":"回复","dateCreated":"2026-11-12T06:40:52Z","replyTo":{"message":"原留言","account":{"nickname":"作者"}},"upCount":4,"downCount":1}]}}"#
            case "myMessages":
                let query = try XCTUnwrap(payload["query"] as? String)
                XCTAssertTrue(query.contains("upCount: upvotes"))
                XCTAssertEqual(variables["offset"] as? Int, 5)
                body = #"{"data":{"myMessages":{"total":25,"messages":[{"id":"b","comicId":"book","deleted":true},null]}}}"#
            default: throw URLError(.badServerResponse)
            }
            return (200, "application/json", Data(body.utf8))
        }
        let comic = try await api.comicComments(comicID: "book", offset: 30)
        XCTAssertEqual(comic.comments.first?.replyTo?.account?.name, "作者")
        XCTAssertEqual(comic.comments.first?.upCount, 4)
        XCTAssertNil(comic.nextOffset)
        let personal = try await api.myComments(offset: 5)
        XCTAssertEqual(personal.comments.map(\.id), ["b"])
        XCTAssertEqual(personal.comments.first?.isDeleted, true)
        XCTAssertEqual(personal.nextOffset, 7)
    }

    func testPostingAndVotingOnCommentsUseOfficialVariables() async throws {
        let replies = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
            switch payload["operationName"] as? String {
            case "addMessageToComic":
                XCTAssertEqual(variables["comicId"] as? String, "book")
                XCTAssertEqual(variables["message"] as? String, "留言内容")
                let reply = try XCTUnwrap(variables["replyToId"] as? String)
                replies.update { $0.append(reply) }
                return (200, "application/json", Data(#"{"data":{"addMessageToComic":{"id":"b","comicId":"book","reviewing":true}}}"#.utf8))
            case "voteMessage":
                XCTAssertEqual(variables["messageId"] as? String, "original")
                XCTAssertEqual(variables["up"] as? Bool, false)
                return (200, "application/json", Data(#"{"data":{"voteMessage":true}}"#.utf8))
            default: throw URLError(.badServerResponse)
            }
        }
        let comment = try await api.postComment(comicID: "book", message: "留言内容", replyingTo: nil)
        XCTAssertEqual(comment.reviewing, true)
        _ = try await api.postComment(comicID: "book", message: "留言内容", replyingTo: "original")
        try await api.voteOnComment(id: "original", up: false)
        XCTAssertEqual(replies.value, ["0", "original"])
    }

    func testAdultProfileKeepsInstanceOriginAndUnauthenticatedStateIsNil() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":null,"errors":[{"message":"no token","path":["account"]}]}"#.utf8))
        }
        let adultAPI = KomiicAPI(mode: .adult, session: session, imageSession: session)
        let profile = try await adultAPI.accountProfile()
        let identity = try await adultAPI.accountID()
        XCTAssertNil(profile)
        XCTAssertNil(identity)
        XCTAssertEqual(requests.value.count, 2)
        XCTAssertTrue(requests.value.allSatisfy { $0.url?.host == "h.komiic.cc" })
    }

    func testAdultImageTicketKeepsHOriginButUsesRegionalImageCDN() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"ticket":{"url":"https://img.komiic.com/page.webp","ticket":"test-ticket","kid":"key"}}}"#.utf8))
        }
        let adultAPI = KomiicAPI(mode: .adult, session: session, imageSession: session)
        let imageRequest = try await adultAPI.imageRequest(for: ComicPage(id: "1", kid: "key"))
        XCTAssertEqual(requests.value.first?.url?.host, "h.komiic.cc")
        XCTAssertEqual(imageRequest.url?.host, "img.komiic.cc")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Referer"), "https://h.komiic.cc/")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "X-Image-Ticket"), "test-ticket")
        XCTAssertFalse(imageRequest.httpShouldHandleCookies)
    }

    func testOfficialCollectionWritesUseSelectedOriginAndZeroBasedProgress() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            if payload["operationName"] as? String == "addFavorite" {
                return (200, "application/json", Data(#"{"data":{"addFavorite":{"comicId":"h1"}}}"#.utf8))
            }
            return (200, "application/json", Data(#"{"data":{"result":true}}"#.utf8))
        }
        let adultAPI = KomiicAPI(mode: .adult, session: session, imageSession: session)
        try await adultAPI.setFavorite(comicID: "h1", isFavorite: true)
        try await adultAPI.setFavorite(comicID: "h1", isFavorite: false)
        try await adultAPI.recordProgress(comicID: "h1", chapterID: "h2", page: 8)
        XCTAssertEqual(requests.value.count, 3)
        XCTAssertTrue(requests.value.allSatisfy { $0.url?.host == "h.komiic.cc" })
        let payloads = try requests.value.map { try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody($0)) as? [String: Any]) }
        XCTAssertEqual(payloads.compactMap { $0["operationName"] as? String }, ["addFavorite", "removeFavorite", "addReadComicHistoryV2"])
        let progress = try XCTUnwrap(payloads.last?["variables"] as? [String: Any])
        XCTAssertEqual(progress["comicId"] as? String, "h1")
        XCTAssertEqual(progress["chapterId"] as? String, "h2")
        XCTAssertEqual(progress["page"] as? Int, 8)
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

    func testComicDetailsLoadsComicAndSortedChaptersInOneRequest() async throws {
        let requests = LockedBox<[URLRequest]>([])
        StubURLProtocol.handler = { request in
            requests.update { $0.append(request) }
            return (200, "application/json", Data(#"{"data":{"comicById":{"id":"1","title":"漫画","imageUrl":"https://public.komiic.com/cover.jpg"},"chaptersByComicId":[null,{"id":"10","serial":"10","type":"chapter"},{"id":"2","serial":"2","type":"chapter"},{"id":"b","serial":"1","type":"book"}]}}"#.utf8))
        }
        let regionalAPI = KomiicAPI(mode: .adult, session: session, imageSession: session)
        let result = try await regionalAPI.comicDetails(id: "1")
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(result.comic.id, "1")
        XCTAssertEqual(result.comic.imageUrl?.host, "public.komiic.cc")
        XCTAssertEqual(result.chapters.map(\.id), ["2", "10", "b"])
        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(request.url?.host, "h.komiic.cc")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        XCTAssertEqual(payload["operationName"] as? String, "comicDetails")
        let query = try XCTUnwrap(payload["query"] as? String)
        XCTAssertTrue(query.contains("comicById(comicId: $comicId)"))
        XCTAssertTrue(query.contains("chaptersByComicId(comicId: $comicId)"))
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["comicId"] as? String, "1")
    }

    func testMissingComicDetailsDoesNotBecomeAnEmptySuccess() async throws {
        StubURLProtocol.handler = { _ in
            (200, "application/json", Data(#"{"data":{"comicById":null,"chaptersByComicId":[]}}"#.utf8))
        }
        do {
            _ = try await api.comicDetails(id: "missing")
            XCTFail("A missing comic must keep the existing not-found state")
        } catch KomiicError.notFound {}
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

    func testSavedRefreshCookieRenewsSessionWhenAccessCookieIsMissing() async throws {
        let domain = "restored-session-\(UUID().uuidString.lowercased()).invalid"
        let source = URL(string: "https://\(domain)")!
        let refresh = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "komiic-refresh-token",
            .value: "saved-refresh", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        let access = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "komiic-access-token",
            .value: "restored-access", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        HTTPCookieStorage.shared.setCookie(refresh)
        defer { for cookie in HTTPCookieStorage.shared.cookies(for: source) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) } }
        let renewals = LockedBox(0)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                renewals.update { $0 += 1 }
                HTTPCookieStorage.shared.setCookie(access)
                return (200, "application/json", Data("{}".utf8))
            }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"restored","title":"恢复"}]}}"#.utf8))
        }
        let restored = KomiicAPI(baseURL: source, session: session, imageSession: session)
        let comics = try await restored.catalog(feed: .updated)
        XCTAssertEqual(comics.first?.id, "restored")
        XCTAssertEqual(renewals.value, 1)
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

    func testClearingSessionDrainsRefreshAndKeepsGateUntilAllClearersFinish() async throws {
        let domain = "logout-test-\(UUID().uuidString.lowercased()).invalid"
        let source = URL(string: "https://\(domain)")!
        let payload = try JSONSerialization.data(withJSONObject: ["exp": Date().timeIntervalSince1970 - 60])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "komiic-access-token",
            .value: "e30.\(payload).signature", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let refreshes = LockedBox(0)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                refreshes.update { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.1)
                return (200, "application/json", Data("{}".utf8))
            }
            return (200, "application/json", Data(#"{"data":{"comics":[{"id":"1","title":"测试"}]}}"#.utf8))
        }
        let testAPI = KomiicAPI(baseURL: source, session: session, imageSession: session)
        let pending = Task { try await testAPI.catalog(feed: .updated) }
        for _ in 0..<100 where refreshes.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(refreshes.value, 1)
        await KomiicAPI.beginClearingSession()
        await KomiicAPI.beginClearingSession()
        await KomiicAPI.endClearingSession()
        do {
            _ = try await testAPI.catalog(feed: .updated)
            XCTFail("A second clearer must keep the refresh gate closed")
        } catch KomiicError.authenticationRequired {
        } catch { XCTFail("Unexpected clearing error: \(error)") }
        await KomiicAPI.endClearingSession()
        _ = await pending.result
        HTTPCookieStorage.shared.deleteCookie(cookie)
        let comics = try await testAPI.catalog(feed: .updated)
        XCTAssertEqual(comics.map(\.id), ["1"])
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
