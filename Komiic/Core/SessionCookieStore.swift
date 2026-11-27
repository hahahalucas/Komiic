import Foundation
import Security
import CryptoKit

extension Notification.Name {
    static let komiicSessionDidChange = Notification.Name("Komiic.SessionDidChange")
}

struct SessionPersistence {
    var load: () -> Data?
    var save: (Data) -> Void
    var remove: () -> Void

    static let keychain = keychain(account: "official-cookies")

    static func keychain(account: String) -> SessionPersistence {
        let itemQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Komiic.session.v1", kSecAttrAccount as String: account]
        return SessionPersistence(load: {
            var query = itemQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }, save: { data in
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = itemQuery
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                _ = SecItemAdd(item as CFDictionary, nil)
            }
        }, remove: { _ = SecItemDelete(itemQuery as CFDictionary) })
    }
}

/// Preserves session-only cookies too, without extending any explicit expiration date.
final class SessionCookieStore: @unchecked Sendable {
    static let shared = SessionCookieStore()
    struct Cookie: Codable, Equatable {
        var name: String, value: String, domain: String, path: String
        var expires: Date?
        var secure: Bool, httpOnly: Bool
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
        }
        var restored: HTTPCookie? {
            guard expires == nil || expires! > Date() else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
    private struct Archive: Codable {
        var cookies: [Cookie] = []
        var scopes: [String: String] = [:]
    }
    private let persistence: SessionPersistence
    private let lock = NSLock()
    private var archive: Archive
    private var encoded: Data?
    private var revision = UUID()
    private var clearing = 0

    init(persistence: SessionPersistence = .keychain) {
        self.persistence = persistence
        let data = persistence.load()
        encoded = data
        archive = data.flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }
    var generation: UUID { lock.withLock { revision } }

    func restoredCookies() -> [HTTPCookie] { lock.withLock { archive.cookies.compactMap(\.restored) } }

    func restore() { restoredCookies().forEach { HTTPCookieStorage.shared.setCookie($0) } }

    func scope(for mode: ComicContentMode) -> String? {
        lock.withLock {
            guard Self.hasCredentials(archive.cookies.compactMap(\.restored), for: mode) else { return nil }
            return archive.scopes[mode.rawValue]
        }
    }

    func capture(_ cookies: [HTTPCookie] = HTTPCookieStorage.shared.cookies ?? [],
                 changedAccounts: Set<ComicContentMode> = [], generation: UUID? = nil) {
        let changed: Bool = lock.withLock {
            guard clearing == 0 else { return false }
            if let generation, generation != revision { return false }
            let previous = archive.scopes
            if !changedAccounts.isEmpty { revision = UUID() }
            archive.cookies = cookies.filter(Self.isOfficial).map(Cookie.init).sorted {
                "\($0.domain)|\($0.path)|\($0.name)" < "\($1.domain)|\($1.path)|\($1.name)"
            }
            for mode in ComicContentMode.allCases {
                if !Self.hasCredentials(cookies, for: mode) { archive.scopes[mode.rawValue] = nil }
                else if archive.scopes[mode.rawValue] == nil || changedAccounts.contains(mode) {
                    archive.scopes[mode.rawValue] = UUID().uuidString
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(archive), data != encoded {
                encoded = data
                persistence.save(data)
            }
            return previous != archive.scopes
        }
        if changed { NotificationCenter.default.post(name: .komiicSessionDidChange, object: nil) }
    }

    func clear() {
        lock.withLock {
            revision = UUID(); archive = Archive(); encoded = nil
            persistence.remove()
        }
        NotificationCenter.default.post(name: .komiicSessionDidChange, object: nil)
    }

    func beginClearing() {
        lock.withLock { clearing += 1 }
        clear()
    }
    func endClearing() { lock.withLock { clearing = max(0, clearing - 1) } }

    static func isOfficial(_ cookie: HTTPCookie) -> Bool {
        cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc")
    }
    static func credentialSignature(_ cookies: [HTTPCookie], mode: ComicContentMode) -> String {
        let rows = credentialCookies(cookies, mode: mode)
            .map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func credentialCookies(_ cookies: [HTTPCookie], mode: ComicContentMode) -> [HTTPCookie] {
        cookies.filter { matches($0, mode: mode) && isCredential($0) }
    }
    private static func hasCredentials(_ cookies: [HTTPCookie], for mode: ComicContentMode) -> Bool {
        credentialCookies(cookies, mode: mode).contains { ($0.expiresDate ?? .distantFuture) > Date() }
    }
    private static func isCredential(_ cookie: HTTPCookie) -> Bool {
        ["komiic-access-token", "komiic-refresh-token"].contains(cookie.name)
    }
    private static func matches(_ cookie: HTTPCookie, mode: ComicContentMode) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        let host = mode.baseURL.host ?? ""
        return isOfficial(cookie) && (host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain)))
    }
}
