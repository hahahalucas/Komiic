import Foundation
import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "����ϵͳ"; case .light: return "ǳɫ"; case .dark: return "��ɫ" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum ReadingMode: String, CaseIterable, Identifiable, Codable {
    case scroll, paged
    var id: String { rawValue }
    var title: String { self == .scroll ? "�������" : "����ҳ" }
}

/// These cases describe when disposable online image files should be removed.
enum CachePolicy: String, CaseIterable, Identifiable, Codable {
    case never, afterReading, oneDay
    var id: String { rawValue }
    var title: String {
        switch self { case .never: return "�����"; case .afterReading: return "�����"; case .oneDay: return "24 Сʱ��" }
    }
}

enum EInkMode: String, CaseIterable, Identifiable, Codable {
    case automatic, on, off
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "�Զ�"; case .on: return "����"; case .off: return "�ر�" }
    }
    // iPhone and iPad do not expose an electronic ink display capability.
    var enabled: Bool { self == .on }
}

enum ReaderOrientation: String, CaseIterable, Identifiable, Codable {
    case system, portrait, landscape
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "����ϵͳ"; case .portrait: return "��������"; case .landscape: return "��������" }
    }
    var mask: UIInterfaceOrientationMask {
        switch self { case .system: return .allButUpsideDown; case .portrait: return .portrait; case .landscape: return .landscape }
    }
}

enum ImageLoadingMode: String, CaseIterable, Identifiable, Codable {
    case online, download
    var id: String { rawValue }
    var title: String { self == .online ? "�����Ķ����Զ����棩" : "�������أ����ô洢��" }
}

