import Foundation
import Combine
import CryptoKit

struct ReadingBookmark: Codable, Identifiable, Sendable {
    var comic: Comic
    var chapter: Chapter
    /// A zero-based image index, shared with the reader and offline manifests.
    var page: Int
    var date: Date
    var id: String { "\(chapter.id):\(page)" }
}

struct ReadingProgress: Codable, Identifiable, Sendable {
    var comic: Comic
    var chapter: Chapter
    var page: Int
    var totalPages: Int
    var date: Date
    var id: String { comic.id }
    var fraction: Double { totalPages > 0 ? min(1, Double(page + 1) / Double(totalPages)) : 0 }
    var isFinished: Bool { totalPages > 0 && page + 1 >= totalPages }
}

struct Bookshelf: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var comics: [Comic] = []
    var createdAt: Date = Date()
    var officialID: String? = nil

    static func official(id: String, name: String) -> Bookshelf {
        let bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        let stableID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                  bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return Bookshelf(id: stableID, name: name, officialID: id)
    }
}

private struct LibraryPartition: Codable {
    var favorites: [Comic] = []
    var bookmarks: [ReadingBookmark] = []
    var shelves: [Bookshelf] = []
    var history: [ReadingProgress] = []
    var hiddenRecentComicIDs: [String: Set<String>] = [:]
    var blockedComicIDs: Set<String> = []
    var readChapterIDs: Set<String> = []
    var blockedComics: [Comic] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case favorites, bookmarks, shelves, history, hiddenRecentComicIDs, blockedComicIDs, readChapterIDs, blockedComics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try values.decodeIfPresent([Comic].self, forKey: .favorites) ?? []
        bookmarks = try values.decodeIfPresent([ReadingBookmark].self, forKey: .bookmarks) ?? []
        shelves = try values.decodeIfPresent([Bookshelf].self, forKey: .shelves) ?? []
        history = try values.decodeIfPresent([ReadingProgress].self, forKey: .history) ?? []
        hiddenRecentComicIDs = try values.decodeIfPresent([String: Set<String>].self, forKey: .hiddenRecentComicIDs) ?? [:]
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
    private var loadedOfficialModes: Set<ComicContentMode> = []
    private var refreshTasks: [ComicContentMode: Task<Void, Never>] = [:]
    private var refreshTaskIDs: [ComicContentMode: UUID] = [:]
    private var collectionEdits: [ComicContentMode: [OfficialCollectionEdit]] = [:]
    private let snapshotStore: AppSnapshotStore
    private let sessionScope: (ComicContentMode) -> String?
    private var snapshotScopes: [ComicContentMode: String] = [:]
    private var observedSessionScopes: [ComicContentMode: String] = [:]

    var readComicCount: Int { Set(history.map { $0.comic.id }).count }
    var readChapterCount: Int { readChapterIDs.count }
    var pendingOfficialChangeCount: Int { pendingOfficialChanges.count }
    var recentReading: [ReadingProgress] {
        let hidden = hiddenRecentComicIDs
        return history.filter { !hidden.contains($0.comic.id) }
    }
    private var hiddenRecentComicIDs: Set<String> {
        partition(for: activeMode).hiddenRecentComicIDs[recentReadingScope(for: activeMode)] ?? []
    }

    init(directoryURL: URL? = nil, initialMode: ComicContentMode = .general,
         officialClient: OfficialLibraryClient = .live,
         sessionScope: @escaping (ComicContentMode) -> String? = { SessionCookieStore.shared.scope(for: $0) }) {
        activeMode = initialMode
        self.officialClient = officialClient
        let directory = directoryURL ?? URL.applicationSupportDirectory.appendingPathComponent("Komiic", isDirectory: true)
        self.sessionScope = sessionScope
        snapshotStore = AppSnapshotStore(directory: directory.appendingPathComponent("OfficialSnapshots", isDirectory: true))
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
        restoreOfficialSnapshots()
    }

