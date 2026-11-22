import SwiftUI
import UIKit

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
            var request = URLRequest(url: url)
            request.setValue("https://komiic.cc/", forHTTPHeaderField: "Referer")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            uiImage = decoded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failure = true
        }
    }
}
