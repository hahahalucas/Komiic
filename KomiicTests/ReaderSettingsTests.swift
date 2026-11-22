import XCTest
@testable import Komiic

@MainActor
final class ReaderSettingsTests: XCTestCase {
    func testWarningCoverIsRevealedBeforeOpeningAndHiddenPreferenceStillWins() throws {
        let settings = ReaderSettings(defaults: try defaults())
        let comic = Comic(id: "warning", title: "警告漫画", warnings: ["血腥"])
        settings.setWarningPreference(tag: "血腥", action: .warn)
        XCTAssertTrue(settings.shouldBlur(comic))
        settings.revealWarningCover(comic)
        XCTAssertFalse(settings.shouldBlur(comic))
        settings.contentMode = .adult
        XCTAssertTrue(settings.shouldBlur(comic))
        settings.setWarningPreference(tag: "血腥", action: .hide)
        settings.revealWarningCover(comic)
        XCTAssertTrue(settings.shouldHide(comic))
    }

    func testReadingDirectionSurvivesRestart() throws {
        let defaults = try defaults()
        let settings = ReaderSettings(defaults: defaults)
        settings.readingDirection = .left
        XCTAssertEqual(ReaderSettings(defaults: defaults).readingDirection, .left)
    }
    private func defaults() throws -> UserDefaults {
        let suite = "KomiicReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testContentModeAndOfflineWarningChoiceSurviveRestart() throws {
        let defaults = try defaults()
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.contentMode, .general)
        settings.contentMode = .adult
        settings.setWarningPreference(tag: "獵奇", action: .hide)
        let restored = ReaderSettings(defaults: defaults)
        XCTAssertEqual(restored.contentMode, .adult)
        XCTAssertEqual(restored.warningAction(for: "獵奇"), .hide)
        XCTAssertEqual(restored.pendingWarningPreferences["獵奇"], .hide)
        XCTAssertTrue(restored.shouldHide(Comic(id: "1", title: "测试", warnings: ["獵奇"])))
    }

    func testOfficialRefreshPreservesUnsyncedChoiceAndAllowsRemovingOverride() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.setWarningPreference(tag: "血腥", action: .hide)
        settings.applyWarningPreferences([ContentWarningPreference(tag: "血腥", action: .warn),
                                          ContentWarningPreference(tag: "BL", action: .warn)])
        XCTAssertEqual(settings.warningAction(for: "血腥"), .hide)
        XCTAssertEqual(settings.warningAction(for: "BL"), .warn)
        settings.markWarningPreferenceSynced(tag: "血腥", action: .hide)
        settings.applyWarningPreferences([])
        XCTAssertEqual(settings.warningAction(for: "血腥"), .show)
        XCTAssertEqual(settings.warningAction(for: "BL"), .show)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
    }

    func testDelayedSyncAcknowledgmentDoesNotEraseNewerChoice() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.setWarningPreference(tag: "血腥", action: .warn)
        settings.setWarningPreference(tag: "血腥", action: .hide)
        settings.markWarningPreferenceSynced(tag: "血腥", action: .warn)
        settings.applyWarningPreferences([ContentWarningPreference(tag: "血腥", action: .warn)])
        XCTAssertEqual(settings.pendingWarningPreferences["血腥"], .hide)
        XCTAssertEqual(settings.warningAction(for: "血腥"), .hide)
    }

    func testWarningsAffectMatchingTagsWithoutHidingUnlabelledComics() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.applyWarningPreferences([ContentWarningPreference(tag: "獵奇", action: .hide),
                                          ContentWarningPreference(tag: "血腥", action: .warn)])
        let hidden = Comic(id: "1", title: "隐藏", warnings: ["獵奇", "血腥"])
        let blurred = Comic(id: "2", title: "模糊", warnings: ["血腥"])
        let ordinary = Comic(id: "3", title: "普通", warnings: [])
        XCTAssertTrue(settings.shouldHide(hidden))
        XCTAssertFalse(settings.shouldHide(blurred))
        XCTAssertTrue(settings.shouldBlur(blurred))
        XCTAssertFalse(settings.shouldHide(ordinary))
        XCTAssertFalse(settings.shouldBlur(ordinary))
    }

    func testMalformedSavedPreferencesUseSafeDefaults() throws {
        let defaults = try defaults()
        defaults.set(Data("broken preferences".utf8), forKey: "komiic.warningPreferences")
        defaults.set("unknown-mode", forKey: "komiic.contentMode")
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.contentMode, .general)
        XCTAssertEqual(settings.warningAction(for: "血腥"), .show)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
    }

    func testSignOutKeepsDisplayChoiceButDropsPendingAccountWrites() throws {
        let defaults = try defaults()
        let settings = ReaderSettings(defaults: defaults)
        settings.setWarningPreference(tag: "血腥", action: .hide)
        settings.cancelWarningSync()
        XCTAssertEqual(settings.warningAction(for: "血腥"), .hide)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
        XCTAssertTrue(ReaderSettings(defaults: defaults).pendingWarningPreferences.isEmpty)
    }
}
