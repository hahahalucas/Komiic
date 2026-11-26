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

/// The website sends an empty string when it renders a text avatar.
struct OfficialProfileImage: Decodable, Sendable {
    var url: URL?

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let string = try? value.decode(String.self),
              let parsed = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme?.lowercased() == "https", let host = parsed.host, !host.isEmpty else {
            url = nil
            return
        }
        url = parsed
    }
}

struct KomiicAccountProfile: Codable, Sendable {
    var id: String
    var username: String
    var email: String?
    var dateCreated: String?
    var profileImageURL: URL?
    var profileText: String?
    var warningPreferences: [ContentWarningPreference]
    var profileTextColor: String? = nil
    var profileBackgroundColor: String? = nil
    var readingStats: AccountReadingStats? = nil
    var imageQuota: ImageReadingQuota? = nil
    var messageStats: AccountMessageStats? = nil

    private enum CodingKeys: String, CodingKey {
        case id, username, email, dateCreated, profileImageURL, profileText, warningPreferences
        case profileTextColor, profileBackgroundColor
        case readingStats, imageQuota, messageStats
    }
}

struct AccountReadingStats: Codable, Sendable {
    let comicsRead: Int
    let chaptersRead: Int
    let favoriteCount: Int
    let bookmarkCount: Int
    let folderCount: Int
    let followingFolderCount: Int
    let topCategories: [ProfileCategoryCount]
}

struct ImageReadingQuota: Codable, Sendable {
    let usage: Int
    let limit: Int
    let resetAt: Date

    var fractionUsed: Double { limit > 0 ? min(1, max(0, Double(usage) / Double(limit))) : 0 }
}

struct AccountMessageStats: Codable, Sendable {
    let totalMessages: Int
    let totalUpvotes: Int
}

extension KomiicAccountProfile {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        username = try values.decode(String.self, forKey: .username)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        dateCreated = try values.decodeIfPresent(String.self, forKey: .dateCreated)
        profileImageURL = try values.decodeIfPresent(URL.self, forKey: .profileImageURL)
        profileText = try values.decodeIfPresent(String.self, forKey: .profileText)
        profileTextColor = try values.decodeIfPresent(String.self, forKey: .profileTextColor)
        profileBackgroundColor = try values.decodeIfPresent(String.self, forKey: .profileBackgroundColor)
        warningPreferences = try values.decode([ContentWarningPreference].self, forKey: .warningPreferences)
        readingStats = try values.decodeIfPresent(AccountReadingStats.self, forKey: .readingStats)
        imageQuota = try values.decodeIfPresent(ImageReadingQuota.self, forKey: .imageQuota)
        messageStats = try values.decodeIfPresent(AccountMessageStats.self, forKey: .messageStats)

        // 0.9.0 stored statistics alongside the identity fields.
        if let legacy = try? LegacyStatistics(from: decoder) {
            readingStats = AccountReadingStats(comicsRead: legacy.readComicCount, chaptersRead: legacy.readChapterCount,
                favoriteCount: legacy.favoriteCount, bookmarkCount: legacy.bookmarkCount, folderCount: legacy.folderCount,
                followingFolderCount: legacy.followedFolderCount, topCategories: legacy.topCategories)
            imageQuota = ImageReadingQuota(usage: legacy.imageReadCount, limit: legacy.imageReadLimit, resetAt: legacy.resetAt)
            messageStats = AccountMessageStats(totalMessages: legacy.commentCount, totalUpvotes: legacy.commentLikes)
        }
    }

    private struct LegacyStatistics: Decodable {
        let readComicCount: Int
        let readChapterCount: Int
        let imageReadCount: Int
        let imageReadLimit: Int
        let resetAt: Date
        let commentCount: Int
        let commentLikes: Int
        let favoriteCount: Int
        let bookmarkCount: Int
        let folderCount: Int
        let followedFolderCount: Int
        let topCategories: [ProfileCategoryCount]
    }
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
