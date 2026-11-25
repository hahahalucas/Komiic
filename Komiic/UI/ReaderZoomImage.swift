import SwiftUI
import UIKit

/// Each page keeps its original fitted size as the minimum zoom level.
struct ReaderZoomImage: UIViewRepresentable {
    let image: UIImage
    let resetID: UUID
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange) }

    func makeUIView(context: Context) -> ReaderImageScrollView {
        let view = ReaderImageScrollView(frame: .zero)
        view.onZoomChange = { [weak coordinator = context.coordinator] in coordinator?.report($0) }
        view.update(image: image, resetID: resetID)
        return view
    }

    func updateUIView(_ view: ReaderImageScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        view.update(image: image, resetID: resetID)
    }

    static func dismantleUIView(_ view: ReaderImageScrollView, coordinator: Coordinator) {
        coordinator.pendingReport?.cancel()
        view.onZoomChange = nil
    }

    @MainActor final class Coordinator {
        var onZoomChange: (Bool) -> Void
        var pendingReport: Task<Void, Never>?
        private var active = false

        init(onZoomChange: @escaping (Bool) -> Void) { self.onZoomChange = onZoomChange }

        func report(_ value: Bool) {
            guard active != value else { return }
            active = value
            pendingReport?.cancel()
            // Bounds/image resets can occur inside a SwiftUI update.
            pendingReport = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.onZoomChange(value)
            }
        }
    }
}

@MainActor final class ReaderImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChange: ((Bool) -> Void)?
    private var resetID: UUID?
    private var fittedSize: CGSize = .zero
    private var resetting = false
    private let coordinatedParents = NSHashTable<UIScrollView>.weakObjects()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = false
        bounces = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        panGestureRecognizer.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: UIImage, resetID: UUID) {
        let changed = imageView.image !== image || self.resetID != resetID
        imageView.image = image
        self.resetID = resetID
        if changed { resetZoom() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize { resetZoom() }
        coordinateParentGestures()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinateParentGestures()
    }

    private func resetZoom() {
        guard !resetting else { return }
        resetting = true
        fittedSize = bounds.size
        pinchGestureRecognizer?.isEnabled = false
        setZoomScale(minimumZoomScale, animated: false)
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        contentOffset = .zero
        panGestureRecognizer.isEnabled = false
        pinchGestureRecognizer?.isEnabled = true
        onZoomChange?(false)
        resetting = false
    }

    private func coordinateParentGestures() {
        var ancestor = superview
        while let view = ancestor {
            if let parent = view as? UIScrollView, !coordinatedParents.contains(parent) {
                // One finger scrolls/turns pages at 1x; a pinch belongs to this image.
                parent.panGestureRecognizer.maximumNumberOfTouches = 1
                parent.panGestureRecognizer.require(toFail: panGestureRecognizer)
                coordinatedParents.add(parent)
            }
            ancestor = view.superview
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        onZoomChange?(true)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !resetting else { return }
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale
        onZoomChange?(isZooming || zoomScale > minimumZoomScale)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !resetting else { return }
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale
        if zoomScale == minimumZoomScale { contentOffset = .zero }
        onZoomChange?(zoomScale > minimumZoomScale)
    }
}
