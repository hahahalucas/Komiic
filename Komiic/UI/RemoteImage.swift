import SwiftUI
import UIKit

/// Covers are public assets: reuse downloads and decoded thumbnails across every tab.
@MainActor
final class CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var requests: [URL: Task<UIImage, Error>] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 160
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024,
                                          diskCapacity: 128 * 1_024 * 1_024, diskPath: "KomiicCovers")
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let request = requests[url] { return try await request.value }
        let task = Task<UIImage, Error> {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("https://komiic.cc/", forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try await ImageDecoding.image(from: data, maximumPixelSize: 640)
        }
        requests[url] = task
        defer { requests[url] = nil }
        let image = try await task.value
        cache.setObject(image, forKey: url as NSURL, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
}

/// Public covers are cached without sending account cookies to their CDN.
struct RemoteImage: View {
    let url: URL?
    var aspectRatio: CGFloat? = nil
    @State private var uiImage: UIImage?
    @State private var failure = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.045))
            if let uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if failure {
                Button { attempt += 1 } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .accessibilityLabel("重新载入图片")
            } else if url != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "book.closed").foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .task(id: "\(url?.absoluteString ?? "")-\(attempt)") { await load() }
        .accessibilityHidden(true)
    }

    @MainActor private func load() async {
        uiImage = nil
        failure = false
        guard let url else { return }
        do {
            if url.isFileURL {
                guard let data = await ImageDecoding.read(from: url) else { throw URLError(.cannotDecodeContentData) }
                let decoded = try await ImageDecoding.image(from: data, maximumPixelSize: 640)
                try Task.checkCancellation()
                uiImage = decoded
                return
            }
            let decoded = try await CoverImageLoader.shared.image(for: url)
            try Task.checkCancellation()
            uiImage = decoded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failure = true
        }
    }
}
