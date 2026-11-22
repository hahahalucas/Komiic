import Foundation

enum CatalogFeed: String, CaseIterable, Identifiable, Sendable {
    case updated, newest, popular, recommended
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updated: return "最新更新"
        case .newest: return "最近上架"
        case .popular: return "当月最热"
        case .recommended: return "推荐漫画"
        }
    }
}

/// Numeric values match the first-party Pagination.sexyLevel input.
enum ContentFilter: Int, CaseIterable, Identifiable, Codable, Sendable {
    case all = -1, general = 0, suggestive = 1, levelTwo = 2, levelThree = 3, levelFour = 4, explicit = 5
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .general: return "无"
        case .suggestive: return "1 级"
        case .levelTwo: return "2 级"
        case .levelThree: return "3 级"
        case .levelFour: return "4 级及以上"
        case .explicit: return "5 级"
        }
    }
}

struct Comic: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var imageUrl: URL?
    var status: String
    var description: String?
    var authors: [String]
    var categories: [String]
    var views: Int
    var monthViews: Int
    var favoriteCount: Int
    var lastChapterUpdate: String?
    var lastBookUpdate: String?
    var dateUpdated: String?

    init(id: String, title: String, imageUrl: URL? = nil, status: String = "ONGOING",
         description: String? = nil, authors: [String] = [], categories: [String] = [],
         views: Int = 0, monthViews: Int = 0, favoriteCount: Int = 0,
         lastChapterUpdate: String? = nil, lastBookUpdate: String? = nil, dateUpdated: String? = nil) {
        self.id = id; self.title = title; self.imageUrl = imageUrl; self.status = status
        self.description = description; self.authors = authors; self.categories = categories
        self.views = views; self.monthViews = monthViews; self.favoriteCount = favoriteCount
        self.lastChapterUpdate = lastChapterUpdate; self.lastBookUpdate = lastBookUpdate
        self.dateUpdated = dateUpdated
    }

    enum CodingKeys: String, CodingKey {
        case id, title, imageUrl, status, description, authors, categories, views, monthViews
        case favoriteCount, lastChapterUpdate, lastBookUpdate, dateUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredString(.id)
        title = try c.decode(String.self, forKey: .title)
        imageUrl = c.flexibleString(.imageUrl).flatMap(URL.init(string:))
        status = c.flexibleString(.status) ?? "ONGOING"
        description = c.flexibleString(.description)
        authors = c.names(.authors)
        categories = c.names(.categories)
        views = c.flexibleInt(.views)
        monthViews = c.flexibleInt(.monthViews)
        favoriteCount = c.flexibleInt(.favoriteCount)
        lastChapterUpdate = c.flexibleString(.lastChapterUpdate)
        lastBookUpdate = c.flexibleString(.lastBookUpdate)
        dateUpdated = c.flexibleString(.dateUpdated)
    }

}

struct Chapter: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var serial: String
    var type: String
    var size: Int

    init(id: String, title: String = "", serial: String = "", type: String = "chapter", size: Int = 0) {
        self.id = id; self.serial = serial; self.type = type; self.size = size
        self.title = title.isEmpty ? Self.makeTitle(serial: serial, type: type) : title
    }

    enum CodingKeys: String, CodingKey { case id, title, serial, type, size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredString(.id)
        serial = c.flexibleString(.serial) ?? ""
        type = c.flexibleString(.type) ?? "chapter"
        size = c.flexibleInt(.size)
        title = c.flexibleString(.title) ?? Self.makeTitle(serial: serial, type: type)
    }

    private static func makeTitle(serial: String, type: String) -> String {
        switch type {
        case "book": return "第 \(serial) 卷"
        case "short": return serial.isEmpty ? "短篇" : "短篇 \(serial)"
        default: return "第 \(serial) 话"
        }
    }
}

struct ComicPage: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kid: String
    var width: Int
    var height: Int

    init(id: String, kid: String, width: Int = 0, height: Int = 0) {
        self.id = id; self.kid = kid; self.width = width; self.height = height
    }

    enum CodingKeys: String, CodingKey { case id, kid, width, height }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kid = try c.decode(String.self, forKey: .kid)
        id = c.flexibleString(.id) ?? kid
        width = c.flexibleInt(.width)
        height = c.flexibleInt(.height)
    }
}

private struct NamedValue: Decodable { let name: String }
private extension KeyedDecodingContainer {
    func flexibleString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
    func requiredString(_ key: Key) throws -> String {
        guard let value = flexibleString(key), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Missing identifier")
        }
        return value
    }
    func flexibleInt(_ key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }
    func names(_ key: Key) -> [String] {
        if let values = try? decode([String].self, forKey: key) { return values }
        return ((try? decode([NamedValue].self, forKey: key)) ?? []).map(\.name)
    }
}
