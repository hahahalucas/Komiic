import SwiftUI

enum AppPage: Hashable {
    case catalog(CatalogPage)
    case favorites, library, account

    static let ordered = CatalogPage.allCases.map(AppPage.catalog) + [.favorites, .library, .account]

    var tab: AppTab {
        switch self {
        case .catalog: return .home
        case .favorites: return .favorites
        case .library: return .library
        case .account: return .account
        }
    }

    var index: Int { Self.ordered.firstIndex(of: self) ?? 0 }
}

@Observable
final class AppPagerPosition {
    var progress: CGFloat = 0

    var catalogProgress: CGFloat { min(progress, CGFloat(CatalogPage.allCases.count - 1)) }
    var tabProgress: CGFloat { progress - catalogProgress }
    var homeOpacity: Double { opacity(for: .home) }

    func opacity(for tab: AppTab) -> Double {
        max(0, 1 - Double(abs(tabProgress - CGFloat(tab.index))))
    }
}

struct SlidingTabs<Screen: View>: View {
    @Binding var scrollPage: AppPage?
    let position: AppPagerPosition
    let didSettle: (AppPage) -> Void
    @ViewBuilder let screen: (AppPage) -> Screen
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var scrolling = false

    var body: some View {
        GeometryReader { viewport in
            pager(size: viewport.size)
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
        }
    }

    @ViewBuilder private func pager(size: CGSize) -> some View {
        if #available(iOS 18.0, *) {
            scrollView(size: size)
                .onScrollPhaseChange { _, phase in
                    scrolling = phase != .idle
                    if phase == .idle { reportSettledPage() }
                }
        } else {
            scrollView(size: size)
        }
    }

    private func scrollView(size: CGSize) -> some View {
        let width = max(1, size.width)
        let rightToLeft = layoutDirection == .rightToLeft
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(AppPage.ordered, id: \.self) { page in
                    screen(page)
                        .frame(width: width, height: size.height)
                        .clipped()
                        .id(page)
                }
            }
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { geometry in
                let frame = geometry.frame(in: .named(PagerSpace.pages))
                let offset = rightToLeft ? frame.maxX - width : -frame.minX
                return min(max(0, offset / width), CGFloat(AppPage.ordered.count - 1))
            } action: { progress in
                position.progress = progress
                if !scrolling { reportSettledPage() }
            }
        }
        .coordinateSpace(.named(PagerSpace.pages))
        .scrollIndicators(.hidden, axes: .horizontal)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollPage, anchor: .center)
    }

    private func reportSettledPage() {
        let index = position.progress.rounded()
        // A canceled drag settles on the original page. The scroll target can change before that.
        guard abs(position.progress - index) < 0.01 else { return }
        didSettle(AppPage.ordered[Int(index)])
    }

    private enum PagerSpace { case pages }
}

struct AppTabBar: View {
    static let phoneHeight: CGFloat = 56

    let selected: AppTab
    let position: AppPagerPosition
    let isPad: Bool
    let select: (AppTab) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.komiicTheme) private var theme

    var body: some View {
        surface
            .frame(maxWidth: isPad ? 420 : 480)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("主标签页")
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            buttons.background(theme.card, in: Capsule())
        } else if #available(iOS 26.0, *) {
            let glass: Glass = isPad ? .regular : .clear
            buttons.glassEffect(glass.interactive(), in: Capsule())
        } else {
            buttons.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var buttons: some View {
        let layout = isPad ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 3))
        let highlightedIndex = Int(position.tabProgress.rounded())
        return HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { select(tab) } label: {
                    layout {
                        Image(systemName: tab.symbol).font(.system(size: isPad ? 16 : 20, weight: .medium))
                        Text(tab.title).font((isPad ? Font.subheadline : .caption2).weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(tab.index == highlightedIndex ? theme.accent : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: isPad ? 44 : Self.phoneHeight - 8)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
            }
        }
        .buttonStyle(.plain)
        .background { indicator }
        .padding(4)
    }

    private var indicator: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(AppTab.allCases.count)
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            Capsule().fill(theme.accent.opacity(0.18))
                .frame(width: width, height: geometry.size.height)
                .offset(x: position.tabProgress * width * direction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(nil, value: position.progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

