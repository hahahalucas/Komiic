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
    private let session: URLSession
    private let imageLoader: (@Sendable (ComicPage, URL) async throws -> Data)?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var currentDownload: Task<Void, Error>?
    private var imageRequests: [String: Task<Data, Error>] = [:]

    var storageBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var availableBytes: Int64 {
        (try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    init(directoryURL: URL? = nil, cacheDirectory: URL? = nil, session: URLSession? = nil,
         imageLoader: (@Sendable (ComicPage, URL) async throws -> Data)? = nil) {
        self.directoryURL = directoryURL ?? URL.documentsDirectory.appendingPathComponent("KomiicOffline", isDirectory: true)
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory.appendingPathComponent("KomiicPages", isDirectory: true)
        self.imageLoader = imageLoader
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpShouldSetCookies = true
            configuration.timeoutIntervalForRequest = 40
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
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
        if let url = localImageURL(chapterID: chapterID, pageID: page.id), let data = try? Data(contentsOf: url), UIImage(data: data) != nil { return data }
        let cachedURL = pageFile(in: cacheChapterDirectory(chapterID), pageID: page.id)
        if let data = try? Data(contentsOf: cachedURL), UIImage(data: data) != nil {
            let modified = (try? cachedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if cachePolicy != .oneDay || Date().timeIntervalSince(modified) < 86_400 { return data }
        }
        guard allowNetwork else { throw ImageStorageError.missingOfflinePage }
        let data = try await fetchImage(page: page, baseURL: baseURL)
        try Task.checkCancellation()
        try fileManager.createDirectory(at: cachedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cachedURL, options: .atomic)
        updateCacheSize()
        return data
    }

    func clearCache(chapterID: String? = nil) {
        let target = chapterID.map(cacheChapterDirectory) ?? cacheDirectory
        do {
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            if chapterID == nil { try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) }
            updateCacheSize()
        } catch { lastError = "无法清除阅读缓存：\(error.localizedDescription)" }
    }

    func applyCachePolicy(_ policy: CachePolicy) {
        if policy == .oneDay, let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                if Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) >= 86_400 {
                    do { try fileManager.removeItem(at: url) }
                    catch { lastError = "部分阅读缓存无法清除：\(error.localizedDescription)" }
                }
            }
        }
        updateCacheSize()
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
                let transfer = Task { try await fetchChapter(id: id) }
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
            let cachedURL = pageFile(in: cacheChapterDirectory(id), pageID: page.id)
            let data: Data
            if let cached = try? Data(contentsOf: cachedURL), UIImage(data: cached) != nil { data = cached }
            else { data = try await fetchImage(page: page, baseURL: initial.sourceURL) }
            try Task.checkCancellation()
            guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            try data.write(to: destination, options: .atomic)
            items[currentIndex].downloadedPageIDs.insert(page.id)
            items[currentIndex].byteCount = items[currentIndex].pages.reduce(0) { $0 + Self.byteSize(pageFile(in: chapterDirectory(id), pageID: $1.id)) }
            try persist(id: id)
        }
    }

    private func fetchImage(page: ComicPage, baseURL: URL) async throws -> Data {
        let key = "\(baseURL.absoluteString)|\(page.kid)"
        if let running = imageRequests[key] { return try await running.value }
        let request = Task<Data, Error> {
            if let imageLoader { return try await imageLoader(page, baseURL) }
            return try await KomiicAPI(baseURL: baseURL, session: session).imageData(for: page)
        }
        imageRequests[key] = request
        defer { imageRequests[key] = nil }
        let data: Data
        data = try await request.value
        try Task.checkCancellation()
        guard !data.isEmpty, UIImage(data: data) != nil else { throw ImageStorageError.invalidImage }
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

    private func updateCacheSize() {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else { cacheBytes = 0; return }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { size += Self.byteSize(url) }
        }
        cacheBytes = size
    }
}
