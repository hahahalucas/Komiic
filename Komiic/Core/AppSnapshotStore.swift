import Foundation
import CryptoKit

/// Small, disposable UI snapshots; credentials are kept separately in Keychain.
final class AppSnapshotStore: @unchecked Sendable {
    static let shared = AppSnapshotStore()
    private let directory: URL
    private let queue = DispatchQueue(label: "Komiic.ContentSnapshots", qos: .utility)

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Komiic/ContentSnapshots", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        queue.sync {
            let file = url(key)
            guard let bytes = try? Data(contentsOf: file), bytes.count < 4_000_000 else { return nil }
            return try? JSONDecoder().decode(type, from: bytes)
        }
    }

    func save<T: Encodable & Sendable>(_ value: T, key: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url(key), options: [.atomic, .completeUntilFirstUserAuthentication])
        }
    }

    func remove(key: String) { queue.sync { _ = try? FileManager.default.removeItem(at: url(key)) } }
    func flush() { queue.sync {} }

    private func url(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}

struct CatalogSnapshot: Codable, Sendable {
    var comics: [Comic]
    var offset: Int
    var hasMore: Bool
}
