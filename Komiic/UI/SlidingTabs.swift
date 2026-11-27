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
        .scrollTargetBehavior(.viewAligned(limitBehavior: pageLimit))
        .scrollPosition(id: $scrollPage, anchor: .center)
    }

    private var pageLimit: ViewAlignedScrollTargetBehavior.LimitBehavior {
        if #available(iOS 26.0, *) { return .alwaysByOne }
        return .always
    }

    private func reportSettledPage() {
        let index = position.progress.rounded()
        // A canceled drag settles on the original page. The scroll target can change before that.
        guard abs(position.progress - index) < 0.01 else { return }
        didSettle(AppPage.ordered[Int(index)])
    }

    private enum PagerSpace { case pages }
}

