import Foundation

/// Injectable first-party operations keep account sync separate from local storage.
struct OfficialLibraryClient {
    var accountID: (ComicContentMode) async throws -> String?
    var favorites: (ComicContentMode, Int) async throws -> [Comic]
    var history: (ComicContentMode, Int) async throws -> [OfficialReadingHistory]
    var setFavorite: (ComicContentMode, String, Bool) async throws -> Void
    var recordProgress: (ComicContentMode, String, String, Int) async throws -> Void

    static let live = OfficialLibraryClient(
        accountID: { try await KomiicAPI(mode: $0).accountID() },
        favorites: { try await KomiicAPI(mode: $0).favorites(offset: $1) },
        history: { try await KomiicAPI(mode: $0).readingHistory(offset: $1) },
        setFavorite: { try await KomiicAPI(mode: $0).setFavorite(comicID: $1, isFavorite: $2) },
        recordProgress: { try await KomiicAPI(mode: $0).recordProgress(comicID: $1, chapterID: $2, page: $3) }
    )
}

/// Retried only while the exact account that created the change is signed in.
struct OfficialLibraryMutation: Codable, Identifiable {
    enum Kind: String, Codable { case favorite, progress }
    var id = UUID()
    var accountID: String
    var mode: ComicContentMode
    var kind: Kind
    var comicID: String
    var favorite: Bool?
    var chapterID: String?
    var page: Int?
    var comic: Comic?
    var progress: ReadingProgress?

    func supersedes(_ previous: OfficialLibraryMutation) -> Bool {
        accountID == previous.accountID && mode == previous.mode && kind == previous.kind
            && comicID == previous.comicID && (kind == .favorite || chapterID == previous.chapterID)
    }
}

struct OfficialFavoriteEdit {
    var revision: Int
    var accountID: String
    var comic: Comic
    var favorite: Bool
}

struct OfficialProgressEdit {
    var revision: Int
    var accountID: String
    var progress: ReadingProgress
}

struct OfficialLibrarySnapshot {
    var favorites: [Comic] = []
    var history: [ReadingProgress] = []
    var readChapterIDs: Set<String> = []

    init(favorites: [Comic] = [], history: [OfficialReadingHistory] = []) {
        self.favorites = favorites
        self.history = history.compactMap { row in
            guard let latest = row.chapters.enumerated().max(by: { left, right in
                let leftDate = Self.date(left.element.updatedAt) ?? .distantPast
                let rightDate = Self.date(right.element.updatedAt) ?? .distantPast
                return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
            })?.element else { return nil }
            // The official history response does not include chapter titles or page totals.
            // A zero total means unknown until the reader fetches the actual chapter pages.
            return ReadingProgress(comic: row.comic, chapter: Chapter(id: latest.chapterId, title: "�����Ķ�"),
                page: max(0, latest.page), totalPages: 0,
                date: Self.date(latest.updatedAt) ?? Self.date(row.lastDate) ?? .distantPast)
        }
        readChapterIDs = Set(history.flatMap { $0.chapters.map(\.chapterId) })
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
