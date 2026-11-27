import SwiftUI
import UIKit

struct TabSwipeTargets {
    var previous: AppTab? = nil
    var next: AppTab? = nil

    func destination(horizontal: CGFloat, vertical: CGFloat) -> AppTab? {
        guard abs(horizontal) > abs(vertical) * 1.3 else { return nil }
        return horizontal < 0 ? next : previous
    }
}

struct SlidingTabs<Screen: View>: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    let swipeTargets: (AppTab) -> TabSwipeTargets?
    let prepareSwipe: (AppTab) -> (() -> Void)?
    let screen: (AppTab) -> Screen

    func makeCoordinator() -> SlidingTabsCoordinator { SlidingTabsCoordinator(selection: $selection) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let screens = AppTab.allCases.map { tab in
            let host = UIHostingController(rootView: screen(tab))
            host.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: 0)
            return host
        }
        if #available(iOS 18.0, *) { controller.mode = .tabBar }
        if #available(iOS 26.0, *) { controller.tabBarMinimizeBehavior = .onScrollDown }
        controller.setViewControllers(screens, animated: false)
        context.coordinator.attach(to: controller)
        context.coordinator.applySelection()
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.swipeTargets = swipeTargets
        coordinator.prepareSwipe = prepareSwipe
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        let theme = context.environment.komiicTheme
        controller.view.tintColor = UIColor(theme.accent)
        controller.view.backgroundColor = UIColor(theme.canvas)
        for (tab, child) in zip(AppTab.allCases, controller.viewControllers ?? []) {
            (child as? UIHostingController<Screen>)?.rootView = screen(tab)
        }
        coordinator.applySelection()
    }
}