    private func restoreOfficialSnapshots() {
        for mode in ComicContentMode.allCases {
            let scope = sessionScope(mode)
            observedSessionScopes[mode] = scope ?? "guest"
            guard let scope,
                  let saved = snapshotStore.load(CachedOfficialLibrary.self, key: "official:\(mode.rawValue):\(scope)") else { continue }
            officialSnapshots[mode] = saved.snapshot
            officialAccountIDs[mode] = saved.accountID
            snapshotScopes[mode] = scope
            loadedOfficialModes.insert(mode)
        }
        officialAccountID = officialAccountIDs[activeMode]
        apply(partition(for: activeMode))
    }

    func synchronizeSessionScopes() {
        for mode in ComicContentMode.allCases {
            let scope = sessionScope(mode) ?? "guest"
            guard observedSessionScopes[mode] != scope else { continue }
            resetOfficialSession(mode: mode)
            observedSessionScopes[mode] = scope
        }
    }

    /// Switching replaces every visible collection together; each mode keeps its own archive.
    func flushSnapshots() { snapshotStore.flush() }

    func selectMode(_ mode: ComicContentMode) {
        guard activeMode != mode else { return }
        if refreshTasks[activeMode] != nil {
            loadedOfficialModes.remove(activeMode)
            refreshTasks[activeMode]?.cancel()
            refreshTasks[activeMode] = nil
            refreshTaskIDs[activeMode] = nil
        }
        officialRefreshID = UUID()
        syncingOfficial = false
        officialSyncError = nil
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
        let scope = recentReadingScope(for: targetMode)
        if let accountID = officialAccountIDs[targetMode] {
            var archive = partition(for: targetMode)
            if archive.hiddenRecentComicIDs[scope]?.remove(comic.id) != nil {
                setPartition(archive, for: targetMode)
            }
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
        updatePartition(mode: targetMode) { archive in
            archive.hiddenRecentComicIDs[scope]?.remove(comic.id)
            archive.history.removeAll { $0.comic.id == comic.id }
            archive.history.insert(progress, at: 0)
            archive.readChapterIDs.insert(chapter.id)
        }
    }

    func progress(for comicID: String) -> ReadingProgress? { history.first { $0.comic.id == comicID } }

    func isInRecentReading(comicID: String) -> Bool {
        !hiddenRecentComicIDs.contains(comicID) && progress(for: comicID) != nil
    }

    func removeFromRecentReading(comicID: String) {
        guard isInRecentReading(comicID: comicID) else { return }
        let scope = recentReadingScope(for: activeMode)
        updatePartition { $0.hiddenRecentComicIDs[scope, default: []].insert(comicID) }
    }

    private func recentReadingScope(for mode: ComicContentMode) -> String {
        officialAccountIDs[mode].map { "account:\($0)" } ?? "guest"
    }

    @discardableResult
    func createShelf(name: String) -> Bookshelf? {
        guard let name = validShelfName(name) else { return nil }
        let shelf = Bookshelf(name: name)
        if let accountID = officialAccountIDs[activeMode] {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .createShelf, comicID: "", shelfID: shelf.id, shelfName: name, shelf: shelf))
            return shelf
        }
        updatePartition { $0.shelves.append(shelf) }
        return shelf
    }

    func renameShelf(id: UUID, name: String) {
        guard let index = shelves.firstIndex(where: { $0.id == id }), let name = validShelfName(name, excluding: id) else { return }
        if let accountID = officialAccountIDs[activeMode] {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .renameShelf, comicID: "", shelfID: id, officialShelfID: shelves[index].officialID, shelfName: name))
            return
        }
        updatePartition { $0.shelves[index].name = name }
    }

    func deleteShelf(id: UUID) {
        if let accountID = officialAccountIDs[activeMode], let shelf = shelves.first(where: { $0.id == id }) {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .deleteShelf, comicID: "", shelfID: id, officialShelfID: shelf.officialID))
            return
        }
        updatePartition { $0.shelves.removeAll { $0.id == id } }
    }

    func addToShelf(_ comic: Comic, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }), !shelves[index].comics.contains(where: { $0.id == comic.id }) else { return }
        if let accountID = officialAccountIDs[activeMode] {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .shelfComic, comicID: comic.id, comic: comic, shelfID: shelfID,
                officialShelfID: shelves[index].officialID, adding: true))
            return
        }
        updatePartition { $0.shelves[index].comics.insert(comic, at: 0) }
    }

    func toggleShelfMembership(_ comic: Comic, shelfID: UUID) {
        guard let shelf = shelves.first(where: { $0.id == shelfID }) else { return }
        if shelf.comics.contains(where: { $0.id == comic.id }) {
            removeFromShelf(comicID: comic.id, shelfID: shelfID)
        } else {
            addToShelf(comic, shelfID: shelfID)
        }
    }

    func removeFromShelf(comicID: String, shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        if let accountID = officialAccountIDs[activeMode] {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .shelfComic, comicID: comicID, shelfID: shelfID,
                officialShelfID: shelves[index].officialID, adding: false))
            return
        }
        updatePartition { $0.shelves[index].comics.removeAll { $0.id == comicID } }
    }

    func toggleBlocked(_ comic: Comic, mode: ComicContentMode? = nil) {
        let targetMode = mode ?? activeMode
        if let accountID = officialAccountIDs[targetMode] {
            let snapshot = officialSnapshots[targetMode] ?? OfficialLibrarySnapshot()
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: targetMode,
                kind: .blocked, comicID: comic.id, comic: comic, blocked: !snapshot.blockedComicIDs.contains(comic.id)))
            return
        }
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
        if var snapshot = officialSnapshots[mode], snapshot.blockedComicIDs.contains(comic.id) {
            snapshot.blockedComics.removeAll { $0.id == comic.id }
            snapshot.blockedComics.append(comic)
            officialSnapshots[mode] = snapshot
            if activeMode == mode { apply(partition(for: mode)) }
            return
        }
        updatePartition(mode: mode) { archive in
            guard archive.blockedComicIDs.contains(comic.id) else { return }
            archive.blockedComics.removeAll { $0.id == comic.id }
            archive.blockedComics.append(comic)
        }
    }

    func unblock(comicID: String) {
        if let accountID = officialAccountIDs[activeMode] {
            editOfficialCollection(OfficialLibraryMutation(accountID: accountID, mode: activeMode,
                kind: .blocked, comicID: comicID, blocked: false))
            return
        }
        updatePartition { archive in
            archive.blockedComicIDs.remove(comicID)
            archive.blockedComics.removeAll { $0.id == comicID }
        }
    }

    func clearHistory() {
        updatePartition { archive in
            archive.history = []
            archive.hiddenRecentComicIDs["guest"] = nil
            archive.readChapterIDs = []
        }
    }

    func clearLocalData() {
        canPersist = true
        updatePartition { $0 = LibraryPartition() }
    }

    /// Signed-in favorites/history use the account-scoped official snapshot and pending edits.
    /// Logging out restores the independent local archive without copying cloud records into it.
    func refreshOfficialLibrary(force: Bool = true) async {
        synchronizeSessionScopes()
        let mode = activeMode
        if let running = refreshTasks[mode] { await running.value; return }
        guard force || !loadedOfficialModes.contains(mode) else { return }
        loadedOfficialModes.insert(mode)
        let id = UUID()
        refreshTaskIDs[mode] = id
        let task = Task { await performOfficialRefresh(mode: mode) }
        refreshTasks[mode] = task
        await task.value
        if refreshTaskIDs[mode] == id {
            refreshTasks[mode] = nil
            refreshTaskIDs[mode] = nil
        }
        if activeMode == mode, !Task.isCancelled, !loadedOfficialModes.contains(mode), refreshTasks[mode] == nil {
            await refreshOfficialLibrary(force: false)
        }
    }

    private func performOfficialRefresh(mode: ComicContentMode) async {
        let startingScope = sessionScope(mode)
        let startingSessionGeneration = SessionCookieStore.shared.generation
        let refreshID = UUID()
        officialRefreshID = refreshID
        syncingOfficial = true
        defer { if officialRefreshID == refreshID { syncingOfficial = false } }
        do {
            let accountID = try await officialClient.accountID(mode)
            try Task.checkCancellation()
            guard officialRefreshID == refreshID, activeMode == mode else { return }
            guard let accountID else {
                resetOfficialSession(mode: mode)
                loadedOfficialModes.insert(mode)
                return
            }
            if officialAccountIDs[mode] != accountID {
                officialSnapshots[mode] = OfficialLibrarySnapshot()
                favoriteEdits[mode] = [:]
                progressEdits[mode] = [:]
                collectionEdits[mode] = []
                officialAccountIDs[mode] = accountID
                officialAccountID = accountID
                apply(partition(for: mode))
            }
            try await flushPendingOfficialChanges(accountID: accountID, mode: mode)
            guard officialRefreshID == refreshID, officialAccountIDs[mode] == accountID else { return }
            let startingRevision = favoriteEditRevision
            async let loadedFavorites = loadAllOfficialFavorites(mode: mode)
            async let loadedHistory = loadAllOfficialHistory(mode: mode)
            async let extras = loadOfficialCollections(mode: mode)
            let snapshot = try await OfficialLibrarySnapshot(favorites: loadedFavorites, history: loadedHistory)
            let collections = await extras
            try Task.checkCancellation()
            guard officialRefreshID == refreshID, activeMode == mode, officialAccountIDs[mode] == accountID else { return }
            var reconciled = snapshot
            reconciled.shelves = collections.shelves ?? officialSnapshots[mode]?.shelves ?? []
            reconciled.blockedComicIDs = collections.blockedIDs ?? officialSnapshots[mode]?.blockedComicIDs ?? []
            reconciled.blockedComics = collections.blockedComics ?? officialSnapshots[mode]?.blockedComics ?? []
            // A tap made while these requests were in flight wins over the older server snapshot.
            for pending in pendingOfficialChanges where pending.accountID == accountID && pending.mode == mode {
                if pending.kind == .favorite {
                    reconciled.favorites.removeAll { $0.id == pending.comicID }
                    if pending.favorite == true, let comic = pending.comic { reconciled.favorites.insert(comic, at: 0) }
                } else if pending.kind == .progress, let progress = pending.progress {
                    reconciled.history.removeAll { $0.comic.id == progress.comic.id }
                    reconciled.history.insert(progress, at: 0)
                    reconciled.readChapterIDs.insert(progress.chapter.id)
                } else {
                    reconciled.applyCollectionChange(pending)
                }
            }
            for edit in collectionEdits[mode] ?? [] where edit.change.accountID == accountID && edit.revision > startingRevision {
                reconciled.applyCollectionChange(edit.change)
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
            guard (startingScope == nil || sessionScope(mode) == startingScope),
                  SessionCookieStore.shared.generation == startingSessionGeneration else {
                loadedOfficialModes.remove(mode)
                return
            }
            officialSnapshots[mode] = reconciled
            if let scope = sessionScope(mode) { snapshotScopes[mode] = scope }
            apply(partition(for: mode))
            officialSyncError = collections.error
            persist()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch KomiicError.authenticationRequired {
            if officialRefreshID == refreshID {
                resetOfficialSession(mode: mode)
                loadedOfficialModes.insert(mode)
            }
        } catch {
            guard officialRefreshID == refreshID else { return }
            reportOfficialError(error)
        }
    }

    func resetOfficialSession(mode: ComicContentMode? = nil) {
        for target in mode.map({ [$0] }) ?? ComicContentMode.allCases {
            if let scope = snapshotScopes.removeValue(forKey: target) {
                snapshotStore.remove(key: "official:\(target.rawValue):\(scope)")
            }
        }
        if let mode {
            refreshTasks[mode]?.cancel()
            refreshTasks[mode] = nil
            refreshTaskIDs[mode] = nil
            officialAccountIDs[mode] = nil
            officialSnapshots[mode] = nil
            favoriteEdits[mode] = nil
            progressEdits[mode] = nil
            collectionEdits[mode] = nil
            loadedOfficialModes.remove(mode)
        } else {
            refreshTasks.values.forEach { $0.cancel() }
            refreshTasks = [:]
            refreshTaskIDs = [:]
            uploadTask?.cancel()
            uploadTask = nil
            officialAccountIDs = [:]
            officialSnapshots = [:]
            favoriteEdits = [:]
            progressEdits = [:]
            collectionEdits = [:]
            loadedOfficialModes = []
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

    private func loadOfficialCollections(mode: ComicContentMode) async -> OfficialCollectionLoad {
        async let folders = officialResult { try await officialClient.shelves(mode) }
        async let blocks = officialResult { try await officialClient.blockedComics(mode) }
        let (shelfResult, blockResult) = await (folders, blocks)
        var loaded = OfficialCollectionLoad()
        var errors: [String] = []
        switch shelfResult {
        case .success(let shelves):
            loaded.shelves = shelves.map { shelf in
                var copy = shelf
                if let previous = officialSnapshots[mode]?.shelves.first(where: { $0.officialID == shelf.officialID }) {
                    copy.id = previous.id
                }
                return copy
            }
        case .failure(let error): errors.append("书柜同步未完成：\(error.localizedDescription)")
        }
        switch blockResult {
        case .success(let blocks): loaded.blockedIDs = blocks.ids; loaded.blockedComics = blocks.comics
        case .failure(let error): errors.append("屏蔽同步未完成：\(error.localizedDescription)")
        }
        loaded.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return loaded
    }

    private func editOfficialCollection(_ change: OfficialLibraryMutation) {
        var snapshot = officialSnapshots[change.mode] ?? OfficialLibrarySnapshot()
        snapshot.applyCollectionChange(change)
        officialSnapshots[change.mode] = snapshot
        favoriteEditRevision += 1
        collectionEdits[change.mode, default: []].removeAll { change.supersedes($0.change) }
        collectionEdits[change.mode, default: []].append(OfficialCollectionEdit(revision: favoriteEditRevision, change: change))
        queueOfficialChange(change)
        if change.mode == activeMode { apply(partition(for: change.mode)) }
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
        guard pendingOfficialChanges.contains(where: { $0.accountID == accountID && $0.mode == mode }) else { return }
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
        guard pendingOfficialChanges.contains(where: { $0.accountID == accountID && $0.mode == mode }) else { return }
        // One identity check covers this serialized batch; never cache identity across batches.
        guard officialAccountIDs[mode] == accountID,
              try await officialClient.accountID(mode) == accountID else {
            resetOfficialSession(mode: mode)
            return
        }
        while let change = pendingOfficialChanges.first(where: { $0.accountID == accountID && $0.mode == mode }) {
            try Task.checkCancellation()
            guard officialAccountIDs[mode] == accountID else { return }
            switch change.kind {
            case .favorite:
                guard let favorite = change.favorite else { throw KomiicError.invalidResponse }
                try await officialClient.setFavorite(change.mode, change.comicID, favorite)
            case .progress:
                guard let chapterID = change.chapterID, let page = change.page else { throw KomiicError.invalidResponse }
                try await officialClient.recordProgress(change.mode, change.comicID, chapterID, page)
            case .blocked:
                guard let blocked = change.blocked else { throw KomiicError.invalidResponse }
                try await officialClient.setBlocked(change.mode, change.comicID, blocked)
            case .createShelf:
                guard let name = change.shelfName, let localID = change.shelfID else { throw KomiicError.invalidResponse }
                // Reconcile a prior response lost to a disconnect before creating another folder.
                let existing = try await officialClient.shelves(mode)
                let created: Bookshelf
                if let previous = existing.first(where: { $0.name == name }) { created = previous }
                else { created = try await officialClient.createShelf(mode, name) }
                guard officialAccountIDs[mode] == accountID, let remoteID = created.officialID else { return }
                if let index = officialSnapshots[mode]?.shelves.firstIndex(where: { $0.id == localID }) {
                    officialSnapshots[mode]?.shelves[index].officialID = remoteID
                }
                for index in pendingOfficialChanges.indices where pendingOfficialChanges[index].accountID == accountID
                    && pendingOfficialChanges[index].mode == mode && pendingOfficialChanges[index].shelfID == localID {
                    pendingOfficialChanges[index].officialShelfID = remoteID
                    pendingOfficialChanges[index].shelf?.officialID = remoteID
                }
                for index in (collectionEdits[mode] ?? []).indices where collectionEdits[mode]?[index].change.shelfID == localID {
                    collectionEdits[mode]?[index].change.officialShelfID = remoteID
                    collectionEdits[mode]?[index].change.shelf?.officialID = remoteID
                }
            case .renameShelf:
                guard let remoteID = officialShelfID(for: change), let name = change.shelfName else { throw KomiicError.invalidResponse }
                try await officialClient.renameShelf(mode, remoteID, name)
            case .deleteShelf:
                guard let remoteID = officialShelfID(for: change) else { throw KomiicError.invalidResponse }
                try await officialClient.deleteShelf(mode, remoteID)
            case .shelfComic:
                guard let remoteID = officialShelfID(for: change), let adding = change.adding else { throw KomiicError.invalidResponse }
                try await officialClient.setShelfComic(mode, remoteID, change.comicID, adding)
            }
            pendingOfficialChanges.removeAll { $0.id == change.id }
            persist()
        }
    }

    private func officialShelfID(for change: OfficialLibraryMutation) -> String? {
        change.officialShelfID ?? officialSnapshots[change.mode]?.shelves.first { $0.id == change.shelfID }?.officialID
    }

    private func reportOfficialError(_ error: Error) {
        let message = "官网资料同步未完成，下拉刷新会重试。\(error.localizedDescription)"
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
            shelves = remote.shelves
            blockedComicIDs = remote.blockedComicIDs
            blockedComics = remote.blockedComics
            if let accountID = officialAccountIDs[activeMode] {
                for pending in pendingOfficialChanges where pending.accountID == accountID && pending.mode == activeMode {
                    if pending.kind == .favorite {
                        favorites.removeAll { $0.id == pending.comicID }
                        if pending.favorite == true, let comic = pending.comic { favorites.insert(comic, at: 0) }
                    } else if pending.kind == .progress, let progress = pending.progress {
                        history.removeAll { $0.comic.id == progress.comic.id }
                        history.insert(progress, at: 0)
                        readChapterIDs.insert(progress.chapter.id)
                    }
                }
                var collections = remote
                for pending in pendingOfficialChanges where pending.accountID == accountID && pending.mode == activeMode {
                    collections.applyCollectionChange(pending)
                }
                shelves = collections.shelves
                blockedComicIDs = collections.blockedComicIDs
                blockedComics = collections.blockedComics
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
        for (mode, snapshot) in officialSnapshots {
            guard let accountID = officialAccountIDs[mode], let scope = snapshotScopes[mode],
                  sessionScope(mode) == scope else { continue }
            snapshotStore.save(CachedOfficialLibrary(accountID: accountID, snapshot: snapshot), key: "official:\(mode.rawValue):\(scope)")
        }
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
