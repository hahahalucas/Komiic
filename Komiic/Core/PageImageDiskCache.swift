import Foundation

/// A serial file queue keeps reads and atomic writes off the UI thread. Generations
/// are checked on this same queue so a late write cannot recreate a cleared cache.
final class PageImageDiskCache: @unchecked Sendable {
    struct Snapshot: Sendable {
        let bytes: Int64
        let revision: UInt64
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "cc.komiic.page-cache", qos: .userInitiated)
    private var generations: [String: UUID] = [:]
    private var bytes: Int64 = 0
    private var revision: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    func register(chapter: String, generation: UUID) {
        queue.sync { generations[chapter] = generation }
    }

    func read(from url: URL, maximumAge: TimeInterval?) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                if let maximumAge {
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard Date().timeIntervalSince(modified) < maximumAge else {
                        continuation.resume(returning: nil)
                        return
                    }
                }
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.flatMap { ImageDecoding.isValid($0) ? $0 : nil })
            }
        }
    }

    func write(_ data: Data, to url: URL, chapter: String, generation: UUID) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.generations[chapter] == generation {
                        let previous = Self.byteSize(url)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        self.bytes = max(0, self.bytes + Int64(data.count) - previous)
                        self.revision &+= 1
                    }
                    continuation.resume(returning: self.snapshot)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func clear(chapter: String?) throws -> Snapshot {
        try queue.sync {
            if let chapter { generations.removeValue(forKey: chapter) }
            else { generations.removeAll() }
            let target = chapter.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
            let removed = chapter == nil ? bytes : Self.directorySize(target)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            if chapter == nil { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            bytes = max(0, bytes - removed)
            revision &+= 1
            return snapshot
        }
    }

    /// Full scans only occur at startup or explicit cache maintenance, never per page.
    func maintain(maximumAge: TimeInterval?) throws -> Snapshot {
        try queue.sync {
            var total: Int64 = 0
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) {
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                    if let maximumAge, Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) >= maximumAge {
                        try FileManager.default.removeItem(at: url)
                    } else { total += Int64(values.fileSize ?? 0) }
                }
            }
            bytes = total
            revision &+= 1
            return snapshot
        }
    }

    private var snapshot: Snapshot { Snapshot(bytes: bytes, revision: revision) }
    private static func byteSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    private static func directorySize(_ directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in files {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { size += byteSize(url) }
        }
        return size
    }
}
