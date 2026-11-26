import Foundation

enum KomiicError: LocalizedError {
    case invalidResponse
    case http(Int)
    case authenticationRequired
    case imageQuotaExceeded
    case rateLimited
    case graphQL(String)
    case notFound
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Komiic 返回了无法识别的数据，请重试或在官网检查连接。"
        case .http(let status): return "连接 Komiic 失败（HTTP \(status)）。"
        case .authenticationRequired: return "请先在账号页登录 Komiic，或重新登录以更新会话。"
        case .imageQuotaExceeded: return "Komiic 官网的图片读取额度已用完。已下载和仍在缓存中的图片可继续阅读。在线加载新图片请在额度重置后重试。"
        case .rateLimited: return "请求过于频繁，请稍后重试。"
        case .graphQL(let message): return message
        case .notFound: return "没有找到这部漫画。"
        case .invalidImage: return "没有取得有效的漫画图片，请重新加载。"
        }
    }
}

/// Uses the same public operations and cookie session as komiic.cc.
/// Endpoint and ticket protocol verified against its first-party client on 2026-11-18.
struct KomiicAPI: Sendable {
    static let pageSize = 30
    let baseURL: URL
    let mode: ComicContentMode
    private let session: URLSession
    private let imageSession: URLSession

    private static let apiSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private static let ticketImageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(mode: ComicContentMode = .general, baseURL: URL? = nil, session: URLSession? = nil,
         imageSession: URLSession? = nil) {
        self.mode = mode
        self.baseURL = baseURL ?? mode.baseURL
        self.session = session ?? Self.apiSession
        self.imageSession = imageSession ?? Self.ticketImageSession
    }

    /// Hold refreshes while both WebKit and native cookies are being removed.
    static func beginClearingSession() async {
        await SessionRefreshCoordinator.shared.beginClearingSession()
    }

    static func endClearingSession() async {
        await SessionRefreshCoordinator.shared.endClearingSession()
    }

    func catalog(feed: CatalogFeed, offset: Int = 0, filter: ContentFilter = .all) async throws -> [Comic] {
        if feed == .recommended {
            guard offset <= 0 else { return [] }
            return try await personalizedRecommendations(filter: filter)
        }
        var pagination: [String: Any] = [
            "limit": Self.pageSize, "offset": max(0, offset), "asc": false,
            "orderBy": feed == .popular ? "VIEWS" : "DATE_UPDATED"
        ]
        if filter != .all { pagination["sexyLevel"] = filter.rawValue }
        let operation: String
        let arguments: String
        if feed == .popular {
            operation = "hotComics"
            arguments = "pagination: $pagination"
        } else if mode == .adult {
            operation = "comicByElements"
            arguments = "elementIds: [], pagination: $pagination"
        } else {
            operation = "comicByCategories"
            arguments = "categoryId: [], pagination: $pagination"
        }
        let query = "query \(operation)($pagination: Pagination!) { comics: \(operation)(\(arguments)) { \(Self.comicFields) } }"
        let data: ComicList = try await perform(operation, query: query, variables: ["pagination": pagination])
        return data.comics.compactMap { $0 }.map(normalized)
    }

    private func personalizedRecommendations(filter: ContentFilter) async throws -> [Comic] {
        let data: PersonalizedSuggestions = try await perform("personalizedSuggestions", query: """
            query personalizedSuggestions($contentType: ContentType) {
                personalizedSuggestions(limit: 25, excludeRead: true, excludeFavorites: true, contentType: $contentType) {
                    comicId
                }
            }
            """, variables: ["contentType": mode.rawValue])
        let ids = data.personalizedSuggestions?.compactMap { $0?.comicId } ?? []
        let suggestions = try await comics(ids: ids)
        guard filter != .all else { return suggestions }
        let ratings = try await contentRatings(comicIDs: suggestions.map(\.id))
        return suggestions.filter { filter.matches(sexyLevel: ratings[$0.id]) }
    }

