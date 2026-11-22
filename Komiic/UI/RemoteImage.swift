import SwiftUI
import UIKit
import ImageIO

/// Covers are public assets: reuse downloads and decoded thumbnails across every tab.
@MainActor
private final class CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var requests: [URL: Task<UIImage, Error>] = [:]
    private let session: URLSession

    private init() {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 160
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024,
                                          diskCapacity: 128 * 1_024 * 1_024, diskPath: "KomiicCovers")
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let request = requests[url] { return try await request.value }
        let task = Task<UIImage, Error> {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("https://komiic.cc/", forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
            return UIImage(cgImage: thumbnail)
        }
        requests[url] = task
        defer { requests[url] = nil }
        let image = try await task.value
        cache.setObject(image, forKey: url as NSURL, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
}

/// Uses the same cookie store as the API, including for protected chapter images.
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
                let data = try Data(contentsOf: url)
                guard let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
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
