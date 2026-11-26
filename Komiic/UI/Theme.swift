import SwiftUI
import UIKit

struct KomiicTheme {
    let accent: Color
    let canvas: Color
    let card: Color
    static let line = Color.primary.opacity(0.08)
    var accentWash: Color { accent.opacity(0.12) }

    init(palette: AppPalette = .standard) {
        switch palette {
        case .standard:
            self.init(accent: Color(red: 0.22, green: 0.39, blue: 0.58),
                      canvas: Color(uiColor: .systemGroupedBackground),
                      card: Color(uiColor: .secondarySystemGroupedBackground))
        case .rose:
            self.init(light: (0xB07080, 0xFDFAFB, 0xFAF4F5), dark: (0xD4909A, 0x120E0F, 0x1E1618))
        case .violet:
            self.init(light: (0x7B6BAE, 0xFDFCFF, 0xF6F4FC), dark: (0x9E8FCC, 0x0E0C14, 0x1A1724))
        case .green:
            self.init(light: (0x5A8A6A, 0xFAFDFB, 0xF4FAF6), dark: (0x7ABAA0, 0x0C1210, 0x161E1A))
        case .amber:
            self.init(light: (0xA07050, 0xFDFCFA, 0xFAF6F2), dark: (0xD4A880, 0x12100E, 0x1E1A16))
        case .silver:
            self.init(light: (0x5C5A72, 0xFCFCFE, 0xF4F4F8), dark: (0xB8B4CC, 0x101014, 0x1C1C22))
        }
    }

    private init(accent: Color, canvas: Color, card: Color) {
        self.accent = accent
        self.canvas = canvas
        self.card = card
    }

    private typealias Colors = (accent: UInt32, canvas: UInt32, card: UInt32)

    private init(light: Colors, dark: Colors) {
        self.init(accent: Self.adaptiveColor(light: light.accent, dark: dark.accent),
                  canvas: Self.adaptiveColor(light: light.canvas, dark: dark.canvas),
                  card: Self.adaptiveColor(light: light.card, dark: dark.card))
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

private struct KomiicThemeKey: EnvironmentKey {
    static let defaultValue = KomiicTheme()
}

extension EnvironmentValues {
    var komiicTheme: KomiicTheme {
        get { self[KomiicThemeKey.self] }
        set { self[KomiicThemeKey.self] = newValue }
    }
}

struct BrandMark: View {
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17, weight: .bold))
            Text("KOMIIC")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(-1)
        }
        .foregroundStyle(theme.accent)
        .accessibilityLabel("Komiic")
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.accent)
                .frame(width: 80, height: 80)
                .background(theme.accentWash, in: RoundedRectangle(cornerRadius: 25))
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void
    @Environment(\.komiicTheme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Button(action: action) {
            label
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: symbol != nil && verticalSizeClass != .compact ? 52 : 44)
                .foregroundStyle(selected ? theme.accent : Color.primary)
                .background(selected ? theme.accentWash : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 28, interactive: true, translucent: true)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var label: some View {
        if let symbol {
            let layout = verticalSizeClass == .compact ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(spacing: 3))
            layout {
                Image(systemName: symbol).font(.system(size: 17, weight: selected ? .semibold : .medium))
                Text(title).font(.caption.weight(selected ? .semibold : .medium))
            }
        } else {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
        }
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    func komiicGlass(cornerRadius: CGFloat = 24, interactive: Bool = false, translucent: Bool = false) -> some View {
        modifier(KomiicGlassModifier(cornerRadius: cornerRadius, interactive: interactive, translucent: translucent))
    }

    @ViewBuilder func komiicGlassGroup(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } }
        else { self }
    }

    @ViewBuilder func komiicActionStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
    }

    func komiicCard() -> some View {
        modifier(KomiicCardModifier())
    }
}

private struct KomiicCardModifier: ViewModifier {
    @Environment(\.komiicTheme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(KomiicTheme.line, lineWidth: 0.5))
    }
}

private struct KomiicGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    let translucent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.komiicTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(theme.card, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(KomiicTheme.line, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            let glass: Glass = translucent ? .clear : .regular
            content.glassEffect(glass.interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            let material: Material = translucent ? .ultraThinMaterial : .regularMaterial
            content.background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