    /// Komiic search returns its complete result set; an optional offset returns its suffix.
    func search(keyword: String, offset: Int = 0) async throws -> [Comic] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let query = "query searchComicsAndAuthors($keyword: String!) { searchComicsAndAuthors(keyword: $keyword) { comics { \(Self.comicFields) } } }"
        let data: SearchResult = try await perform("searchComicsAndAuthors", query: query, variables: ["keyword": keyword])
        return Array((data.searchComicsAndAuthors.comics ?? []).compactMap { $0 }
            .dropFirst(max(0, offset))).map(normalized)
    }

    func comic(id: String) async throws -> Comic {
        let query = "query comicById($comicId: ID!) { comicById(comicId: $comicId) { \(Self.comicFields) description sexyLevel sexyLevelReason } }"
        let data: ComicResult = try await perform("comicById", query: query, variables: ["comicId": id])
        guard let comic = data.comicById else { throw KomiicError.notFound }
        return normalized(comic)
    }

    func contentRatings(comicIDs: [String]) async throws -> [String: Int] {
        guard !comicIDs.isEmpty else { return [:] }
        // The bulk comic resolver can return zero for rated titles. Request the detail field.
        let parameters = comicIDs.indices.map { "$id\($0): ID!" }.joined(separator: ", ")
        let fields = comicIDs.indices.map { "comic\($0): comicById(comicId: $id\($0)) { sexyLevel }" }
        let variables = Dictionary(uniqueKeysWithValues: comicIDs.enumerated().map { ("id\($0.offset)", $0.element as Any) })
        let data: [String: ComicRating?] = try await perform("contentRatings", query:
            "query contentRatings(\(parameters)) { \(fields.joined(separator: " ")) }", variables: variables)
        var ratings: [String: Int] = [:]
        for (index, id) in comicIDs.enumerated() {
            if let comic = data["comic\(index)"] ?? nil, let level = comic.sexyLevel {
                ratings[id] = level
            }
        }
        return ratings
    }

    /// Both sections of the detail screen travel in one GraphQL round trip.
    func comicDetails(id: String) async throws -> (comic: Comic, chapters: [Chapter]) {
        let data: ComicDetailsResult = try await perform("comicDetails", query: """
            query comicDetails($comicId: ID!) {
                comicById(comicId: $comicId) { \(Self.comicFields) description sexyLevel sexyLevelReason }
                chaptersByComicId(comicId: $comicId) { id serial type size }
            }
            """, variables: ["comicId": id])
        guard let comic = data.comicById else { throw KomiicError.notFound }
        return (normalized(comic), Self.sortedChapters(data.chaptersByComicId))
    }

    /// The first-party author page returns the author's complete collection without pagination.
    func comics(authorID: String) async throws -> [Comic] {
        let query = "query comicsByAuthor($authorId: ID!) { comics: getComicsByAuthor(authorId: $authorId) { \(Self.comicFields) } }"
        let data: ComicList = try await perform("comicsByAuthor", query: query, variables: ["authorId": authorID])
        return data.comics.compactMap { $0 }.map(normalized)
    }

    /// Resolves legacy local records that saved author names without their identifiers.
    func searchAuthors(keyword: String) async throws -> [ComicAuthor] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let query = "query searchAuthors($keyword: String!) { searchComicsAndAuthors(keyword: $keyword) { authors { id name } } }"
        let data: AuthorSearchResult = try await perform("searchAuthors", query: query, variables: ["keyword": keyword])
        return (data.searchComicsAndAuthors.authors ?? []).compactMap { $0 }
    }

    func chapters(comicID: String) async throws -> [Chapter] {
        let query = "query chapterByComicId($comicId: ID!) { chaptersByComicId(comicId: $comicId) { id serial type size } }"
        let data: ChapterResult = try await perform("chapterByComicId", query: query, variables: ["comicId": comicID])
        return Self.sortedChapters(data.chaptersByComicId)
    }

    private static func sortedChapters(_ chapters: [Chapter?]) -> [Chapter] {
        chapters.compactMap { $0 }.sorted {
            if $0.type != $1.type { return $0.type == "chapter" || ($0.type == "book" && $1.type != "chapter") }
            return $0.serial.compare($1.serial, options: .numeric) == .orderedAscending
        }
    }

    func pages(chapterID: String) async throws -> [ComicPage] {
        let query = "query imagesByChapterId($chapterId: ID!) { imagesByChapterId(chapterId: $chapterId) { id kid width height } }"
        let data: PageResult = try await perform("imagesByChapterId", query: query, variables: ["chapterId": chapterID])
        return data.imagesByChapterId.compactMap { $0 }
    }

    func accountID() async throws -> String? {
        do {
            let data: AccountIdentityResult = try await perform("accountIdentity", query:
                "query accountIdentity { account { id } }", variables: [:])
            return data.account?.id
        } catch KomiicError.authenticationRequired { return nil }
    }

    func accountProfile() async throws -> KomiicAccountProfile? {
        let accountData: AccountResult
        do {
            accountData = try await perform("accountQuery", query: """
                query accountQuery { account { id nickname email dateCreated profileImageUrl profileText
                    profileTextColor profileBackgroundColor
                    warningPreferences { tag action } } }
                """, variables: [:])
        } catch KomiicError.authenticationRequired { return nil }
        guard let account = accountData.account else { return nil }
        return KomiicAccountProfile(id: account.id, username: account.nickname ?? "", email: account.email,
            dateCreated: account.dateCreated, profileImageURL: (account.profileImageUrl?.url).flatMap(normalizedURL),
            profileText: account.profileText, warningPreferences: account.warningPreferences ?? [],
            profileTextColor: account.profileTextColor, profileBackgroundColor: account.profileBackgroundColor)
    }

    func accountReadingStats() async throws -> AccountReadingStats {
        let data: ReadingStatsResult = try await perform("readingStats", query: """
            query readingStats {
                readingStats { comicsRead chaptersRead favoriteCount bookmarkCount folderCount followingFolderCount }
            }
            """, variables: [:])
        return data.readingStats
    }

    func imageReadingQuota(accountID: String) async throws -> ImageReadingQuota {
        // The quota field alone can return a visitor's allowance after a session expires.
        let data: ImageLimitResult = try await perform("getImageLimit", query:
            "query getImageLimit { account { id } getImageLimit { limit usage resetInSeconds } }", variables: [:])
        guard data.account?.id == accountID else { throw KomiicError.authenticationRequired }
        let quota = data.getImageLimit
        return ImageReadingQuota(usage: quota.usage, limit: quota.limit,
                                 resetAt: Date().addingTimeInterval(quota.resetInSeconds))
    }

    func accountMessageStats() async throws -> AccountMessageStats {
        let data: MessageStatsResult = try await perform("messageStats", query:
            "query messageStats { messageStats { totalMessages totalUpvotes } }", variables: [:])
        return data.messageStats
    }

    func warningPreferences() async throws -> [ContentWarningPreference] {
        let data: WarningPreferencesResult = try await perform("getWarningPreferences", query:
            "query getWarningPreferences { account { warningPreferences { tag action } } }", variables: [:])
        guard let account = data.account else { throw KomiicError.authenticationRequired }
        return account.warningPreferences ?? []
    }

    @discardableResult
    func setWarningPreference(tag: String, action: ContentWarningAction) async throws -> [ContentWarningPreference] {
        let data: SetWarningResult = try await perform("setWarningPreference", query: """
            mutation setWarningPreference($tag: String!, $action: WarningAction) {
                setWarningPreference(tag: $tag, action: $action) { warningPreferences { tag action } }
            }
            """, variables: ["tag": tag, "action": action == .show ? NSNull() : action.rawValue as Any])
        return data.setWarningPreference.warningPreferences ?? []
    }

    func comics(ids: [String]) async throws -> [Comic] {
        guard !ids.isEmpty else { return [] }
        let data: ComicList = try await perform("comicByIds", query:
            "query comicByIds($comicIds: [ID]!) { comics: comicByIds(comicIds: $comicIds) { \(Self.comicFields) } }",
            variables: ["comicIds": ids])
        let byID = Dictionary(data.comics.compactMap { $0 }.map { ($0.id, normalized($0)) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func favorites(offset: Int = 0) async throws -> [Comic] {
        let data: FavoritesResult = try await perform("favoritesQuery", query: """
            query favoritesQuery($pagination: Pagination!) {
                favoritesV2(pagination: $pagination) { comicId }
            }
            """, variables: ["pagination": ["limit": Self.pageSize, "offset": max(0, offset),
                "orderBy": "FAVORITE_ADDED", "asc": false]])
        return try await comics(ids: data.favoritesV2.compactMap { $0?.comicId })
    }

    func readingHistory(offset: Int = 0) async throws -> [OfficialReadingHistory] {
        let data: HistoryResult = try await perform("readComicHistory", query: """
            query readComicHistory($pagination: Pagination!) {
                readComicHistory(pagination: $pagination) { comicId lastDate chapters { chapterId page updatedAt } }
            }
            """, variables: ["pagination": ["limit": Self.pageSize, "offset": max(0, offset),
                "orderBy": "DATE_UPDATED", "asc": false]])
        let rows = data.readComicHistory.compactMap { $0 }
        let loaded = try await comics(ids: rows.map(\.comicId))
        let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { row in
            guard let comic = byID[row.comicId] else { return nil }
            return OfficialReadingHistory(comic: comic, chapters: row.chapters.compactMap { $0 }, lastDate: row.lastDate)
        }
    }

    func setFavorite(comicID: String, isFavorite: Bool) async throws {
        if isFavorite {
            let _: AddFavoriteResult = try await perform("addFavorite", query:
                "mutation addFavorite($comicId: ID!) { addFavorite(comicId: $comicId) { comicId } }",
                variables: ["comicId": comicID])
        } else {
            let _: MutationResult = try await perform("removeFavorite", query:
                "mutation removeFavorite($comicId: ID!) { removeFavorite(comicId: $comicId) }",
                variables: ["comicId": comicID])
        }
    }

    func recordProgress(comicID: String, chapterID: String, page: Int) async throws {
        let _: MutationResult = try await perform("addReadComicHistoryV2", query: """
            mutation addReadComicHistoryV2($comicId: ID!, $chapterId: ID!, $page: Int!) {
                addReadComicHistoryV2(comicId: $comicId, chapterId: $chapterId, page: $page)
            }
            """, variables: ["comicId": comicID, "chapterId": chapterID, "page": max(0, page)])
    }

    /// Tickets are requested only when an image is needed, preserving the server's quota rules.
    func imageRequest(for page: ComicPage) async throws -> URLRequest {
        try await ticketRequest(kid: page.kid, refreshing: false)
    }

    func imageData(for page: ComicPage) async throws -> Data {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let request = try await ticketRequest(kid: page.kid, refreshing: attempt > 0)
            let (data, response) = try await imageSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KomiicError.invalidResponse }
            if http.statusCode == 403 && attempt == 0 { continue }
            try Self.checkStatus(http.statusCode)
            guard !data.isEmpty, http.mimeType?.lowercased().hasPrefix("image/") == true else {
                throw KomiicError.invalidImage
            }
            return data
        }
        throw KomiicError.authenticationRequired
    }

    func diagnose() async throws -> String {
        let comics = try await catalog(feed: .all)
        return "已连接 \(baseURL.host ?? "Komiic")，成功读取 \(comics.count) 部漫画。"
    }

    private func ticketRequest(kid: String, refreshing: Bool) async throws -> URLRequest {
        let operation = refreshing ? "refreshImageTicket" : "getImageTicket"
        let kind = refreshing ? "mutation" : "query"
        let query = "\(kind) \(operation)($kid: String!) { ticket: \(operation)(kid: $kid) { url ticket kid } }"
        let data: TicketResult = try await perform(operation, query: query, variables: ["kid": kid])
        guard let ticket = data.ticket, let url = normalizedURL(ticket.url),
              url.scheme == "https", !ticket.ticket.isEmpty else { throw KomiicError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.httpShouldHandleCookies = false
        request.setValue(ticket.ticket, forHTTPHeaderField: "X-Image-Ticket")
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        return request
    }

    func perform<T: Decodable>(_ operation: String, query: String, variables: [String: Any]) async throws -> T {
        try Task.checkCancellation()
        try await refreshSessionIfNeeded()
        var request = request(path: "api/query")
        let cookieGeneration = SessionCookieStore.shared.generation
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operationName": operation, "query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        if session === Self.apiSession { SessionCookieStore.shared.capture(generation: cookieGeneration) }
        guard let http = response as? HTTPURLResponse else { throw KomiicError.invalidResponse }
        try Self.checkStatus(http.statusCode)
        let decoder = JSONDecoder()
        // Inspect errors first: nullable partial GraphQL data may not match the success type.
        if let error = (try? decoder.decode(GraphQLProblems.self, from: data))?.errors?.first {
            // The current official service uses this message without an extensions code.
            if error.message.lowercased() == "no token" { throw KomiicError.authenticationRequired }
            switch error.extensions?.code {
            case "QUOTA_EXCEEDED": throw KomiicError.imageQuotaExceeded
            case "UNAUTHENTICATED", "FORBIDDEN": throw KomiicError.authenticationRequired
            default: throw KomiicError.graphQL(error.message)
            }
        }
        let envelope: GraphQLResponse<T>
        do { envelope = try decoder.decode(GraphQLResponse<T>.self, from: data) }
        catch { throw KomiicError.invalidResponse }
        guard let result = envelope.data else { throw KomiicError.invalidResponse }
        return result
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        return request
    }

    private func refreshSessionIfNeeded() async throws {
        try await SessionRefreshCoordinator.shared.refreshIfNeeded(
            baseURL: baseURL, session: session, request: request(path: "auth/refresh"), persistCookies: session === Self.apiSession
        )
    }

    private func normalized(_ comic: Comic) -> Comic {
        var copy = comic
        if let url = copy.imageUrl { copy.imageUrl = normalizedURL(url) }
        return copy
    }

    /// The official client performs this rewrite for regional Komiic domains.
    func normalizedURL(_ url: URL) -> URL? {
        guard let host = baseURL.host, host != "komiic.com", host.hasSuffix("komiic.cc"),
              let urlHost = url.host, ["img.komiic.com", "public.komiic.com", "download.komiic.com"].contains(urlHost),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = urlHost.replacingOccurrences(of: "komiic.com", with: "komiic.cc")
        return parts.url
    }

    fileprivate static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw KomiicError.authenticationRequired
        case 402: throw KomiicError.imageQuotaExceeded
        case 429: throw KomiicError.rateLimited
        default: throw KomiicError.http(status)
        }
    }

    private static let comicFields = """
        id title status imageUrl authors { id name } categories { id name }
        dateUpdated monthViews views favoriteCount lastBookUpdate lastChapterUpdate
        contentType warnings
        """
}

