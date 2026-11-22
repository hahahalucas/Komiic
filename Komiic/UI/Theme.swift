import SwiftUI

enum KomiicTheme {
    static let accent = Color(red: 0.22, green: 0.39, blue: 0.58)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.08)
    static let softBlue = accent.opacity(0.12)
}

struct BrandMark: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17, weight: .bold))
            Text("KOMIIC")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(-1)
        }
        .foregroundStyle(KomiicTheme.accent)
        .accessibilityLabel("Komiic")
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(KomiicTheme.accent)
                .frame(width: 80, height: 80)
                .background(KomiicTheme.softBlue, in: RoundedRectangle(cornerRadius: 25))
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
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? KomiicTheme.accent : Color.secondary)
                .background(selected ? KomiicTheme.softBlue : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .komiicGlass(cornerRadius: 24, interactive: true)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
    func komiicGlass(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(KomiicGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
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
        self.background(KomiicTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(KomiicTheme.line, lineWidth: 0.5))
    }
}

private struct KomiicGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(KomiicTheme.line, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
