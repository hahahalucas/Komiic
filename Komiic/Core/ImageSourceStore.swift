import Combine
import Foundation

enum ImageAccountSlot: Int, CaseIterable, Codable, Identifiable {
    case first = 1, second

    var id: Int { rawValue }
    var title: String { "账号 \(rawValue)" }
}

struct ImageSourceOwner: Equatable {
    let id: String
    let sessionScope: String
}

extension ImageReadingQuota {
    static func combined(_ quotas: [ImageReadingQuota]) -> ImageReadingQuota? {
        guard let resetAt = quotas.map(\.resetAt).min() else { return nil }
        return ImageReadingQuota(usage: quotas.reduce(0) { $0 + $1.usage },
                                 limit: quotas.reduce(0) { $0 + $1.limit }, resetAt: resetAt)
    }
}

@MainActor
final class ImageSourceStore: ObservableObject {
    enum Status {
        case disconnected, awaitingQuota, expired, available(ImageReadingQuota)

        var quota: ImageReadingQuota? {
            if case .available(let quota) = self { return quota }
            return nil
        }
    }

    private struct Key: Hashable {
        let mode: ComicContentMode
        let slot: ImageAccountSlot
    }

    private struct Credentials: Codable {
        let mode: ComicContentMode
        let slot: ImageAccountSlot
        let ownerID: String
        let accountID: String
        var cookies: [SessionCookieStore.Cookie]
    }

    private struct Source {
        let session: URLSession
        let api: KomiicAPI
        var credentials: Credentials
        var quota: ImageReadingQuota?
        var expired = false
        var exhaustedUntil: Date?
    }

    private enum ConnectionError: LocalizedError {
        case duplicateAccount, keychainUnavailable

        var errorDescription: String? {
            switch self {
            case .duplicateAccount: return "这个账号已在使用，请登录另一个 Komiic 账号。"
            case .keychainUnavailable: return "无法保存登录会话，请解锁设备后重试。"
            }
        }
    }

    @Published private var sources: [Key: Source] = [:]
    private let persistence: SessionPersistence
    private let primary: (ComicContentMode) -> (owner: ImageSourceOwner, quota: ImageReadingQuota?)?
    private let sessionConfiguration: () -> URLSessionConfiguration
    private let imageSession: URLSession?
    private let primaryImage: (ComicPage, URL) async throws -> Data
    private var primaryExhaustion: [ComicContentMode: (owner: ImageSourceOwner, until: Date)] = [:]
    private var refreshing: Set<ObjectIdentifier> = []
    private var generation = UUID()

    init(primary: @escaping (ComicContentMode) -> (owner: ImageSourceOwner, quota: ImageReadingQuota?)?,
         persistence: SessionPersistence = .keychain(account: "image-source-cookies"),
         sessionConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         imageSession: URLSession? = nil,
         primaryImage: @escaping (ComicPage, URL) async throws -> Data = { page, url in
             try await KomiicAPI(baseURL: url).imageData(for: page)
         }) {
        self.primary = primary
        self.persistence = persistence
        self.sessionConfiguration = sessionConfiguration
        self.imageSession = imageSession
        self.primaryImage = primaryImage
        let saved = persistence.load().flatMap { try? JSONDecoder().decode([Credentials].self, from: $0) } ?? []
        for credentials in saved {
            let key = Key(mode: credentials.mode, slot: credentials.slot)
            guard sources[key] == nil else { continue }
            let session = makeSession(cookies: credentials.cookies.compactMap(\.restored), mode: credentials.mode)
            sources[key] = Source(session: session,
                api: KomiicAPI(mode: credentials.mode, imageAccountSession: session, imageSession: imageSession),
                credentials: credentials)
        }
    }

    func status(for slot: ImageAccountSlot, mode: ComicContentMode, ownerID: String) -> Status {
        guard let source = sources[Key(mode: mode, slot: slot)], source.credentials.ownerID == ownerID else {
            return .disconnected
        }
        if source.expired || credentialCookies(in: source.session, mode: mode).isEmpty { return .expired }
        if let quota = source.quota { return .available(quota) }
        return .awaitingQuota
    }

    func connect(_ slot: ImageAccountSlot, mode: ComicContentMode, ownerID: String, cookies: [HTTPCookie]) async throws {
        guard let owner = primary(mode)?.owner, owner.id == ownerID else { throw KomiicError.authenticationRequired }
        let revision = generation
        let session = makeSession(cookies: cookies, mode: mode)
        let api = KomiicAPI(mode: mode, imageAccountSession: session, imageSession: imageSession)
        var connected = false
        defer { if !connected { session.invalidateAndCancel() } }
        let result = try await api.imageReadingAccount()
        try requireCurrent(owner, mode: mode)
        guard revision == generation else { throw CancellationError() }
        let duplicate = sources.values.contains {
            $0.credentials.mode == mode && $0.credentials.slot != slot &&
            $0.credentials.ownerID == owner.id && $0.credentials.accountID == result.id
        }
        guard result.id != owner.id, !duplicate else { throw ConnectionError.duplicateAccount }

        let key = Key(mode: mode, slot: slot)
        let credentials = Credentials(mode: mode, slot: slot, ownerID: owner.id, accountID: result.id,
            cookies: credentialCookies(in: session, mode: mode))
        guard !credentials.cookies.isEmpty else { throw KomiicError.imageAccountExpired }
        var updated = sources
        updated[key] = Source(session: session, api: api, credentials: credentials, quota: result.quota)
        guard persist(updated) else { throw ConnectionError.keychainUnavailable }
        sources[key]?.session.invalidateAndCancel()
        sources = updated
        connected = true
    }

