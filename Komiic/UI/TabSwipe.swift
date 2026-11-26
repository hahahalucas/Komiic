import SwiftUI
import UIKit

struct TabSwipeTargets {
    var previous: AppTab? = nil
    var next: AppTab? = nil

    var isEmpty: Bool { previous == nil && next == nil }

    func destination(horizontal: CGFloat, vertical: CGFloat, minimumDistance: CGFloat = 54) -> AppTab? {
        guard abs(horizontal) >= minimumDistance, abs(horizontal) > abs(vertical) * 1.3 else { return nil }
        return horizontal < 0 ? next : previous
    }
}

struct TabSwipeModifier: ViewModifier {
    let targets: TabSwipeTargets
    let select: (AppTab) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(TabPanGesture(targets: targets, select: select))
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 20, coordinateSpace: .global).onEnded { value in
                if let destination = targets.destination(horizontal: value.translation.width, vertical: value.translation.height) {
                    select(destination)
                }
            }, including: targets.isEmpty ? .subviews : .all)
        }
    }
}

@available(iOS 18.0, *)
private struct TabPanGesture: UIGestureRecognizerRepresentable {
    let targets: TabSwipeTargets
    let select: (AppTab) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(targets: targets) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = !targets.isEmpty
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.targets = targets
        recognizer.isEnabled = !targets.isEmpty
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended, let destination = context.coordinator.destination else { return }
        let translation = recognizer.translation(in: nil)
        guard destination == targets.destination(horizontal: translation.x, vertical: translation.y) else { return }
        select(destination)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var targets: TabSwipeTargets
        var destination: AppTab?

        init(targets: TabSwipeTargets) { self.targets = targets }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            // Resolve the destination before SwiftUI's home pager can settle on its next page.
            destination = targets.destination(horizontal: velocity.x, vertical: velocity.y, minimumDistance: 0)
            return destination != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