/// All client instances for one origin await the same refresh, including reader/download clients.
/// An individual cancelled page request does not cancel the refresh needed by other callers.
private actor SessionRefreshCoordinator {
    static let shared = SessionRefreshCoordinator()
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var clearingSessions = 0

    func beginClearingSession() async {
        clearingSessions += 1
        let requests = Array(inFlight.values)
        requests.forEach { $0.cancel() }
        // A cancelled URLSession request must finish before callers erase the cookies,
        // otherwise a delayed refresh response could recreate a signed-out session.
        for request in requests { _ = await request.result }
    }

    func endClearingSession() {
        clearingSessions = max(0, clearingSessions - 1)
    }

    func refreshIfNeeded(baseURL: URL, session: URLSession, request: URLRequest, persistCookies: Bool) async throws {
        guard clearingSessions == 0 else { throw KomiicError.authenticationRequired }
        let key = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? ""):\(baseURL.port ?? 443)"
        if let pending = inFlight[key] {
            try await pending.value
            return
        }
        guard Self.needsRefresh(baseURL) else { return }
        let refresh = Task<Void, Error> {
            // Cookies may have changed while this actor/task was waiting for execution.
            guard Self.needsRefresh(baseURL) else { return }
            let cookieGeneration = SessionCookieStore.shared.generation
            let (_, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw KomiicError.invalidResponse }
            try KomiicAPI.checkStatus(http.statusCode)
            if persistCookies { SessionCookieStore.shared.capture(generation: cookieGeneration) }
        }
        inFlight[key] = refresh
        defer { inFlight.removeValue(forKey: key) }
        try await refresh.value
    }

    private static func needsRefresh(_ baseURL: URL) -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        guard let token = cookies.first(where: { $0.name == "komiic-access-token" })?.value else {
            return cookies.contains { $0.name == "komiic-refresh-token" }
        }
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return false }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expiration = object["exp"] as? Double else { return false }
        return expiration < Date().timeIntervalSince1970 + 300
    }
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}
private struct GraphQLProblems: Decodable { let errors: [GraphQLError]? }
private struct GraphQLError: Decodable {
    let message: String
    let extensions: Extensions?
    struct Extensions: Decodable { let code: String? }
}
private struct ComicList: Decodable { let comics: [Comic?] }
private struct PersonalizedSuggestions: Decodable {
    let personalizedSuggestions: [Suggestion?]?
    struct Suggestion: Decodable { let comicId: String? }
}
private struct SearchResult: Decodable {
    let searchComicsAndAuthors: Matches
    struct Matches: Decodable { let comics: [Comic?]? }
}
private struct AuthorSearchResult: Decodable {
    let searchComicsAndAuthors: Matches
    struct Matches: Decodable { let authors: [ComicAuthor?]? }
}
private struct ComicResult: Decodable { let comicById: Comic? }
private struct ComicRating: Decodable { let sexyLevel: Int? }
private struct ComicDetailsResult: Decodable {
    let comicById: Comic?
    let chaptersByComicId: [Chapter?]
}
private struct ChapterResult: Decodable { let chaptersByComicId: [Chapter?] }
private struct PageResult: Decodable { let imagesByChapterId: [ComicPage?] }
private struct TicketResult: Decodable {
    let ticket: Ticket?
    struct Ticket: Decodable { let url: URL; let ticket: String; let kid: String }
}