    func clear() {
        generation = UUID()
        sources.values.forEach { $0.session.invalidateAndCancel() }
        sources.removeAll()
        primaryExhaustion.removeAll()
        persistence.remove()
    }

    func refresh(mode: ComicContentMode) async {
        guard let owner = primary(mode)?.owner else { return }
        async let first: Void = refresh(.first, mode: mode, owner: owner)
        async let second: Void = refresh(.second, mode: mode, owner: owner)
        _ = await (first, second)
    }

    func imageData(for page: ComicPage, baseURL: URL) async throws -> Data {
        guard let mode = ComicContentMode.allCases.first(where: { $0.baseURL == baseURL }),
              sources.keys.contains(where: { $0.mode == mode }), let account = primary(mode) else {
            return try await primaryImage(page, baseURL)
        }
        let keys = ImageAccountSlot.allCases.map { Key(mode: mode, slot: $0) }
        guard keys.contains(where: { canUseSource($0, owner: account.owner) }) else {
            return try await primaryImage(page, baseURL)
        }

        let primaryExhausted = primaryExhaustion[mode].map { $0.owner == account.owner && $0.until > Date() } ?? false
        if !primaryExhausted {
            do { return try await primaryImage(page, baseURL) }
            catch KomiicError.imageQuotaExceeded {
                try requireCurrent(account.owner, mode: mode)
                primaryExhaustion[mode] = (account.owner, nextCheck(for: account.quota))
            }
        }

        for key in keys {
            try requireCurrent(account.owner, mode: mode)
            guard canUseSource(key, owner: account.owner), let source = sources[key],
                  (source.exhaustedUntil ?? .distantPast) <= Date() else { continue }
            defer { saveRefreshedCookies(for: key, session: source.session) }
            do {
                let data = try await source.api.imageData(for: page)
                try requireCurrent(account.owner, mode: mode)
                guard sources[key]?.session === source.session else { throw CancellationError() }
                return data
            } catch KomiicError.imageQuotaExceeded {
                if sources[key]?.session === source.session {
                    sources[key]?.exhaustedUntil = nextCheck(for: sources[key]?.quota)
                }
            } catch KomiicError.imageAccountExpired {
                if sources[key]?.session === source.session { sources[key]?.expired = true }
            }
        }
        throw KomiicError.imageQuotaExceeded
    }

    private func refresh(_ slot: ImageAccountSlot, mode: ComicContentMode, owner: ImageSourceOwner) async {
        let key = Key(mode: mode, slot: slot)
        guard canUseSource(key, owner: owner), let source = sources[key] else { return }
        let id = ObjectIdentifier(source.session)
        guard refreshing.insert(id).inserted else { return }
        defer {
            refreshing.remove(id)
            saveRefreshedCookies(for: key, session: source.session)
        }
        do {
            let quota = try await source.api.imageReadingQuota(accountID: source.credentials.accountID)
            try requireCurrent(owner, mode: mode)
            guard sources[key]?.session === source.session else { return }
            sources[key]?.quota = quota
            if quota.usage < quota.limit { sources[key]?.exhaustedUntil = nil }
        } catch KomiicError.authenticationRequired {
            if sources[key]?.session === source.session { sources[key]?.expired = true }
        } catch KomiicError.imageAccountExpired {
            if sources[key]?.session === source.session { sources[key]?.expired = true }
        } catch {
            // Keep the last verified quota through transient errors.
        }
    }

    private func canUseSource(_ key: Key, owner: ImageSourceOwner) -> Bool {
        guard let source = sources[key], source.credentials.ownerID == owner.id,
              source.credentials.accountID != owner.id, !source.expired else { return false }
        return !credentialCookies(in: source.session, mode: key.mode).isEmpty
    }

    private func requireCurrent(_ owner: ImageSourceOwner, mode: ComicContentMode) throws {
        try Task.checkCancellation()
        guard primary(mode)?.owner == owner else { throw CancellationError() }
    }

    private func nextCheck(for quota: ImageReadingQuota?) -> Date {
        let now = Date()
        if let quota, quota.resetAt > now { return quota.resetAt }
        return now.addingTimeInterval(60)
    }

    private func makeSession(cookies: [HTTPCookie], mode: ComicContentMode) -> URLSession {
        let configuration = sessionConfiguration()
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        let storage = session.configuration.httpCookieStorage
        precondition(storage != nil && storage !== HTTPCookieStorage.shared)
        for cookie in SessionCookieStore.credentialCookies(cookies, mode: mode) {
            if (cookie.expiresDate ?? .distantFuture) > Date() { storage?.setCookie(cookie) }
        }
        return session
    }

    private func credentialCookies(in session: URLSession, mode: ComicContentMode) -> [SessionCookieStore.Cookie] {
        let cookies = session.configuration.httpCookieStorage?.cookies(for: mode.baseURL) ?? []
        return SessionCookieStore.credentialCookies(cookies, mode: mode)
            .filter { ($0.expiresDate ?? .distantFuture) > Date() }
            .map(SessionCookieStore.Cookie.init)
            .sorted { "\($0.domain)|\($0.path)|\($0.name)" < "\($1.domain)|\($1.path)|\($1.name)" }
    }

    private func saveRefreshedCookies(for key: Key, session: URLSession) {
        guard var source = sources[key], source.session === session else { return }
        let cookies = credentialCookies(in: session, mode: key.mode)
        guard cookies != source.credentials.cookies else { return }
        source.credentials.cookies = cookies
        var updated = sources
        updated[key] = source
        if persist(updated) { sources = updated }
    }

    private func persist(_ sources: [Key: Source]) -> Bool {
        let credentials = sources.values.map(\.credentials)
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        persistence.save(data)
        return persistence.load() == data
    }
}
