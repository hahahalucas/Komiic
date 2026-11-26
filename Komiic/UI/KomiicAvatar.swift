import SwiftUI
import UIKit

struct KomiicAvatar: View {
    let name: String
    let profileText: String?
    let url: URL?
    let size: CGFloat
    var profileTextColor: String? = nil
    var profileBackgroundColor: String? = nil
    @State private var image: UIImage?

    private var initials: String {
        let custom = profileText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? String(name.prefix(2)).uppercased() : custom
    }

    var body: some View {
        ZStack {
            Circle().fill(avatarColor(profileBackgroundColor) ?? KomiicTheme.accent)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.4))
                    .foregroundStyle(avatarColor(profileTextColor) ?? Color.white)
            } else {
                Text(initials).font(.system(size: size * 0.33, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.4).foregroundStyle(avatarColor(profileTextColor) ?? Color.white)
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

    private func avatarColor(_ value: String?) -> Color? {
        guard let value, value.hasPrefix("#") else { return nil }
        var hex = String(value.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        let hasAlpha = hex.count == 8
        guard hex.count == 6 || hasAlpha, let packed = UInt32(hex, radix: 16) else { return nil }
        let rgb = hasAlpha ? packed >> 8 : packed
        let opacity = hasAlpha ? Double(packed & 255) / 255 : 1
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255, opacity: opacity)
    }
}
