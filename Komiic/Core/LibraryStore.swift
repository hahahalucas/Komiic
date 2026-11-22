import Foundation
import Combine

struct ReadingBookmark: Codable, Identifiable {
    var comic: Comic
    var chapter: Chapter
    /// A zero-based image index, shared with the reader and offline manifests.
    var page: Int
    var date: Date
    var id: String { "\(chapter.id):\(page)" }
}

struct ReadingProgress: Codable, Identifiable {
    var comic: Comic
    var chapter: Chapter
    var page: Int
    var totalPages: Int
    var date: Date
    var id: String { comic.id }
    var fraction: Double { totalPages > 0 ? min(1, Double(page + 1) / Double(totalPages)) : 0 }
    var isFinished: Bool { totalPages > 0 && page + 1 >= totalPages }
}

struct Bookshelf: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var comics: [Comic] = []
    var createdAt: Date = Date()
}

private struct LibraryArchive: Codable {
    var version = 1
    var favorites: [Comic] = []
    var bookmarks: [ReadingBookmark] = []
    var shelves: [Bookshelf] = []
    var history: [ReadingProgress] = []
    var blockedComicIDs: Set<String> = []
    var readChapterIDs: Set<String> = []
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [Comic] = []
    @Published private(set) var bookmarks: [ReadingBookmark] = []
    @Published private(set) var shelves: [Bookshelf] = []
    @Published private(set) var history: [ReadingProgress] = []
    @Published private(set) var blockedComicIDs: Set<String> = []
    @Published var lastError: String?
    @Published private(set) var readChapterIDs: Set<String> = []
    private var canPersist = true
    private let fileURL: URL
    private let fileManager = FileManager.default

    var readComicCount: Int { Set(history.map { $0.comic.id }).count }
    var readChapterCount: Int { readChapterIDs.count }

    init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? URL.applicationSupportDirectory.appendingPathComponent("Komiic", isDirectory: true)
        fileURL = directory.appendingPathComponent("library.json")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path) {
                let archive = try JSONDecoder().decode(LibraryArchive.self, from: Data(contentsOf: fileURL))
                guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                favorites = archive.favorites
                bookmarks = archive.bookmarks
                shelves = archive.shelves
                history = archive.history.sorted { $0.date > $1.date }
                blockedComicIDs = archive.blockedComicIDs
                readChapterIDs = archive.readChapterIDs
            }
        } catch {
            // Preserve an unreadable archive so a later explicit edit cannot destroy it.
            if fileManager.fileExists(atPath: fileURL.path) {
                let backup = directory.appendingPathComponent("library-recovery-\(UUID().uuidString).json")
                do {
                    try fileManager.copyItem(at: fileURL, to: backup)
                    lastError = "本机数据读取失败，原文件已保留为 \(backup.lastPathComponent)。\(error.localizedDescription)"
                } catch {
                    canPersist = false
                    lastError = "本机数据读取失败，原文件仍在。请先备份后再清除数据。\(error.localizedDescription)"
                }
            } else {
                lastError = "无法建立本机资料库：\(error.localizedDescription)"
            }
        }
    }

    func isFavorite(_ comic: Comic) -> Bool { favorites.contains { $0.id == comic.id } }
    func isBlocked(_ comic: Comic) -> Bool { blockedComicIDs.contains(comic.id) }
    func isChapterRead(_ chapterID: String) -> Bool { readChapterIDs.contains(chapterID) }

    func toggleFavorite(_ comic: Comic) {
        if isFavorite(comic) { favorites.removeAll { $0.id == comic.id } }
        else { favorites.insert(comic, at: 0) }
        persist()
    }

    func isBookmarked(chapterID: String, page: Int) -> Bool {
        bookmarks.contains { $0.chapter.id == chapterID && $0.page == page }
    }

    func toggleBookmark(comic: Comic, chapter: Chapter, page: Int) {
        let page = max(0, page)
        if isBookmarked(chapterID: chapter.id, page: page) {
            bookmarks.removeAll { $0.chapter.id == chapter.id && $0.page == page }
        } else {
            bookmarks.insert(ReadingBookmark(comic: comic, chapter: chapter, page: page, date: Date()), at: 0)
        }
        persist()
    }

    func removeBookmark(id: String) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func recordProgress(comic: Comic, chapter: Chapter, page: Int, totalPages: Int) {
        guard totalPages > 0 else { return }
        let progress = ReadingProgress(comic: comic, chapter: chapter, page: min(max(0, page), totalPages - 1), totalPages: totalPages, date: Date())
        history.removeAll { $0.comic.id == comic.id }
        history.insert(progress, at: 0)
        readChapterIDs.insert(chapter.id)
        persist()
    }

    func progress(for comicID: String) -> ReadingProgress? { history.first { $0.comic.id == comicID } }

    @discardableResult
    func createShelf(name: String) -> Bookshelf? {
        guard let name = validShelfName(name) else { return nil }
        let shelf = Bookshelf(name: name)
        shelves.append(shelf)
        persist()
        return shelf
    }

    func renameShelf(id: UUID, name: String) {
        guard let index = shelves.firstIndex(where: { $0.id == id }), let name = validShelfName(name, excluding: id) else { return }
        shelves[index].name = name
        persist()
    }

    func deleteShelf(id: UUID) {
        shelves.removeAll { $0.id == id }
        persist()
    }

    func addToShelf(_ comic: Comic, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }), !shelves[index].comics.contains(where: { $0.id == comic.id }) else { return }
        shelves[index].comics.insert(comic, at: 0)
        persist()
    }

    func removeFromShelf(comicID: String, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        shelves[index].comics.removeAll { $0.id == comicID }
        persist()
    }

    func toggleBlocked(_ comic: Comic) {
        if blockedComicIDs.contains(comic.id) { blockedComicIDs.remove(comic.id) }
        else { blockedComicIDs.insert(comic.id) }
        persist()
    }

    func unblock(comicID: String) {
        blockedComicIDs.remove(comicID)
        persist()
    }

    func clearHistory() {
        history = []
        readChapterIDs = []
        persist()
    }

    func clearLocalData() {
        favorites = []; bookmarks = []; shelves = []; history = []
        blockedComicIDs = []; readChapterIDs = []
        canPersist = true
        persist()
    }

    private func validShelfName(_ proposed: String, excluding id: UUID? = nil) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            lastError = "书柜名称需要 1 至 80 个字。"
            return nil
        }
        guard !shelves.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            lastError = "已有同名书柜，请换一个名称。"
            return nil
        }
        return name
    }

    private func persist() {
        guard canPersist else {
            lastError = "为保留无法读取的原始资料，暂未保存更改。请备份后在设置中清除本机资料。"
            return
        }
        do {
            let archive = LibraryArchive(favorites: favorites, bookmarks: bookmarks, shelves: shelves, history: history,
                                         blockedComicIDs: blockedComicIDs, readChapterIDs: readChapterIDs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            lastError = "本机数据尚未保存：\(error.localizedDescription)"
        }
    }
}
