import Foundation
import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum ReadingMode: String, CaseIterable, Identifiable, Codable {
    case scroll, paged
    var id: String { rawValue }
    var title: String { self == .scroll ? "纵向滚动" : "横向翻页" }
}

enum ReadingDirection: String, CaseIterable, Identifiable, Codable {
    case right, left
    var id: String { rawValue }
    var title: String { self == .right ? "向右阅读" : "向左阅读" }
}

/// These cases describe when disposable online image files should be removed.
enum CachePolicy: String, CaseIterable, Identifiable, Codable {
    case never, afterReading, oneDay
    var id: String { rawValue }
    var title: String {
        switch self { case .never: return "不清除"; case .afterReading: return "读完后"; case .oneDay: return "24 小时后" }
    }
}

enum EInkMode: String, CaseIterable, Identifiable, Codable {
    case automatic, on, off
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动"; case .on: return "开启"; case .off: return "关闭" }
    }
    // iPhone and iPad do not expose an electronic ink display capability.
    var enabled: Bool { self == .on }
}

enum ReaderOrientation: String, CaseIterable, Identifiable, Codable {
    case system, portrait, landscape
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .portrait: return "锁定竖向"; case .landscape: return "锁定横向" }
    }
    var mask: UIInterfaceOrientationMask {
        switch self { case .system: return .allButUpsideDown; case .portrait: return .portrait; case .landscape: return .landscape }
    }
}

enum ImageLoadingMode: String, CaseIterable, Identifiable, Codable {
    case online, download
    var id: String { rawValue }
    var title: String { self == .online ? "在线阅读（自动缓存）" : "离线下载（永久存储）" }
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
    @Published var readingDirection: ReadingDirection { didSet { save(readingDirection.rawValue, "readingDirection") } }
    @Published private(set) var revealedWarningCovers: Set<String> = []
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
        readingDirection = ReadingDirection(rawValue: defaults.string(forKey: "komiic.readingDirection") ?? "") ?? .right
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
        revealedWarningCovers = []
        warningPreferences[tag] = action
        pendingWarningPreferences[tag] = action
    }

    func markWarningPreferenceSynced(tag: String, action: ContentWarningAction) {
        if pendingWarningPreferences[tag] == action { pendingWarningPreferences.removeValue(forKey: tag) }
    }

    func applyWarningPreferences(_ preferences: [ContentWarningPreference]) {
        var merged = Dictionary(preferences.map { ($0.tag, $0.action) }, uniquingKeysWith: { _, latest in latest })
        merged.merge(pendingWarningPreferences) { _, local in local }
        if merged != warningPreferences { revealedWarningCovers = [] }
        warningPreferences = merged
    }

    func shouldHide(_ comic: Comic) -> Bool {
        comic.warnings.contains { warningAction(for: $0) == .hide }
    }

    func shouldBlur(_ comic: Comic) -> Bool {
        comic.warnings.contains { warningAction(for: $0) == .warn }
            && !revealedWarningCovers.contains("\(contentMode.rawValue):\(comic.id)")
    }

    func revealWarningCover(_ comic: Comic) {
        guard !shouldHide(comic) else { return }
        revealedWarningCovers.insert("\(contentMode.rawValue):\(comic.id)")
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
            return "已保留本机偏好，官网同步未完成。\(error.localizedDescription)"
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
