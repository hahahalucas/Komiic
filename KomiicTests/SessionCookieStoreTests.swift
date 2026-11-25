import XCTest
@testable import Komiic

final class SessionCookieStoreTests: XCTestCase {
    func testSessionOnlyCookiesAndAccountScopeSurviveRestart() throws {
        let memory = MemorySessionData()
        let store = SessionCookieStore(persistence: memory.persistence)
        store.capture([try cookie("komiic-access-token", value: "access"), try cookie("komiic-refresh-token", value: "refresh")])
        let scope = try XCTUnwrap(store.scope(for: .general))
        let restored = SessionCookieStore(persistence: memory.persistence)
        XCTAssertEqual(Set(restored.restoredCookies().map(\.name)), ["komiic-access-token", "komiic-refresh-token"])
        XCTAssertEqual(restored.scope(for: .general), scope)
        XCTAssertTrue(restored.restoredCookies().allSatisfy { $0.expiresDate == nil })
    }

    func testRefreshPreservesScopeWhileExplicitAccountChangeReplacesIt() throws {
        let store = SessionCookieStore(persistence: MemorySessionData().persistence)
        store.capture([try cookie("komiic-refresh-token", value: "first")])
        let scope = store.scope(for: .general)
        store.capture([try cookie("komiic-refresh-token", value: "renewed")])
        XCTAssertEqual(store.scope(for: .general), scope)
        store.capture([try cookie("komiic-refresh-token", value: "another-account")], changedAccounts: [.general])
        XCTAssertNotEqual(store.scope(for: .general), scope)
    }

    func testLogoutClearsPersistedCredentialsAndRejectsDelayedOldWrites() throws {
        let memory = MemorySessionData()
        let store = SessionCookieStore(persistence: memory.persistence)
        let cookies = [try cookie("komiic-refresh-token", value: "old-session")]
        store.capture(cookies)
        let generation = store.generation
        store.clear()
        store.capture(cookies, generation: generation)
        XCTAssertNil(memory.bytes)
        XCTAssertTrue(store.restoredCookies().isEmpty)
        XCTAssertNil(SessionCookieStore(persistence: memory.persistence).scope(for: .general))
    }

    func testExpiredAndNonOfficialCookiesAreNotRestored() throws {
        let store = SessionCookieStore(persistence: MemorySessionData().persistence)
        let foreign = try XCTUnwrap(HTTPCookie(properties: [.name: "komiic-refresh-token", .value: "foreign", .domain: "example.invalid", .path: "/"]))
        let expired = try cookie("komiic-access-token", value: "expired", expires: Date(timeIntervalSinceNow: -60))
        store.capture([foreign, expired])
        XCTAssertTrue(store.restoredCookies().isEmpty)
        XCTAssertNil(store.scope(for: .general))
    }

    func testLifecycleCaptureCannotRecreateSessionDuringLogout() throws {
        let store = SessionCookieStore(persistence: MemorySessionData().persistence)
        let cookies = [try cookie("komiic-refresh-token", value: "old")]
        store.capture(cookies)
        store.beginClearing()
        store.capture(cookies)
        XCTAssertNil(store.scope(for: .general))
        XCTAssertTrue(store.restoredCookies().isEmpty)
        store.endClearing()
        store.capture([try cookie("komiic-refresh-token", value: "new")])
        XCTAssertNotNil(store.scope(for: .general))
    }

    func testUnchangedRequestsDoNotRewriteKeychainData() throws {
        let memory = MemorySessionData()
        let store = SessionCookieStore(persistence: memory.persistence)
        let cookies = [try cookie("komiic-refresh-token", value: "same")]
        store.capture(cookies)
        store.capture(cookies)
        store.capture(cookies)
        XCTAssertEqual(memory.writes, 1)
    }

    private func cookie(_ name: String, value: String, expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: "komiic.cc", .path: "/", .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}

private final class MemorySessionData {
    var bytes: Data?
    var writes = 0
    var persistence: SessionPersistence {
        SessionPersistence(load: { self.bytes }, save: { self.bytes = $0; self.writes += 1 }, remove: { self.bytes = nil })
    }
}
