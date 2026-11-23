import Foundation
import Combine
import CryptoKit
import UIKit

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, completed, failed
    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .downloading: return "正在下载"
        case .paused: return "已暂停"
        case .completed: return "已下载"
        case .failed: return "下载失败"
        }
    }
}

struct OfflineChapter: Codable, Identifiable {
    var comic: Comic
    var chapter: Chapter
    var pages: [ComicPage]
    var downloadedPageIDs: Set<String> = []
    var status: DownloadStatus = .queued
    var errorMessage: String?
    var byteCount: Int64 = 0
    var createdAt = Date()
    var sourceURL: URL
    var id: String { chapter.id }
    var chapterID: String { chapter.id }
    var progress: Double { pages.isEmpty ? 0 : Double(downloadedPageIDs.count) / Double(pages.count) }
}

enum ImageStorageError: LocalizedError {
    case invalidResponse, unavailable(Int), invalidImage, missingOfflinePage
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "图片服务器返回了无效响应。"
        case .unavailable(let status):
            if status == 401 || status == 403 { return "图片访问被拒绝，请登录 Komiic，并检查账号的图片额度。" }
            if status == 429 { return "图片请求过于频繁或额度已用完，请稍后再试。" }
            return "图片下载失败（HTTP \(status)）。"
        case .invalidImage: return "服务器未返回可读取的图片，请在官网检查登录状态和图片额度。"
        case .missingOfflinePage: return "这一页尚未下载，连接网络后可重试。"
        }
    }
}