@MainActor
final class SlidingTabsCoordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
    private struct Swipe {
        let destination: AppTab
        let direction: CGFloat
        let width: CGFloat
        let finishDistance: CGFloat
        let driver: UIPercentDrivenInteractiveTransition
        let undoPreparation: (() -> Void)?
    }

    var selection: Binding<AppTab>
    var swipeTargets: (AppTab) -> TabSwipeTargets? = { _ in nil }
    var prepareSwipe: (AppTab) -> (() -> Void)? = { _ in nil }
    var reduceMotion = false

    private weak var controller: UITabBarController?
    private var proposedSwipe: (destination: AppTab, direction: CGFloat)?
    private var activeSwipe: Swipe?
    private var sliding = false

    init(selection: Binding<AppTab>) { self.selection = selection }

    func attach(to controller: UITabBarController) {
        self.controller = controller
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        controller.view.addGestureRecognizer(pan)
        controller.delegate = self
    }

    func applySelection() {
        guard !sliding, activeSwipe == nil, let controller,
              let index = AppTab.allCases.firstIndex(of: selection.wrappedValue), controller.selectedIndex != index else { return }
        controller.selectedIndex = index
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !sliding, activeSwipe == nil, let controller, controller.presentedViewController == nil,
              let screen = controller.selectedViewController?.viewIfLoaded, let touchedView = touch.view,
              touchedView.isDescendant(of: screen), !touchedView.isDescendant(of: controller.tabBar) else { return false }
        // The home pager may still be settling when the touch starts. Resolve the direction and destination when the pan begins.
        return swipeTargets(selection.wrappedValue) != nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        proposedSwipe = nil
        guard !sliding, activeSwipe == nil, let controller, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: controller.view)
        let direction: CGFloat = controller.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        guard let targets = swipeTargets(selection.wrappedValue),
              let destination = targets.destination(horizontal: velocity.x * direction, vertical: velocity.y) else { return false }
        proposedSwipe = (destination, velocity.x < 0 ? -1 : 1)
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Give the tab swipe first refusal. Vertical gestures and home subpage swipes fall through to the scroll views.
        guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
        return otherGestureRecognizer === scrollView.panGestureRecognizer
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let controller else { return }
        if pan.state == .began {
            guard let proposal = proposedSwipe, let index = AppTab.allCases.firstIndex(of: proposal.destination) else { return }
            proposedSwipe = nil
            let driver = UIPercentDrivenInteractiveTransition()
            driver.completionCurve = .easeOut
            let width = max(1, controller.selectedViewController?.view.superview?.bounds.width ?? controller.view.bounds.width)
            let fromRecent = selection.wrappedValue == .home && proposal.destination == .favorites
            let finishDistance = fromRecent ? min(width * 0.25, 120) : width * 0.35
            activeSwipe = Swipe(destination: proposal.destination, direction: proposal.direction,
                                width: width, finishDistance: finishDistance, driver: driver,
                                undoPreparation: prepareSwipe(proposal.destination))
            controller.selectedIndex = index
            if !sliding {
                completeSwipe(completed: controller.selectedIndex == index)
            }
        }

        guard let swipe = activeSwipe else { return }
        let distance = pan.translation(in: controller.view).x * swipe.direction
        let progress = min(1, max(0, distance / swipe.width))
        switch pan.state {
        case .began, .changed:
            swipe.driver.update(progress)
        case .ended:
            swipe.driver.update(progress)
            let speed = pan.velocity(in: controller.view).x * swipe.direction
            let finishDistance = swipe.finishDistance
            if distance >= finishDistance || (distance >= 16 && distance + speed * 0.18 >= finishDistance) {
                swipe.driver.finish()
            } else {
                swipe.driver.cancel()
            }
        case .cancelled, .failed:
            swipe.driver.cancel()
        default:
            break
        }
    }

    private func completeSwipe(completed: Bool) {
        guard let swipe = activeSwipe else { return }
        activeSwipe = nil
        if completed {
            selection.wrappedValue = swipe.destination
        } else {
            swipe.undoPreparation?()
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        !sliding && activeSwipe == nil
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard activeSwipe == nil, let index = tabBarController.viewControllers?.firstIndex(where: { $0 === viewController }) else { return }
        let tab = AppTab.allCases[index]
        if selection.wrappedValue != tab { selection.wrappedValue = tab }
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          animationControllerForTransitionFrom fromVC: UIViewController,
                          to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let reduceMotion = self.reduceMotion || UIAccessibility.isReduceMotionEnabled
        guard activeSwipe != nil || !reduceMotion,
              let screens = tabBarController.viewControllers,
              let from = screens.firstIndex(where: { $0 === fromVC }),
              let to = screens.firstIndex(where: { $0 === toVC }), from != to else { return nil }
        let leftToRight = tabBarController.view.effectiveUserInterfaceLayoutDirection == .leftToRight
        let direction: CGFloat = (from < to) == leftToRight ? 1 : -1
        sliding = true
        return TabSlideAnimator(direction: direction, duration: reduceMotion ? 0.15 : 0.28) { [weak self] completed in
            self?.sliding = false
            self?.completeSwipe(completed: completed)
            DispatchQueue.main.async { [weak self] in self?.applySelection() }
        }
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        activeSwipe?.driver
    }
}

private final class TabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let direction: CGFloat
    let duration: TimeInterval
    let completion: (Bool) -> Void

    init(direction: CGFloat, duration: TimeInterval, completion: @escaping (Bool) -> Void) {
        self.direction = direction
        self.duration = duration
        self.completion = completion
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { duration }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to),
              let destination = context.viewController(forKey: .to) else {
            context.completeTransition(false)
            completion(false)
            return
        }
        let container = context.containerView
        let distance = container.bounds.width * direction
        let fromTransform = from.transform
        let toTransform = to.transform
        let clipsToBounds = container.clipsToBounds

        container.clipsToBounds = true
        to.frame = context.finalFrame(for: destination)
        to.transform = toTransform.translatedBy(x: distance, y: 0)
        container.addSubview(to)
        to.layoutIfNeeded()

        UIView.animate(withDuration: duration, delay: 0, options: context.isInteractive ? .curveLinear : .curveEaseInOut) {
            from.transform = fromTransform.translatedBy(x: -distance, y: 0)
            to.transform = toTransform
        } completion: { [completion] _ in
            let completed = !context.transitionWasCancelled
            if !completed { to.removeFromSuperview() }
            context.completeTransition(completed)
            from.transform = fromTransform
            to.transform = toTransform
            container.clipsToBounds = clipsToBounds
            completion(completed)
        }
    }
}
