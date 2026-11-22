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

private struct LibraryPartition: Codable {
    var favorites: [Comic] = []
    var bookmarks: [ReadingBookmark] = []
    var shelves: [Bookshelf] = []
    var history: [ReadingProgress] = []
    var blockedComicIDs: Set<String> = []
    var readChapterIDs: Set<String> = []
    var blockedComics: [Comic] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case favorites, bookmarks, shelves, history, blockedComicIDs, readChapterIDs, blockedComics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try values.decodeIfPresent([Comic].self, forKey: .favorites) ?? []
        bookmarks = try values.decodeIfPresent([ReadingBookmark].self, forKey: .bookmarks) ?? []
        shelves = try values.decodeIfPresent([Bookshelf].self, forKey: .shelves) ?? []
        history = try values.decodeIfPresent([ReadingProgress].self, forKey: .history) ?? []
        blockedComicIDs = try values.decodeIfPresent(Set<String>.self, forKey: .blockedComicIDs) ?? []
        readChapterIDs = try values.decodeIfPresent(Set<String>.self, forKey: .readChapterIDs) ?? []
        blockedComics = try values.decodeIfPresent([Comic].self, forKey: .blockedComics) ?? []
        // Old archives only stored blocked IDs. Reuse any metadata already on this device.
        let knownComics = favorites + history.map(\.comic) + bookmarks.map(\.comic) + shelves.flatMap(\.comics)
        var cachedIDs = Set(blockedComics.map(\.id))
        blockedComics += knownComics.filter { blockedComicIDs.contains($0.id) && cachedIDs.insert($0.id).inserted }
        blockedComics.removeAll { !blockedComicIDs.contains($0.id) }
    }
}

private struct LibraryArchive: Codable {
    var version = 2
    var general: LibraryPartition
    var adult: LibraryPartition
    var pendingOfficialChanges: [OfficialLibraryMutation]

    init(general: LibraryPartition, adult: LibraryPartition, pendingOfficialChanges: [OfficialLibraryMutation]) {
        self.general = general
        self.adult = adult
        self.pendingOfficialChanges = pendingOfficialChanges
    }

    enum CodingKeys: String, CodingKey { case version, general, adult, pendingOfficialChanges }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        switch version {
        case 1:
            // v3.0 had a single library. It belongs to general mode during migration.
            general = try LibraryPartition(from: decoder)
            adult = LibraryPartition()
        case 2:
            general = try values.decode(LibraryPartition.self, forKey: .general)
            adult = try values.decode(LibraryPartition.self, forKey: .adult)
        default:
            throw CocoaError(.coderReadCorrupt)
        }
        pendingOfficialChanges = try values.decodeIfPresent([OfficialLibraryMutation].self, forKey: .pendingOfficialChanges) ?? []
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var activeMode: ComicContentMode = .general
    @Published private(set) var favorites: [Comic] = []
    @Published private(set) var bookmarks: [ReadingBookmark] = []
    @Published private(set) var shelves: [Bookshelf] = []
    @Published private(set) var history: [ReadingProgress] = []
    @Published private(set) var blockedComicIDs: Set<String> = []
    @Published private(set) var blockedComics: [Comic] = []
    @Published var lastError: String?
    @Published private(set) var readChapterIDs: Set<String> = []
    @Published private(set) var syncingOfficial = false
    @Published private(set) var officialSyncError: String?
    @Published private(set) var officialAccountID: String?
    private var canPersist = true
    private var generalArchive = LibraryPartition()
    private var adultArchive = LibraryPartition()
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let officialClient: OfficialLibraryClient
    private var officialSnapshots: [ComicContentMode: OfficialLibrarySnapshot] = [:]
    private var officialAccountIDs: [ComicContentMode: String] = [:]
    private var favoriteEditRevision = 0
    private var favoriteEdits: [ComicContentMode: [String: OfficialFavoriteEdit]] = [:]
    private var progressEdits: [ComicContentMode: [String: OfficialProgressEdit]] = [:]
    private var pendingOfficialChanges: [OfficialLibraryMutation] = []
    private var officialRefreshID = UUID()
    private var uploadTask: Task<Void, Never>?
    private var flushingChanges = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    var readComicCount: Int { Set(history.map { $0.comic.id }).count }
    var readChapterCount: Int { readChapterIDs.count }
    var pendingOfficialChangeCount: Int { pendingOfficialChanges.count }

