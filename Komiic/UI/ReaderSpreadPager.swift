import SwiftUI
import UIKit

struct ReaderSpreadPager: UIViewControllerRepresentable {
    let layout: ReaderSpreadLayout
    let page: Int
    let requestID: UUID
    let canvas: (Int) -> ReaderCanvasView
    let onPageChange: (Int) -> Void
    let onEndOfChapter: () -> Void

    func makeUIViewController(context: Context) -> ReaderSpreadPagerController {
        ReaderSpreadPagerController()
    }

    func updateUIViewController(_ controller: ReaderSpreadPagerController, context: Context) {
        controller.configure(self)
    }
}

@MainActor final class ReaderSpreadPagerController: UIViewController, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private var configuration: ReaderSpreadPager?
    private var viewport: CGSize = .zero
    private var canvases: [Int: ReaderCanvasController] = [:]
    private var loadedIndex: Int?
    private var zoomedIndex: Int?
    private var positioning = false
    private var beganAtEnd = false

    private var visibleIndex: Int {
        guard let layout = configuration?.layout, viewport.width > 0 else { return 0 }
        let index = Int((scrollView.contentOffset.x / viewport.width).rounded())
        return min(max(0, index), max(0, layout.count - 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.semanticContentAttribute = .forceLeftToRight
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(didPan(_:)))
        view.addSubview(scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if viewport != view.bounds.size { positionPager() }
    }

    func configure(_ configuration: ReaderSpreadPager) {
        loadViewIfNeeded()
        let needsPosition = self.configuration?.layout != configuration.layout
            || self.configuration?.requestID != configuration.requestID
        self.configuration = configuration
        if needsPosition || viewport != view.bounds.size { positionPager() }
        else { updateCanvases(around: visibleIndex, refresh: true) }
    }

    private func positionPager() {
        guard let configuration, view.bounds.width > 0, view.bounds.height > 0 else { return }
        positioning = true
        beganAtEnd = false
        viewport = view.bounds.size
        scrollView.frame = view.bounds
        scrollView.contentSize = CGSize(width: viewport.width * CGFloat(configuration.layout.count), height: viewport.height)
        let index = configuration.layout.horizontalIndex(for: configuration.page)
        scrollView.setContentOffset(CGPoint(x: CGFloat(index) * viewport.width, y: 0), animated: false)
        updateCanvases(around: index, refresh: true)
        positioning = false
    }

    private func updateCanvases(around index: Int, refresh: Bool = false) {
        guard let configuration, configuration.layout.count > 0, viewport.width > 0,
              refresh || loadedIndex != index else { return }
        loadedIndex = index
        let visible = max(0, index - 1)...min(configuration.layout.count - 1, index + 1)
        for oldIndex in Array(canvases.keys) where !visible.contains(oldIndex) {
            guard let canvas = canvases.removeValue(forKey: oldIndex) else { continue }
            canvas.willMove(toParent: nil)
            canvas.stop()
            canvas.view.removeFromSuperview()
            canvas.removeFromParent()
            setZoomed(false, at: oldIndex)
        }
        for index in visible {
            let page = configuration.layout.page(atHorizontalIndex: index)
            let frame = CGRect(x: CGFloat(index) * viewport.width, y: 0, width: viewport.width, height: viewport.height)
            if let canvas = canvases[index] {
                if refresh {
                    canvas.view.frame = frame
                    configuration.canvas(page).configure(canvas)
                }
            } else {
                let canvas = ReaderCanvasController()
                canvas.onZoomChange = { [weak self] in self?.setZoomed($0, at: index) }
                addChild(canvas)
                canvas.view.frame = frame
                canvases[index] = canvas
                configuration.canvas(page).configure(canvas)
                scrollView.addSubview(canvas.view)
                canvas.didMove(toParent: self)
            }
        }
    }

    private func setZoomed(_ zoomed: Bool, at index: Int) {
        if zoomed { zoomedIndex = index }
        else if zoomedIndex == index { zoomedIndex = nil }
        // A spread's pan is enabled only while zoomed. Yield paging to that canvas until it returns to 1x.
        let pan = scrollView.panGestureRecognizer
        let canPage = zoomedIndex == nil
        if pan.isEnabled != canPage { pan.isEnabled = canPage }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !positioning { updateCanvases(around: visibleIndex) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportPage() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportPage() }

    private func reportPage() {
        guard !positioning, let configuration, viewport.width > 0 else { return }
        let page = configuration.layout.page(atHorizontalIndex: visibleIndex)
        if page != configuration.layout.start(for: configuration.page) { configuration.onPageChange(page) }
    }

    @objc private func didPan(_ pan: UIPanGestureRecognizer) {
        guard !positioning, let configuration, configuration.layout.count > 0, viewport.width > 0 else { return }
        switch pan.state {
        case .began:
            let lastIndex = configuration.layout.horizontalIndex(for: configuration.layout.pageCount - 1)
            let endOffset = CGFloat(lastIndex) * viewport.width
            beganAtEnd = abs(scrollView.contentOffset.x - endOffset) <= 20
        case .ended:
            defer { beganAtEnd = false }
            if beganAtEnd, zoomedIndex == nil, configuration.layout.isForwardSwipe(pan.translation(in: view)) {
                configuration.onEndOfChapter()
            }
        case .cancelled, .failed:
            beganAtEnd = false
        default:
            break
        }
    }
}
