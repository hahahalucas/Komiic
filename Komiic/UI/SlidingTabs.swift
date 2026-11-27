import SwiftUI
import UIKit

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

struct SystemTabs<Content: View>: UIViewControllerRepresentable {
    let selected: AppTab
    let hideTopScrollEdge: Bool
    let select: (AppTab) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SystemTabsController {
        SystemTabsController(host: UIHostingController(rootView: content()))
    }

    func updateUIViewController(_ controller: SystemTabsController, context: Context) {
        (controller.host as? UIHostingController<Content>)?.rootView = content()
        controller.didSelectTab = select
        controller.hideTopScrollEdge = hideTopScrollEdge
        controller.loadViewIfNeeded()
        controller.view.tintColor = UIColor(context.environment.komiicTheme.accent)
        controller.view.backgroundColor = UIColor(context.environment.komiicTheme.canvas)
        controller.show(selected)
    }
}

@MainActor
final class SystemTabsController: UITabBarController, UITabBarControllerDelegate {
    let host: UIViewController
    var didSelectTab: (AppTab) -> Void = { _ in }
    var hideTopScrollEdge = false {
        didSet {
            guard hideTopScrollEdge != oldValue else { return }
            slots.forEach { $0.hideTopScrollEdge = hideTopScrollEdge }
        }
    }
    private let slots = AppTab.allCases.map { tab in
        let slot = SystemTabSlot()
        slot.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: 0)
        return slot
    }

    init(host: UIViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(host:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 18.0, *) { mode = .tabBar }
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .onScrollDown }
        setViewControllers(slots, animated: false)
        delegate = self
        mountContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mountContent()
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        if hideTopScrollEdge && edge == .top { return nil }
        return super.contentScrollView(for: edge)
    }

    func show(_ tab: AppTab) {
        guard let index = AppTab.allCases.firstIndex(of: tab), index != selectedIndex else { return }
        // The shared scroll view has already committed its page.
        selectedIndex = index
        mountContent()
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let index = slots.firstIndex(where: { $0 === viewController }) else { return }
        mountContent()
        didSelectTab(AppTab.allCases[index])
    }

    private func mountContent() {
        guard let slot = selectedViewController as? SystemTabSlot, host.parent !== slot else { return }
        // The same hosting controller keeps the pager and navigation alive across tab selections.
        UIView.performWithoutAnimation {
            if host.parent != nil {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            slot.addChild(host)
            host.view.frame = slot.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            slot.view.addSubview(host.view)
            host.didMove(toParent: slot)
        }
    }
}

private final class SystemTabSlot: UIViewController {
    var hideTopScrollEdge = false

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        if hideTopScrollEdge && edge == .top { return nil }
        return children.first?.contentScrollView(for: edge) ?? super.contentScrollView(for: edge)
    }
}

