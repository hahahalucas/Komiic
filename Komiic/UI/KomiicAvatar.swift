import SwiftUI
import UIKit

struct KomiicAvatar: View {
    let name: String
    let profileText: String?
    let url: URL?
    let size: CGFloat
    @State private var image: UIImage?

    private var initials: String {
        let custom = profileText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? String(name.prefix(2)).uppercased() : custom
    }

    var body: some View {
        ZStack {
            Circle().fill(KomiicTheme.accent)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.white)
            } else {
                Text(initials).font(.system(size: size * 0.33, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.4).foregroundStyle(.white)
                    .padding(.horizontal, size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            image = nil
            guard let url, url.scheme == "https",
                  let loaded = try? await CoverImageLoader.shared.image(for: url), !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}
