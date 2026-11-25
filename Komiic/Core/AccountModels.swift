import Foundation

/// The website selects its catalog and account collections using the h. origin.
enum ComicContentMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case general = "REGULAR", adult = "H_MANGA"
    var id: String { rawValue }
    var title: String { self == .general ? "一般漫画" : "H 漫画" }
    var baseURL: URL { URL(string: self == .general ? "https://komiic.cc" : "https://h.komiic.cc")! }
}

/// SHOW is represented by null in the official mutation, removing an override.
enum ContentWarningAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case show = "SHOW", warn = "WARN", hide = "HIDE"
    var id: String { rawValue }
    var title: String {
        switch self { case .show: return "显示"; case .warn: return "模糊显示"; case .hide: return "完全隐藏" }
    }
}

struct ContentWarningPreference: Codable, Hashable, Sendable {
    var tag: String
    var action: ContentWarningAction
}

struct ProfileCategoryCount: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var count: Int
}

struct KomiicAccountProfile: Codable, Sendable {
    var id: String
    var username: String
    var email: String
    var dateCreated: String
    var profileImageURL: URL?
    var profileText: String?
    var readComicCount: Int
    var readChapterCount: Int
    var imageReadCount: Int
    var imageReadLimit: Int
    var resetAt: Date
    var commentCount: Int
    var commentLikes: Int
    var favoriteCount: Int
    var bookmarkCount: Int
    var folderCount: Int
    var followedFolderCount: Int
    var topCategories: [ProfileCategoryCount]
    var warningPreferences: [ContentWarningPreference]
}

struct OfficialChapterProgress: Decodable, Sendable {
    var chapterId: String
    /// The first-party reader also stores a zero-based image index.
    var page: Int
    var updatedAt: String?
}

struct OfficialReadingHistory: Sendable {
    var comic: Comic
    var chapters: [OfficialChapterProgress]
    var lastDate: String?
}