/// Permanent downloads live in Documents; disposable online pages live in Caches.
/// A manifest in every chapter folder permits recovery without a central index.
@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var items: [OfflineChapter] = []
    @Published private(set) var activeID: String?
    @Published private(set) var cacheBytes: Int64 = 0
    @Published var lastError: String?
    let directoryURL: URL
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let session: URLSession?
    private let pageCache: PageImageDiskCache
    private var cacheRevision: UInt64 = 0
    private let imageLoader: (@Sendable (ComicPage, URL) async throws -> Data)?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var currentDownload: Task<Void, Error>?
    private struct ImageRequestKey: Hashable {
        let chapterID: String
        let page: ComicPage
        let baseURL: URL
    }
    private struct PendingImageRequest {
        let task: Task<Data, Error>
        var readers: Set<UUID>
    }
    private var imageRequests: [ImageRequestKey: PendingImageRequest] = [:]
    private var cacheGenerations: [String: UUID] = [:]
    private var readingPositions: [String: Int] = [:]

    var storageBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var availableBytes: Int64 {
        (try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    init(directoryURL: URL? = nil, cacheDirectory: URL? = nil, session: URLSession? = nil,
         imageLoader: (@Sendable (ComicPage, URL) async throws -> Data)? = nil) {
        self.directoryURL = directoryURL ?? URL.documentsDirectory.appendingPathComponent("KomiicOffline", isDirectory: true)
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory.appendingPathComponent("KomiicPages", isDirectory: true)
        self.pageCache = PageImageDiskCache(directory: self.cacheDirectory)
        self.imageLoader = imageLoader
        // Use KomiicAPI's shared connection pool for image tickets and all other API calls.
        self.session = session
        do {
            try fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
            var excludedURL = self.directoryURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try excludedURL.setResourceValues(resourceValues)
        } catch { lastError = "无法建立图片储存目录：\(error.localizedDescription)" }
        restore()
        applyCachePolicy(CachePolicy(rawValue: UserDefaults.standard.string(forKey: "komiic.cachePolicy") ?? "") ?? .oneDay)
    }

    /// Enqueues chapters; a single worker fetches one image at a time.
    /// Calling this again resumes an incomplete chapter and retries failed pages.
    func download(comic: Comic, chapter: Chapter, pages: [ComicPage], baseURL: URL) async {
        guard !pages.isEmpty else { lastError = "本章没有可下载的页面。"; return }
        if let index = items.firstIndex(where: { $0.id == chapter.id }) {
            if items[index].status == .completed || items[index].status == .downloading || queue.contains(chapter.id) { return }
            items[index].pages = pages
            items[index].comic = comic
            items[index].chapter = chapter
            items[index].sourceURL = baseURL
            items[index].downloadedPageIDs.formIntersection(Set(pages.map(\.id)))
            items[index].status = .queued
            items[index].errorMessage = nil
        } else {
            items.insert(OfflineChapter(comic: comic, chapter: chapter, pages: pages, sourceURL: baseURL), at: 0)
        }
        do { try persist(id: chapter.id) }
        catch { fail(id: chapter.id, error: error); return }
        queue.append(chapter.id)
        startWorker()
    }

    func resume(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Task { await download(comic: item.comic, chapter: item.chapter, pages: item.pages, baseURL: item.sourceURL) }
    }

    func cancel(id: String) {
        queue.removeAll { $0 == id }
        if activeID == id { currentDownload?.cancel() }
        if let index = items.firstIndex(where: { $0.id == id }), items[index].status != .completed {
            items[index].status = .paused
            tryPersist(id: id)
        }
    }

    func remove(id: String) {
        cancel(id: id)
        do {
            let url = chapterDirectory(id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            items.removeAll { $0.id == id }
        } catch { lastError = "无法删除下载章节：\(error.localizedDescription)" }
    }

    func removeAll() {
        let ids = items.map(\.id)
        for id in ids { remove(id: id) }
    }

    func localImageURL(chapterID: String, pageID: String) -> URL? {
        let url = pageFile(in: chapterDirectory(chapterID), pageID: pageID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(chapterID: String) -> Bool {
        items.contains { $0.id == chapterID && $0.status == .completed }
    }

    /// Recovers copied downloads and validates that each claimed page still exists.
    func restore() {
        guard activeID == nil else { lastError = "请先暂停当前下载，再扫描离线资料。"; return }
        do {
            let folders = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var restored: [OfflineChapter] = []
            var unreadable = 0
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let manifestURL = folder.appendingPathComponent("chapter.json")
                guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                do {
                    var item = try JSONDecoder().decode(OfflineChapter.self, from: Data(contentsOf: manifestURL))
                    // Only folders generated from our opaque ID hash may be read or mutated.
                    guard folder.lastPathComponent == Self.fileName(item.id) else { unreadable += 1; continue }
                    item.downloadedPageIDs = []
                    item.byteCount = 0
                    for page in item.pages {
                        let url = pageFile(in: folder, pageID: page.id)
                        let byteCount = Self.byteSize(url)
                        guard byteCount > 0, autoreleasepool(invoking: { UIImage(contentsOfFile: url.path) != nil }) else { continue }
                        item.downloadedPageIDs.insert(page.id)
                        item.byteCount += byteCount
                    }
                    item.status = !item.pages.isEmpty && item.downloadedPageIDs.count == item.pages.count ? .completed : .paused
                    item.errorMessage = nil
                    restored.append(item)
                } catch { unreadable += 1 }
            }
            items = restored.sorted { $0.createdAt > $1.createdAt }
            if unreadable > 0 { lastError = "有 \(unreadable) 个章节的资料无法读取，原文件已保留。" }
        } catch { lastError = "无法扫描离线资料：\(error.localizedDescription)" }
    }

    /// Reads a permanent page first, then temporary cache, then the official server.
    /// Offline reading never requires the network when all chapter pages are present.
    func imageData(page: ComicPage, chapterID: String, baseURL: URL, cachePolicy: CachePolicy, allowNetwork: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        let generation = cacheGenerations[chapterID] ?? UUID()
        cacheGenerations[chapterID] = generation
        if let url = localImageURL(chapterID: chapterID, pageID: page.id), let data = await ImageDecoding.read(from: url) {
            try Task.checkCancellation()
            return data
        }
        let cachedURL = pageFile(in: cacheChapterDirectory(chapterID), pageID: page.id)
        if let data = await pageCache.read(from: cachedURL, maximumAge: cachePolicy == .oneDay ? 86_400 : nil) {
            try Task.checkCancellation()
            return data
        }
        try Task.checkCancellation()
        guard cacheGenerations[chapterID] == generation else { throw CancellationError() }
        guard allowNetwork else { throw ImageStorageError.missingOfflinePage }
        let key = ImageRequestKey(chapterID: chapterID, page: page, baseURL: baseURL)
        let readerID = UUID()
        let task: Task<Data, Error>
        if var pending = imageRequests[key] {
            pending.readers.insert(readerID)
            imageRequests[key] = pending
            task = pending.task
        } else {
            pageCache.register(chapter: Self.fileName(chapterID), generation: generation)
            task = Task {
                // Another reader may have finished while the initial disk read was pending.
                if let cached = await pageCache.read(from: cachedURL, maximumAge: cachePolicy == .oneDay ? 86_400 : nil) {
                    try Task.checkCancellation()
                    return cached
                }
                try Task.checkCancellation()
                let data = try await fetchImage(page: page, baseURL: baseURL)
                try Task.checkCancellation()
                // A page already in flight must not recreate a cleared chapter cache.
                if cacheGenerations[chapterID] == generation {
                    do {
                        let snapshot = try await pageCache.write(data, to: cachedURL,
                            chapter: Self.fileName(chapterID), generation: generation)
                        updateCacheSize(snapshot)
                    } catch { lastError = "阅读缓存尚未保存：\(error.localizedDescription)" }
                }
                return data
            }
            imageRequests[key] = PendingImageRequest(task: task, readers: [readerID])
        }
        return try await withTaskCancellationHandler {
            defer { releaseImageRequest(key, readerID: readerID) }
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            Task { @MainActor in self.releaseImageRequest(key, readerID: readerID) }
        }
    }

    /// Fetch the entire chapter independently of which views SwiftUI has created.
    /// Only compressed files are cached; visible page views decode their own images.
    func prefetchChapter(pages: [ComicPage], chapterID: String, baseURL: URL,
                         startingAt pageIndex: Int = 0, cachePolicy: CachePolicy) async {
        guard !pages.isEmpty, !Task.isCancelled else { return }
        let generation = cacheGenerations[chapterID] ?? UUID()
        cacheGenerations[chapterID] = generation
        let start = min(max(0, pageIndex), pages.count - 1)
        readingPositions[chapterID] = start
        await withTaskGroup(of: Bool.self) { group in
            var remaining = Set(pages.indices)
            @MainActor func nextPage() -> ComicPage? {
                let position = min(max(0, readingPositions[chapterID] ?? start), pages.count - 1)
                guard let index = remaining.min(by: {
                    ($0 - position + pages.count) % pages.count < ($1 - position + pages.count) % pages.count
                }) else { return nil }
                remaining.remove(index)
                return pages[index]
            }
            // Leave connection capacity for the currently visible page and API calls.
            for _ in 0..<3 {
                guard !Task.isCancelled, let page = nextPage() else { break }
                group.addTask { @MainActor in
                    guard self.cacheGenerations[chapterID] == generation else { return true }
                    return await self.prefetchPage(page, chapterID: chapterID, baseURL: baseURL, cachePolicy: cachePolicy)
                }
            }
            for await shouldStop in group {
                guard !shouldStop, !Task.isCancelled, cacheGenerations[chapterID] == generation else { group.cancelAll(); break }
                guard let page = nextPage() else { continue }
                group.addTask { @MainActor in
                    guard self.cacheGenerations[chapterID] == generation else { return true }
                    return await self.prefetchPage(page, chapterID: chapterID, baseURL: baseURL, cachePolicy: cachePolicy)
                }
            }
        }
    }

    func prioritizeReading(chapterID: String, pageIndex: Int) {
        readingPositions[chapterID] = max(0, pageIndex)
    }

    /// A damaged page can be skipped; account limits stop background traffic.
    private func prefetchPage(_ page: ComicPage, chapterID: String, baseURL: URL, cachePolicy: CachePolicy) async -> Bool {
        do { _ = try await imageData(page: page, chapterID: chapterID, baseURL: baseURL, cachePolicy: cachePolicy) }
        catch KomiicError.imageQuotaExceeded { return true }
        catch KomiicError.rateLimited { return true }
        catch KomiicError.authenticationRequired { return true }
        catch {}
        return false
    }

    private func releaseImageRequest(_ key: ImageRequestKey, readerID: UUID) {
        guard var pending = imageRequests[key], pending.readers.remove(readerID) != nil else { return }
        if pending.readers.isEmpty {
            imageRequests.removeValue(forKey: key)
            pending.task.cancel()
        } else {
            imageRequests[key] = pending
        }
    }

    func clearCache(chapterID: String? = nil) {
        if let chapterID { cacheGenerations.removeValue(forKey: chapterID) }
        else { cacheGenerations.removeAll() }
        if let chapterID { readingPositions.removeValue(forKey: chapterID) }
        else { readingPositions.removeAll() }
        do {
            updateCacheSize(try pageCache.clear(chapter: chapterID.map(Self.fileName)))
        } catch { lastError = "无法清除阅读缓存：\(error.localizedDescription)" }
    }

    func applyCachePolicy(_ policy: CachePolicy) {
        do { updateCacheSize(try pageCache.maintain(maximumAge: policy == .oneDay ? 86_400 : nil)) }
        catch { lastError = "部分阅读缓存无法清除：\(error.localizedDescription)" }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].status = .downloading
                activeID = id
                let transfer = Task { try await self.fetchChapter(id: id) }
                currentDownload = transfer
                do {
                    try await transfer.value
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].status = .completed
                        items[index].errorMessage = nil
                    }
                } catch is CancellationError {
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = .paused }
                } catch {
                    if (error as? URLError)?.code == .cancelled {
                        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = .paused }
                    } else { fail(id: id, error: error) }
                }
                tryPersist(id: id)
                currentDownload = nil
                activeID = nil
            }
            worker = nil
        }
    }

    private func fetchChapter(id: String) async throws {
        guard let initial = items.first(where: { $0.id == id }) else { throw CancellationError() }
        for page in initial.pages {
            try Task.checkCancellation()
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            let destination = pageFile(in: chapterDirectory(id), pageID: page.id)
            if items[index].downloadedPageIDs.contains(page.id), Self.byteSize(destination) > 0 { continue }
            let data = try await imageData(page: page, chapterID: id, baseURL: initial.sourceURL, cachePolicy: .never)
            try Task.checkCancellation()
            guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            try data.write(to: destination, options: .atomic)
            items[currentIndex].downloadedPageIDs.insert(page.id)
            items[currentIndex].byteCount = items[currentIndex].pages.reduce(0) { $0 + Self.byteSize(pageFile(in: chapterDirectory(id), pageID: $1.id)) }
            try persist(id: id)
        }
    }

    private func fetchImage(page: ComicPage, baseURL: URL) async throws -> Data {
        let data: Data
        if let imageLoader { data = try await imageLoader(page, baseURL) }
        else { data = try await KomiicAPI(baseURL: baseURL, session: session).imageData(for: page) }
        try Task.checkCancellation()
        try await ImageDecoding.validate(data)
        return data
    }

    private func persist(id: String) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let directory = chapterDirectory(id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(item).write(to: directory.appendingPathComponent("chapter.json"), options: .atomic)
    }

    private func tryPersist(id: String) {
        do { try persist(id: id) }
        catch { lastError = "下载进度尚未保存：\(error.localizedDescription)" }
    }

    private func fail(id: String, error: Error) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].status = .failed
            items[index].errorMessage = error.localizedDescription
        }
        lastError = error.localizedDescription
    }

    private func chapterDirectory(_ id: String) -> URL { directoryURL.appendingPathComponent(Self.fileName(id), isDirectory: true) }
    private func cacheChapterDirectory(_ id: String) -> URL { cacheDirectory.appendingPathComponent(Self.fileName(id), isDirectory: true) }
    private func pageFile(in directory: URL, pageID: String) -> URL { directory.appendingPathComponent(Self.fileName(pageID) + ".image") }
    private static func fileName(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func byteSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }

    private func updateCacheSize(_ snapshot: PageImageDiskCache.Snapshot) {
        guard snapshot.revision >= cacheRevision else { return }
        cacheRevision = snapshot.revision
        if cacheBytes != snapshot.bytes { cacheBytes = snapshot.bytes }
    }
}
