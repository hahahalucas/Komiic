import XCTest
@testable import Komiic

@MainActor
final class ReaderSettingsTests: XCTestCase {
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
        settings.setWarningPreference(tag: "�C��", action: .hide)
        let restored = ReaderSettings(defaults: defaults)
        XCTAssertEqual(restored.contentMode, .adult)
        XCTAssertEqual(restored.warningAction(for: "�C��"), .hide)
        XCTAssertEqual(restored.pendingWarningPreferences["�C��"], .hide)
        XCTAssertTrue(restored.shouldHide(Comic(id: "1", title: "����", warnings: ["�C��"])))
    }

    func testOfficialRefreshPreservesUnsyncedChoiceAndAllowsRemovingOverride() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.setWarningPreference(tag: "Ѫ��", action: .hide)
        settings.applyWarningPreferences([ContentWarningPreference(tag: "Ѫ��", action: .warn),
                                          ContentWarningPreference(tag: "BL", action: .warn)])
        XCTAssertEqual(settings.warningAction(for: "Ѫ��"), .hide)
        XCTAssertEqual(settings.warningAction(for: "BL"), .warn)
        settings.markWarningPreferenceSynced(tag: "Ѫ��", action: .hide)
        settings.applyWarningPreferences([])
        XCTAssertEqual(settings.warningAction(for: "Ѫ��"), .show)
        XCTAssertEqual(settings.warningAction(for: "BL"), .show)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
    }

    func testDelayedSyncAcknowledgmentDoesNotEraseNewerChoice() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.setWarningPreference(tag: "Ѫ��", action: .warn)
        settings.setWarningPreference(tag: "Ѫ��", action: .hide)
        settings.markWarningPreferenceSynced(tag: "Ѫ��", action: .warn)
        settings.applyWarningPreferences([ContentWarningPreference(tag: "Ѫ��", action: .warn)])
        XCTAssertEqual(settings.pendingWarningPreferences["Ѫ��"], .hide)
        XCTAssertEqual(settings.warningAction(for: "Ѫ��"), .hide)
    }

    func testWarningsAffectMatchingTagsWithoutHidingUnlabelledComics() throws {
        let settings = ReaderSettings(defaults: try defaults())
        settings.applyWarningPreferences([ContentWarningPreference(tag: "�C��", action: .hide),
                                          ContentWarningPreference(tag: "Ѫ��", action: .warn)])
        let hidden = Comic(id: "1", title: "����", warnings: ["�C��", "Ѫ��"])
        let blurred = Comic(id: "2", title: "ģ��", warnings: ["Ѫ��"])
        let ordinary = Comic(id: "3", title: "��ͨ", warnings: [])
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
        XCTAssertEqual(settings.warningAction(for: "Ѫ��"), .show)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
    }

    func testSignOutKeepsDisplayChoiceButDropsPendingAccountWrites() throws {
        let defaults = try defaults()
        let settings = ReaderSettings(defaults: defaults)
        settings.setWarningPreference(tag: "Ѫ��", action: .hide)
        settings.cancelWarningSync()
        XCTAssertEqual(settings.warningAction(for: "Ѫ��"), .hide)
        XCTAssertTrue(settings.pendingWarningPreferences.isEmpty)
        XCTAssertTrue(ReaderSettings(defaults: defaults).pendingWarningPreferences.isEmpty)
    }
}
