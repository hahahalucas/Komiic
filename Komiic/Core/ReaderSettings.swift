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
    @Published var readingMode: ReadingMode { didSet { save(readingMode.rawValue, "readingMode") } }
    @Published var cachePolicy: CachePolicy { didSet { save(cachePolicy.rawValue, "cachePolicy") } }
    @Published var einkMode: EInkMode { didSet { save(einkMode.rawValue, "einkMode") } }
    @Published var orientation: ReaderOrientation { didSet { save(orientation.rawValue, "orientation") } }
    @Published var loadingMode: ImageLoadingMode { didSet { save(loadingMode.rawValue, "loadingMode") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "komiic.notificationsEnabled") } }
    @Published var chapterNotifications: Bool { didSet { defaults.set(chapterNotifications, forKey: "komiic.chapterNotifications") } }
    @Published var dimImages: Bool { didSet { defaults.set(dimImages, forKey: "komiic.dimImages") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "komiic.theme") ?? "") ?? .system
        readingMode = ReadingMode(rawValue: defaults.string(forKey: "komiic.readingMode") ?? "") ?? .scroll
        cachePolicy = CachePolicy(rawValue: defaults.string(forKey: "komiic.cachePolicy") ?? "") ?? .oneDay
        einkMode = EInkMode(rawValue: defaults.string(forKey: "komiic.einkMode") ?? "") ?? .automatic
        orientation = ReaderOrientation(rawValue: defaults.string(forKey: "komiic.orientation") ?? "") ?? .system
        loadingMode = ImageLoadingMode(rawValue: defaults.string(forKey: "komiic.loadingMode") ?? "") ?? .online
        notificationsEnabled = defaults.bool(forKey: "komiic.notificationsEnabled")
        chapterNotifications = defaults.object(forKey: "komiic.chapterNotifications") as? Bool ?? true
        dimImages = defaults.bool(forKey: "komiic.dimImages")
    }

    private func save(_ value: String, _ key: String) {
        defaults.set(value, forKey: "komiic.\(key)")
    }
}
