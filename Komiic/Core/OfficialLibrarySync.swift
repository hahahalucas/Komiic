import Foundation

/// Injectable first-party operations keep account sync separate from local storage.
struct OfficialLibraryClient {
    var accountID: (ComicContentMode) async throws -> String?
    var favorites: (ComicContentMode, Int) async throws -> [Comic]
    var history: (ComicContentMode, Int) async throws -> [OfficialReadingHistory]
    var setFavorite: (ComicContentMode, String, Bool) async throws -> Void
    var recordProgress: (ComicContentMode, String, String, Int) async throws -> Void
    var shelves: (ComicContentMode) async throws -> [Bookshelf] = { _ in [] }
    var blockedComics: (ComicContentMode) async throws -> OfficialBlockedCollection = { _ in OfficialBlockedCollection() }
    var createShelf: (ComicContentMode, String) async throws -> Bookshelf = { _, _ in throw KomiicError.invalidResponse }
    var renameShelf: (ComicContentMode, String, String) async throws -> Void = { _, _, _ in throw KomiicError.invalidResponse }
    var deleteShelf: (ComicContentMode, String) async throws -> Void = { _, _ in throw KomiicError.invalidResponse }
    var setShelfComic: (ComicContentMode, String, String, Bool) async throws -> Void = { _, _, _, _ in throw KomiicError.invalidResponse }
    var setBlocked: (ComicContentMode, String, Bool) async throws -> Void = { _, _, _ in throw KomiicError.invalidResponse }

    static let live = OfficialLibraryClient(
        accountID: { try await KomiicAPI(mode: $0).accountID() },
        favorites: { try await KomiicAPI(mode: $0).favorites(offset: $1) },
        history: { try await KomiicAPI(mode: $0).readingHistory(offset: $1) },
        setFavorite: { try await KomiicAPI(mode: $0).setFavorite(comicID: $1, isFavorite: $2) },
        recordProgress: { try await KomiicAPI(mode: $0).recordProgress(comicID: $1, chapterID: $2, page: $3) },
        shelves: { try await KomiicAPI(mode: $0).bookshelves() },
        blockedComics: { try await KomiicAPI(mode: $0).blockedCollection() },
        createShelf: { try await KomiicAPI(mode: $0).createBookshelf(name: $1) },
        renameShelf: { try await KomiicAPI(mode: $0).renameBookshelf(id: $1, name: $2) },
        deleteShelf: { try await KomiicAPI(mode: $0).deleteBookshelf(id: $1) },
        setShelfComic: { try await KomiicAPI(mode: $0).setBookshelfComic(shelfID: $1, comicID: $2, adding: $3) },
        setBlocked: { try await KomiicAPI(mode: $0).setBlocked(comicID: $1, blocked: $2) }
    )
}

/// Retried only while the exact account that created the change is signed in.
struct OfficialLibraryMutation: Codable, Identifiable {
    enum Kind: String, Codable { case favorite, progress, createShelf, renameShelf, deleteShelf, shelfComic, blocked }
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
    var shelfID: UUID?
    var officialShelfID: String?
    var shelfName: String?
    var shelf: Bookshelf?
    var adding: Bool?
    var blocked: Bool?

    func supersedes(_ previous: OfficialLibraryMutation) -> Bool {
        guard accountID == previous.accountID, mode == previous.mode, kind == previous.kind,
              comicID == previous.comicID else { return false }
        switch kind {
        case .progress: return chapterID == previous.chapterID
        case .createShelf, .renameShelf, .deleteShelf, .shelfComic: return shelfID == previous.shelfID
        case .favorite, .blocked: return true
        }
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

struct OfficialCollectionEdit {
    var revision: Int
    var change: OfficialLibraryMutation
}

struct OfficialBlockedCollection {
    var ids: Set<String> = []
    var comics: [Comic] = []
}

struct OfficialCollectionLoad {
    var shelves: [Bookshelf]?
    var blockedIDs: Set<String>?
    var blockedComics: [Comic]?
    var error: String?
}

func officialResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

struct OfficialLibrarySnapshot: Codable, Sendable {
    var favorites: [Comic] = []
    var history: [ReadingProgress] = []
    var readChapterIDs: Set<String> = []
    var shelves: [Bookshelf] = []
    var blockedComicIDs: Set<String> = []
    var blockedComics: [Comic] = []

    mutating func applyCollectionChange(_ change: OfficialLibraryMutation) {
        let index = shelves.firstIndex {
            $0.id == change.shelfID || (change.officialShelfID != nil && $0.officialID == change.officialShelfID)
        }
        switch change.kind {
        case .createShelf:
            if index == nil, let shelf = change.shelf { shelves.append(shelf) }
        case .renameShelf:
            if let index, let name = change.shelfName { shelves[index].name = name }
        case .deleteShelf:
            if let index { shelves.remove(at: index) }
        case .shelfComic:
            if let index {
                shelves[index].comics.removeAll { $0.id == change.comicID }
                if change.adding == true, let comic = change.comic { shelves[index].comics.insert(comic, at: 0) }
            }
        case .blocked:
            blockedComicIDs.remove(change.comicID)
            blockedComics.removeAll { $0.id == change.comicID }
            if change.blocked == true {
                blockedComicIDs.insert(change.comicID)
                if let comic = change.comic { blockedComics.insert(comic, at: 0) }
            }
        case .favorite, .progress: break
        }
    }

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
            return ReadingProgress(comic: row.comic, chapter: Chapter(id: latest.chapterId, title: "继续阅读"),
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

struct CachedOfficialLibrary: Codable, Sendable {
    var accountID: String
    var snapshot: OfficialLibrarySnapshot
}