@MainActor
final class ReaderSettings: ObservableObject {
    @Published var theme: AppTheme { didSet { save(theme.rawValue, "theme") } }
    @Published var contentMode: ComicContentMode { didSet { save(contentMode.rawValue, "contentMode") } }
    @Published private(set) var warningPreferences: [String: ContentWarningAction] {
        didSet {
            if let data = try? JSONEncoder().encode(warningPreferences) {
                defaults.set(data, forKey: "komiic.warningPreferences")
            }
        }
    }
    @Published private(set) var pendingWarningPreferences: [String: ContentWarningAction] {
        didSet {
            if let data = try? JSONEncoder().encode(pendingWarningPreferences) {
                defaults.set(data, forKey: "komiic.pendingWarningPreferences")
            }
        }
    }
    @Published var readingMode: ReadingMode { didSet { save(readingMode.rawValue, "readingMode") } }
    @Published var cachePolicy: CachePolicy { didSet { save(cachePolicy.rawValue, "cachePolicy") } }
    @Published var einkMode: EInkMode { didSet { save(einkMode.rawValue, "einkMode") } }
    @Published var orientation: ReaderOrientation { didSet { save(orientation.rawValue, "orientation") } }
    @Published var loadingMode: ImageLoadingMode { didSet { save(loadingMode.rawValue, "loadingMode") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "komiic.notificationsEnabled") } }
    @Published var chapterNotifications: Bool { didSet { defaults.set(chapterNotifications, forKey: "komiic.chapterNotifications") } }
    @Published var dimImages: Bool { didSet { defaults.set(dimImages, forKey: "komiic.dimImages") } }
    private let defaults: UserDefaults
    private var warningSyncTask: Task<String?, Never>?
    private var warningSyncMode: ComicContentMode?
    private var warningSyncGeneration = UUID()
    private var warningAccountID: String? {
        didSet { defaults.set(warningAccountID, forKey: "komiic.warningAccountID") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "komiic.theme") ?? "") ?? .system
        contentMode = ComicContentMode(rawValue: defaults.string(forKey: "komiic.contentMode") ?? "") ?? .general
        warningPreferences = defaults.data(forKey: "komiic.warningPreferences")
            .flatMap { try? JSONDecoder().decode([String: ContentWarningAction].self, from: $0) } ?? [:]
        pendingWarningPreferences = defaults.data(forKey: "komiic.pendingWarningPreferences")
            .flatMap { try? JSONDecoder().decode([String: ContentWarningAction].self, from: $0) } ?? [:]
        warningAccountID = defaults.string(forKey: "komiic.warningAccountID")
        readingMode = ReadingMode(rawValue: defaults.string(forKey: "komiic.readingMode") ?? "") ?? .scroll
        cachePolicy = CachePolicy(rawValue: defaults.string(forKey: "komiic.cachePolicy") ?? "") ?? .oneDay
        einkMode = EInkMode(rawValue: defaults.string(forKey: "komiic.einkMode") ?? "") ?? .automatic
        orientation = ReaderOrientation(rawValue: defaults.string(forKey: "komiic.orientation") ?? "") ?? .system
        loadingMode = ImageLoadingMode(rawValue: defaults.string(forKey: "komiic.loadingMode") ?? "") ?? .online
        notificationsEnabled = defaults.bool(forKey: "komiic.notificationsEnabled")
        chapterNotifications = defaults.object(forKey: "komiic.chapterNotifications") as? Bool ?? true
        dimImages = defaults.bool(forKey: "komiic.dimImages")
    }

    func warningAction(for tag: String) -> ContentWarningAction { warningPreferences[tag] ?? .show }

    func setWarningPreference(tag: String, action: ContentWarningAction) {
        warningPreferences[tag] = action
        pendingWarningPreferences[tag] = action
    }

    func markWarningPreferenceSynced(tag: String, action: ContentWarningAction) {
        if pendingWarningPreferences[tag] == action { pendingWarningPreferences.removeValue(forKey: tag) }
    }

    func applyWarningPreferences(_ preferences: [ContentWarningPreference]) {
        var merged = Dictionary(preferences.map { ($0.tag, $0.action) }, uniquingKeysWith: { _, latest in latest })
        merged.merge(pendingWarningPreferences) { _, local in local }
        warningPreferences = merged
    }

    func shouldHide(_ comic: Comic) -> Bool {
        comic.warnings.contains { warningAction(for: $0) == .hide }
    }

    func shouldBlur(_ comic: Comic) -> Bool {
        comic.warnings.contains { warningAction(for: $0) == .warn }
    }

    @discardableResult
    func syncWarningPreferences(mode: ComicContentMode) async -> String? {
        if let running = warningSyncTask, warningSyncMode == mode { return await running.value }
        warningSyncTask?.cancel()
        let generation = UUID()
        warningSyncGeneration = generation
        warningSyncMode = mode
        let task = Task { await performWarningSync(mode: mode, generation: generation) }
        warningSyncTask = task
        let result = await task.value
        if warningSyncGeneration == generation {
            warningSyncTask = nil
            warningSyncMode = nil
        }
        return result
    }

    /// Called before logging out so no queued edit can be replayed into another account.
    /// The local display choices remain available after the session ends.
    func cancelWarningSync() {
        warningSyncGeneration = UUID()
        warningSyncTask?.cancel()
        warningSyncTask = nil
        warningSyncMode = nil
        warningAccountID = nil
        pendingWarningPreferences = [:]
    }

    private func performWarningSync(mode: ComicContentMode, generation: UUID) async -> String? {
        await WebCookieBridge.synchronize()
        guard warningSyncGeneration == generation, mode == contentMode, !Task.isCancelled,
              OfficialAccountSession.isConnected(mode: mode) else { return nil }
        let api = KomiicAPI(mode: mode)
        do {
            guard let accountID = try await api.accountID() else { return nil }
            try Task.checkCancellation()
            guard warningSyncGeneration == generation, mode == contentMode else { return nil }
            if let previousAccount = warningAccountID, previousAccount != accountID {
                pendingWarningPreferences = [:]
            }
            warningAccountID = accountID
            let preferences = try await api.warningPreferences()
            try Task.checkCancellation()
            guard try await api.accountID() == accountID else { return nil }
            try Task.checkCancellation()
            guard warningSyncGeneration == generation, mode == contentMode else { return nil }
            applyWarningPreferences(preferences)
            while let (tag, action) = pendingWarningPreferences.sorted(by: { $0.key < $1.key }).first {
                try Task.checkCancellation()
                guard try await api.accountID() == accountID else { return nil }
                try Task.checkCancellation()
                guard warningSyncGeneration == generation, mode == contentMode else { return nil }
                let updated = try await api.setWarningPreference(tag: tag, action: action)
                try Task.checkCancellation()
                guard try await api.accountID() == accountID else { return nil }
                try Task.checkCancellation()
                guard warningSyncGeneration == generation, mode == contentMode else { return nil }
                markWarningPreferenceSynced(tag: tag, action: action)
                applyWarningPreferences(updated)
            }
            return nil
        } catch is CancellationError { return nil
        } catch {
            guard !Task.isCancelled, mode == contentMode else { return nil }
            return "�ѱ�������ƫ�ã�����ͬ��δ��ɡ�\(error.localizedDescription)"
        }
    }

    private func save(_ value: String, _ key: String) {
        defaults.set(value, forKey: "komiic.\(key)")
    }
}

enum OfficialAccountSession {
    static func isConnected(mode: ComicContentMode) -> Bool {
        (HTTPCookieStorage.shared.cookies(for: mode.baseURL) ?? []).contains {
            $0.name == "komiic-access-token" && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
    }
}
