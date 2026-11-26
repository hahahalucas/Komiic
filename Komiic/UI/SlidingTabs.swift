import QuartzCore
import SwiftUI
import UIKit

struct SlidingTabs<Screen: View>: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    let screen: (AppTab) -> Screen

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let screens = AppTab.allCases.map { tab in
            let host = UIHostingController(rootView: screen(tab))
            host.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), tag: 0)
            return host
        }
        context.coordinator.screens = screens
        if #available(iOS 18.0, *) { controller.mode = .tabBar }
        if #available(iOS 26.0, *) { controller.tabBarMinimizeBehavior = .onScrollDown }
        controller.setViewControllers(screens, animated: false)
        context.coordinator.applySelection(to: controller)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        let theme = context.environment.komiicTheme
        controller.view.tintColor = UIColor(theme.accent)
        controller.view.backgroundColor = UIColor(theme.canvas)
        for (tab, host) in zip(AppTab.allCases, coordinator.screens) {
            host.rootView = screen(tab)
        }
        coordinator.applySelection(to: controller)
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selection: Binding<AppTab>
        var screens: [UIHostingController<Screen>] = []
        var reduceMotion = false
        private var sliding = false

        init(selection: Binding<AppTab>) { self.selection = selection }

        func applySelection(to controller: UITabBarController) {
            guard !sliding, let index = AppTab.allCases.firstIndex(of: selection.wrappedValue),
                  controller.selectedIndex != index else { return }
            controller.selectedIndex = index
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            !sliding
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard let index = screens.firstIndex(where: { $0 === viewController }) else { return }
            let tab = AppTab.allCases[index]
            if selection.wrappedValue != tab { selection.wrappedValue = tab }
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              animationControllerForTransitionFrom fromVC: UIViewController,
                              to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            guard !reduceMotion, !UIAccessibility.isReduceMotionEnabled,
                  let from = screens.firstIndex(where: { $0 === fromVC }),
                  let to = screens.firstIndex(where: { $0 === toVC }), from != to else { return nil }
            let forward = from < to
            let leftToRight = tabBarController.view.effectiveUserInterfaceLayoutDirection == .leftToRight
            sliding = true
            return TabSlideAnimator(direction: forward == leftToRight ? 1 : -1) { [weak self, weak tabBarController] in
                self?.sliding = false
                DispatchQueue.main.async { [weak self, weak tabBarController] in
                    if let tabBarController { self?.applySelection(to: tabBarController) }
                }
            }
        }
    }
}

private final class TabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let direction: CGFloat
    let completion: () -> Void

    init(direction: CGFloat, completion: @escaping () -> Void) {
        self.direction = direction
        self.completion = completion
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.28 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to),
              let destination = context.viewController(forKey: .to) else {
            context.completeTransition(false)
            completion()
            return
        }
        let container = context.containerView
        let distance = container.bounds.width * direction
        let maximumRate = Float(container.window?.screen.maximumFramesPerSecond ?? 60)
        let frameRate = CAFrameRateRange(minimum: min(90, maximumRate), maximum: maximumRate, preferred: maximumRate)
        let originalTransform = from.transform

        to.frame = context.finalFrame(for: destination)
        container.addSubview(to)
        to.layoutIfNeeded()

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.isAdditive = true
        slide.fromValue = distance
        slide.toValue = 0
        slide.duration = transitionDuration(using: context)
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.preferredFrameRateRange = frameRate

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [completion] in
            let completed = !context.transitionWasCancelled
            if !completed { to.removeFromSuperview() }
            context.completeTransition(completed)
            from.transform = originalTransform
            completion()
        }
        from.transform = originalTransform.translatedBy(x: -distance, y: 0)
        from.layer.add(slide, forKey: "tabSlide")
        to.layer.add(slide, forKey: "tabSlide")
        CATransaction.commit()
    }
}