private struct AccountResult: Decodable {
    let account: Account?
    struct Account: Decodable {
        let id: String
        let nickname: String?
        let email: String?
        let dateCreated: String?
        let profileImageUrl: OfficialProfileImage?
        let profileText: String?
        let profileTextColor: String?
        let profileBackgroundColor: String?
        let warningPreferences: [ContentWarningPreference]?
    }
}
private struct AccountIdentityResult: Decodable {
    let account: Identity?
    struct Identity: Decodable { let id: String }
}
private struct ReadingStatsResult: Decodable { let readingStats: AccountReadingStats }
private struct MessageStatsResult: Decodable { let messageStats: AccountMessageStats }
private struct ImageLimitResult: Decodable {
    let account: AccountIdentityResult.Identity?
    let getImageLimit: ImageLimit
    struct ImageLimit: Decodable {
        let limit: Int
        let usage: Int
        let resetInSeconds: TimeInterval
        enum CodingKeys: String, CodingKey { case limit, usage, resetInSeconds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limit = try c.decode(Int.self, forKey: .limit)
            usage = try c.decode(Int.self, forKey: .usage)
            let seconds = (try? c.decode(Double.self, forKey: .resetInSeconds))
                ?? (try? c.decode(String.self, forKey: .resetInSeconds)).flatMap(Double.init)
            guard let seconds, seconds.isFinite else { throw KomiicError.invalidResponse }
            resetInSeconds = max(0, seconds)
        }
    }
}
private struct WarningPreferencesResult: Decodable {
    let account: Preferences?
}
private struct SetWarningResult: Decodable { let setWarningPreference: Preferences }
private struct Preferences: Decodable { let warningPreferences: [ContentWarningPreference]? }
private struct FavoriteRow: Decodable { let comicId: String }
private struct FavoritesResult: Decodable { let favoritesV2: [FavoriteRow?] }
private struct AddFavoriteResult: Decodable { let addFavorite: FavoriteRow }
private struct HistoryResult: Decodable {
    let readComicHistory: [Row?]
    struct Row: Decodable {
        let comicId: String
        let lastDate: String?
        let chapters: [OfficialChapterProgress?]
    }
}
/// The official progress/remove mutations return scalars whose value is not needed here.
private struct MutationResult: Decodable {}