    init(directoryURL: URL? = nil, initialMode: ComicContentMode = .general,
         officialClient: OfficialLibraryClient = .live) {
        activeMode = initialMode
        self.officialClient = officialClient
        let directory = directoryURL ?? URL.applicationSupportDirectory.appendingPathComponent("Komiic", isDirectory: true)
        fileURL = directory.appendingPathComponent("library.json")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path) {
                let archive = try JSONDecoder().decode(LibraryArchive.self, from: Data(contentsOf: fileURL))
                generalArchive = archive.general
                adultArchive = archive.adult
                pendingOfficialChanges = archive.pendingOfficialChanges
                apply(partition(for: initialMode))
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

    /// Switching replaces every visible collection together; each mode keeps its own archive.
    func selectMode(_ mode: ComicContentMode) {
        guard activeMode != mode else { return }
        officialRefreshID = UUID()
        syncingOfficial = false
        activeMode = mode
        officialAccountID = officialAccountIDs[mode]
        apply(partition(for: mode))
    }

    func isFavorite(_ comic: Comic) -> Bool { favorites.contains { $0.id == comic.id } }
    func isBlocked(_ comic: Comic) -> Bool { blockedComicIDs.contains(comic.id) }
    func isChapterRead(_ chapterID: String) -> Bool { readChapterIDs.contains(chapterID) }

    func toggleFavorite(_ comic: Comic, mode: ComicContentMode? = nil) {
        let targetMode = mode ?? activeMode
        if let accountID = officialAccountIDs[targetMode] {
            var snapshot = officialSnapshots[targetMode] ?? OfficialLibrarySnapshot()
            let pendingFavorite = pendingOfficialChanges.last {
                $0.accountID == accountID && $0.mode == targetMode && $0.kind == .favorite && $0.comicID == comic.id
            }?.favorite
            let wasFavorite = pendingFavorite ?? snapshot.favorites.contains(where: { $0.id == comic.id })
            snapshot.favorites.removeAll { $0.id == comic.id }
            if !wasFavorite { snapshot.favorites.insert(comic, at: 0) }
            officialSnapshots[targetMode] = snapshot
            favoriteEditRevision += 1
            favoriteEdits[targetMode, default: [:]][comic.id] = OfficialFavoriteEdit(revision: favoriteEditRevision,
                accountID: accountID, comic: comic, favorite: !wasFavorite)
            queueOfficialChange(OfficialLibraryMutation(accountID: accountID, mode: targetMode,
                kind: .favorite, comicID: comic.id, favorite: !wasFavorite, comic: comic))
            if targetMode == activeMode { apply(partition(for: targetMode)) }
            return
        }
        let local = partition(for: targetMode)
        let wasFavorite = local.favorites.contains(where: { $0.id == comic.id })
        updatePartition(mode: targetMode) { archive in
            archive.favorites.removeAll { $0.id == comic.id }
            if !wasFavorite { archive.favorites.insert(comic, at: 0) }
        }
    }

    func isBookmarked(chapterID: String, page: Int) -> Bool {
        bookmarks.contains { $0.chapter.id == chapterID && $0.page == page }
    }

    func toggleBookmark(comic: Comic, chapter: Chapter, page: Int, mode: ComicContentMode? = nil) {
        let page = max(0, page)
        updatePartition(mode: mode) { archive in
            if archive.bookmarks.contains(where: { $0.chapter.id == chapter.id && $0.page == page }) {
                archive.bookmarks.removeAll { $0.chapter.id == chapter.id && $0.page == page }
            } else {
                archive.bookmarks.insert(ReadingBookmark(comic: comic, chapter: chapter, page: page, date: Date()), at: 0)
            }
        }
    }

    func removeBookmark(id: String) {
        updatePartition { $0.bookmarks.removeAll { $0.id == id } }
    }

    func recordProgress(comic: Comic, chapter: Chapter, page: Int, totalPages: Int, mode: ComicContentMode? = nil) {
        guard totalPages > 0 else { return }
        let progress = ReadingProgress(comic: comic, chapter: chapter, page: min(max(0, page), totalPages - 1), totalPages: totalPages, date: Date())
        let targetMode = mode ?? activeMode
        if let accountID = officialAccountIDs[targetMode] {
            var snapshot = officialSnapshots[targetMode] ?? OfficialLibrarySnapshot()
            snapshot.history.removeAll { $0.comic.id == comic.id }
            snapshot.history.insert(progress, at: 0)
            snapshot.readChapterIDs.insert(chapter.id)
            officialSnapshots[targetMode] = snapshot
            favoriteEditRevision += 1
            progressEdits[targetMode, default: [:]][chapter.id] = OfficialProgressEdit(revision: favoriteEditRevision,
                accountID: accountID, progress: progress)
            queueOfficialChange(OfficialLibraryMutation(accountID: accountID, mode: targetMode,
                kind: .progress, comicID: comic.id, chapterID: chapter.id, page: progress.page, progress: progress))
            if targetMode == activeMode { apply(partition(for: targetMode)) }
            return
        }
        updatePartition(mode: mode) { archive in
            archive.history.removeAll { $0.comic.id == comic.id }
            archive.history.insert(progress, at: 0)
            archive.readChapterIDs.insert(chapter.id)
        }
    }

    func progress(for comicID: String) -> ReadingProgress? { history.first { $0.comic.id == comicID } }

    @discardableResult
    func createShelf(name: String) -> Bookshelf? {
        guard let name = validShelfName(name) else { return nil }
        let shelf = Bookshelf(name: name)
        updatePartition { $0.shelves.append(shelf) }
        return shelf
    }

    func renameShelf(id: UUID, name: String) {
        guard let index = shelves.firstIndex(where: { $0.id == id }), let name = validShelfName(name, excluding: id) else { return }
        updatePartition { $0.shelves[index].name = name }
    }

    func deleteShelf(id: UUID) {
        updatePartition { $0.shelves.removeAll { $0.id == id } }
    }

    func addToShelf(_ comic: Comic, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }), !shelves[index].comics.contains(where: { $0.id == comic.id }) else { return }
        updatePartition { $0.shelves[index].comics.insert(comic, at: 0) }
    }

    func removeFromShelf(comicID: String, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        updatePartition { $0.shelves[index].comics.removeAll { $0.id == comicID } }
    }

    func toggleBlocked(_ comic: Comic, mode: ComicContentMode? = nil) {
        updatePartition(mode: mode) { archive in
            if archive.blockedComicIDs.contains(comic.id) {
                archive.blockedComicIDs.remove(comic.id)
                archive.blockedComics.removeAll { $0.id == comic.id }
            } else {
                archive.blockedComicIDs.insert(comic.id)
                archive.blockedComics.insert(comic, at: 0)
            }
        }
    }

    /// An old blocked ID may be resolved over the network after the user switches modes.
    func cacheBlockedComic(_ comic: Comic, mode: ComicContentMode) {
        updatePartition(mode: mode) { archive in
            guard archive.blockedComicIDs.contains(comic.id) else { return }
            archive.blockedComics.removeAll { $0.id == comic.id }
            archive.blockedComics.append(comic)
        }
    }

    func unblock(comicID: String) {
        updatePartition { archive in
            archive.blockedComicIDs.remove(comicID)
            archive.blockedComics.removeAll { $0.id == comicID }
        }
    }

    func clearHistory() {
        updatePartition { archive in
            archive.history = []
            archive.readChapterIDs = []
        }
    }

    func clearLocalData() {
        canPersist = true
        updatePartition { $0 = LibraryPartition() }
    }

    /// Signed-in favorites/history use the account-scoped official snapshot and pending edits.
    /// Logging out restores the independent local archive without copying cloud records into it.
    func refreshOfficialLibrary() async {
        let mode = activeMode
        let refreshID = UUID()
        officialRefreshID = refreshID
        syncingOfficial = true
        defer { if officialRefreshID == refreshID { syncingOfficial = false } }
        do {
            let accountID = try await officialClient.accountID(mode)
            try Task.checkCancellation()
            guard officialRefreshID == refreshID, activeMode == mode else { return }
            guard let accountID else { resetOfficialSession(mode: mode); return }
            if officialAccountIDs[mode] != accountID {
                officialSnapshots[mode] = OfficialLibrarySnapshot()
                favoriteEdits[mode] = [:]
                progressEdits[mode] = [:]
                officialAccountIDs[mode] = accountID
                officialAccountID = accountID
                apply(partition(for: mode))
            }
            try await flushPendingOfficialChanges(accountID: accountID, mode: mode)
            guard officialRefreshID == refreshID, officialAccountIDs[mode] == accountID else { return }
            let startingRevision = favoriteEditRevision
            async let loadedFavorites = loadAllOfficialFavorites(mode: mode)
            async let loadedHistory = loadAllOfficialHistory(mode: mode)
            let snapshot = try await OfficialLibrarySnapshot(favorites: loadedFavorites, history: loadedHistory)
            try Task.checkCancellation()
            guard officialRefreshID == refreshID, activeMode == mode, officialAccountIDs[mode] == accountID else { return }
            var reconciled = snapshot
            // A tap made while these requests were in flight wins over the older server snapshot.
            for pending in pendingOfficialChanges where pending.accountID == accountID && pending.mode == mode {
                if pending.kind == .favorite {
                    reconciled.favorites.removeAll { $0.id == pending.comicID }
                    if pending.favorite == true, let comic = pending.comic { reconciled.favorites.insert(comic, at: 0) }
                } else if let progress = pending.progress {
                    reconciled.history.removeAll { $0.comic.id == progress.comic.id }
                    reconciled.history.insert(progress, at: 0)
                    reconciled.readChapterIDs.insert(progress.chapter.id)
                }
            }
            for edit in (favoriteEdits[mode] ?? [:]).values where edit.accountID == accountID && edit.revision > startingRevision {
                reconciled.favorites.removeAll { $0.id == edit.comic.id }
                if edit.favorite { reconciled.favorites.insert(edit.comic, at: 0) }
            }
            for edit in (progressEdits[mode] ?? [:]).values.sorted(by: { $0.revision < $1.revision })
                where edit.accountID == accountID && edit.revision > startingRevision {
                reconciled.history.removeAll { $0.comic.id == edit.progress.comic.id }
                reconciled.history.insert(edit.progress, at: 0)
                reconciled.readChapterIDs.insert(edit.progress.chapter.id)
            }
            officialSnapshots[mode] = reconciled
            apply(partition(for: mode))
            officialSyncError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch KomiicError.authenticationRequired {
            if officialRefreshID == refreshID { resetOfficialSession(mode: mode) }
        } catch {
            guard officialRefreshID == refreshID else { return }
            reportOfficialError(error)
        }
    }

    func resetOfficialSession(mode: ComicContentMode? = nil) {
        if let mode {
            officialAccountIDs[mode] = nil
            officialSnapshots[mode] = nil
            favoriteEdits[mode] = nil
            progressEdits[mode] = nil
        } else {
            uploadTask?.cancel()
            uploadTask = nil
            officialAccountIDs = [:]
            officialSnapshots = [:]
            favoriteEdits = [:]
            progressEdits = [:]
        }
        if mode == nil || mode == activeMode {
            officialRefreshID = UUID()
            officialAccountID = officialAccountIDs[activeMode]
            officialSyncError = nil
            syncingOfficial = false
            apply(partition(for: activeMode))
        }
    }

    /// Explicit retries are also run on foreground, pull-to-refresh and catalog changes.
    func retryPendingOfficialChanges() async {
        do {
            for mode in ComicContentMode.allCases {
                guard let accountID = officialAccountIDs[mode] else { continue }
                try await flushPendingOfficialChanges(accountID: accountID, mode: mode)
            }
            officialSyncError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch { reportOfficialError(error) }
    }

    private func loadAllOfficialFavorites(mode: ComicContentMode) async throws -> [Comic] {
        var results: [Comic] = []
        var ids: Set<String> = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await officialClient.favorites(mode, offset)
            let additions = page.filter { ids.insert($0.id).inserted }
            guard !additions.isEmpty else { return results }
            results += additions
            // Advance by the raw server page size, since deleted comics may be omitted.
            offset += KomiicAPI.pageSize
        }
    }

    private func loadAllOfficialHistory(mode: ComicContentMode) async throws -> [OfficialReadingHistory] {
        var results: [OfficialReadingHistory] = []
        var ids: Set<String> = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await officialClient.history(mode, offset)
            let additions = page.filter { ids.insert($0.comic.id).inserted }
            guard !additions.isEmpty else { return results }
            results += additions
            offset += KomiicAPI.pageSize
        }
    }

    private func queueOfficialChange(_ change: OfficialLibraryMutation) {
        pendingOfficialChanges.removeAll { change.supersedes($0) }
        pendingOfficialChanges.append(change)
        persist()
        guard uploadTask == nil else { return }
        uploadTask = Task {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            await retryPendingOfficialChanges()
            uploadTask = nil
        }
    }

    private func flushPendingOfficialChanges(accountID: String, mode: ComicContentMode) async throws {
        while flushingChanges {
            await withCheckedContinuation { mutationWaiters.append($0) }
            try Task.checkCancellation()
        }
        flushingChanges = true
        defer {
            flushingChanges = false
            let waiters = mutationWaiters
            mutationWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        while let change = pendingOfficialChanges.first(where: { $0.accountID == accountID && $0.mode == mode }) {
            try Task.checkCancellation()
            guard officialAccountIDs[mode] == accountID else { return }
            // Verify against the request's own origin before replaying a saved mutation.
            guard try await officialClient.accountID(change.mode) == accountID else {
                resetOfficialSession(mode: mode)
                return
            }
            switch change.kind {
            case .favorite:
                guard let favorite = change.favorite else { throw KomiicError.invalidResponse }
                try await officialClient.setFavorite(change.mode, change.comicID, favorite)
            case .progress:
                guard let chapterID = change.chapterID, let page = change.page else { throw KomiicError.invalidResponse }
                try await officialClient.recordProgress(change.mode, change.comicID, chapterID, page)
            }
            pendingOfficialChanges.removeAll { $0.id == change.id }
            persist()
        }
    }

    private func reportOfficialError(_ error: Error) {
        let message = "官网喜爱与阅读记录同步未完成，已保留本机资料；下次刷新会重试。\(error.localizedDescription)"
        if officialSyncError != message { lastError = message }
        officialSyncError = message
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

    private func partition(for mode: ComicContentMode) -> LibraryPartition {
        mode == .adult ? adultArchive : generalArchive
    }

    private func setPartition(_ archive: LibraryPartition, for mode: ComicContentMode) {
        if mode == .adult { adultArchive = archive } else { generalArchive = archive }
    }

    private func apply(_ archive: LibraryPartition) {
        favorites = archive.favorites
        bookmarks = archive.bookmarks
        shelves = archive.shelves
        history = archive.history
        blockedComicIDs = archive.blockedComicIDs
        blockedComics = archive.blockedComics
        readChapterIDs = archive.readChapterIDs
        if let remote = officialSnapshots[activeMode] {
            favorites = remote.favorites
            history = remote.history
            readChapterIDs = remote.readChapterIDs
            if let accountID = officialAccountIDs[activeMode] {
                for pending in pendingOfficialChanges where pending.accountID == accountID && pending.mode == activeMode {
                    if pending.kind == .favorite {
                        favorites.removeAll { $0.id == pending.comicID }
                        if pending.favorite == true, let comic = pending.comic { favorites.insert(comic, at: 0) }
                    } else if let progress = pending.progress {
                        history.removeAll { $0.comic.id == progress.comic.id }
                        history.insert(progress, at: 0)
                        readChapterIDs.insert(progress.chapter.id)
                    }
                }
            }
        }
        history.sort { $0.date > $1.date }
    }

    private func updatePartition(mode: ComicContentMode? = nil, _ mutation: (inout LibraryPartition) -> Void) {
        let targetMode = mode ?? activeMode
        var archive = partition(for: targetMode)
        mutation(&archive)
        setPartition(archive, for: targetMode)
        if targetMode == activeMode { apply(archive) }
        persist()
    }

    private func persist() {
        guard canPersist else {
            lastError = "为保留无法读取的原始资料，暂未保存更改。请备份后在设置中清除本机资料。"
            return
        }
        do {
            let archive = LibraryArchive(general: generalArchive, adult: adultArchive,
                pendingOfficialChanges: pendingOfficialChanges)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            lastError = "本机数据尚未保存：\(error.localizedDescription)"
        }
    }
}
