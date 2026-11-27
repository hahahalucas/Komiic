import SwiftUI
import UIKit

struct ReaderCanvasView: UIViewControllerRepresentable {
    let pages: [ComicPage]
    let scopeID: String
    let mode: ReaderCanvasMode
    var landscapeSizing: ReaderLandscapeSizing? = nil
    let targetPage: Int
    let requestID: UUID
    let resetID: UUID
    let spacing: CGFloat
    let footer: String
    let onPageChange: (Int) -> Void
    let onZoomChange: (Bool) -> Void
    let onEndOfChapter: () -> Void
    let renderPage: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    func makeUIViewController(context: Context) -> ReaderCanvasController {
        let controller = ReaderCanvasController()
        controller.onPageChange = { [weak coordinator = context.coordinator] in coordinator?.page($0) }
        controller.onZoomChange = { [weak coordinator = context.coordinator] in coordinator?.zoom($0) }
        controller.onEndOfChapter = { [weak coordinator = context.coordinator] in coordinator?.owner.onEndOfChapter() }
        return controller
    }
    func updateUIViewController(_ controller: ReaderCanvasController, context: Context) {
        context.coordinator.owner = self
        controller.configure(pages: pages, scopeID: scopeID, mode: mode, targetPage: targetPage,
            requestID: requestID, resetID: resetID, spacing: spacing, footer: footer,
            landscapeSizing: landscapeSizing, renderPage: renderPage)
    }
    static func dismantleUIViewController(_ controller: ReaderCanvasController, coordinator: Coordinator) {
        coordinator.pageReport?.cancel()
        coordinator.zoomReport?.cancel()
        controller.onPageChange = nil
        controller.onZoomChange = nil
        controller.onEndOfChapter = nil
        controller.stop()
    }

    @MainActor final class Coordinator {
        var owner: ReaderCanvasView
        var pageReport: Task<Void, Never>?
        var zoomReport: Task<Void, Never>?
        private var currentPage: Int?
        private var zoomed = false
        init(owner: ReaderCanvasView) { self.owner = owner }
        func page(_ index: Int) {
            guard currentPage != index else { return }
            currentPage = index
            pageReport?.cancel()
            pageReport = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.owner.onPageChange(index)
            }
        }
        func zoom(_ active: Bool) {
            guard active != zoomed else { return }
            zoomed = active
            zoomReport?.cancel()
            zoomReport = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.owner.onZoomChange(active)
            }
        }
    }
}

@MainActor final class ReaderCanvasController: UIViewController, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private(set) var layout = ReaderCanvasLayout(pages: [], viewport: .zero, mode: .chapter)
    private(set) var renderedPages: Set<Int> = []
    var onPageChange: ((Int) -> Void)?
    var onZoomChange: ((Bool) -> Void)?
    var onEndOfChapter: (() -> Void)?
    private var pages: [ComicPage] = []
    private var scopeID: String?
    private var mode: ReaderCanvasMode = .chapter
    private var landscapeSizing: ReaderLandscapeSizing?
    private var targetPage = 0
    private var requestID: UUID?
    private var resetID: UUID?
    private var spacing: CGFloat = 8
    private var footer = ""
    private var renderPage: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
    private var viewport: CGSize = .zero
    private var rebuilding = false
    private var beganAtEnd = false
    private var pinchedDuringDrag = false
    private let coordinatedParents = NSHashTable<UIScrollView>.weakObjects()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.semanticContentAttribute = .forceLeftToRight
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.frame = view.bounds
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(didPan(_:)))
        view.addSubview(scrollView)
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.semanticContentAttribute = .forceLeftToRight
        scrollView.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func configure(pages: [ComicPage], scopeID: String, mode: ReaderCanvasMode, targetPage: Int,
                   requestID: UUID, resetID: UUID, spacing: CGFloat, footer: String,
                   landscapeSizing: ReaderLandscapeSizing? = nil,
                   renderPage: @escaping (Int) -> AnyView) {
        loadViewIfNeeded()
        let changed = self.scopeID != scopeID || self.pages != pages || self.mode != mode || self.spacing != spacing
            || self.landscapeSizing != landscapeSizing
        let requested = self.requestID != requestID
        let reset = self.resetID != resetID
        let footerChanged = self.footer != footer
        self.pages = pages; self.scopeID = scopeID; self.mode = mode; self.targetPage = targetPage
        self.landscapeSizing = landscapeSizing
        self.requestID = requestID; self.resetID = resetID; self.spacing = spacing; self.footer = footer
        self.renderPage = renderPage
        if changed || viewport != view.bounds.size { rebuild() }
        else if reset || requested { restoreScale(); if requested { scroll(to: targetPage) } }
        updateVisiblePages(force: changed || footerChanged || requested || reset)
        coordinateParentGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        if viewport != view.bounds.size { rebuild() }
        coordinateParentGestures()
        updateVisiblePages()
    }

    private func rebuild() {
        guard !rebuilding, view.bounds.width > 0, view.bounds.height > 0 else { return }
        rebuilding = true
        viewport = view.bounds.size
        scrollView.frame = view.bounds
        scrollView.setZoomScale(1, animated: false)
        layout = ReaderCanvasLayout(pages: pages, viewport: viewport, mode: mode, spacing: spacing,
                                    landscapeSizing: landscapeSizing)
        host.view.transform = .identity
        host.view.frame = CGRect(origin: .zero, size: layout.size)
        scrollView.contentSize = layout.size
        scrollView.bounces = mode.isChapter
        scrollView.alwaysBounceVertical = mode.isChapter
        scrollView.panGestureRecognizer.isEnabled = mode.isChapter
        renderedPages = []
        scroll(to: targetPage)
        rebuilding = false
        onZoomChange?(false)
        updateVisiblePages(force: true)
    }

    private func restoreScale() {
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.setZoomScale(1, animated: false)
        scrollView.pinchGestureRecognizer?.isEnabled = true
        scrollView.panGestureRecognizer.isEnabled = mode.isChapter
        if !mode.isChapter { scrollView.contentOffset = .zero }
        onZoomChange?(false)
    }

    private func scroll(to page: Int) {
        let y = mode.isChapter ? layout.items.first(where: { $0.id == page })?.frame.minY ?? 0 : 0
        scrollView.setContentOffset(CGPoint(x: 0, y: min(y, max(0, layout.size.height - viewport.height))), animated: false)
    }

    private func updateVisiblePages(force: Bool = false) {
        guard !rebuilding, viewport.width > 0, viewport.height > 0 else { return }
        let visible = scrollView.convert(scrollView.bounds, to: host.view)
        let indices = mode.isChapter ? layout.visiblePages(in: visible) : Set(layout.items.map(\.id))
        if indices != renderedPages || force {
            renderedPages = indices
            let layout = layout, render = renderPage, footer = footer
            host.rootView = AnyView(ZStack(alignment: .topLeading) {
                ForEach(layout.items.filter { indices.contains($0.id) }) { item in
                    render(item.id)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                }
                if let frame = layout.footerFrame {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .environment(\.layoutDirection, .leftToRight).ignoresSafeArea())
        }
        if mode.isChapter { onPageChange?(layout.page(at: max(0, visible.minY))) }
    }

    private func coordinateParentGestures() {
        guard !mode.isChapter else { return }
        var ancestor = scrollView.superview
        while let node = ancestor {
            if let parent = node as? UIScrollView, !coordinatedParents.contains(parent) {
                parent.panGestureRecognizer.maximumNumberOfTouches = 1
                parent.panGestureRecognizer.require(toFail: scrollView.panGestureRecognizer)
                coordinatedParents.add(parent)
            }
            ancestor = node.superview
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisiblePages() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        pinchedDuringDrag = true
        onZoomChange?(true)
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !rebuilding else { return }
        scrollView.panGestureRecognizer.isEnabled = mode.isChapter || scrollView.zoomScale > 1
        onZoomChange?(scrollView.isZooming || scrollView.zoomScale > 1)
        updateVisiblePages()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scrollView.panGestureRecognizer.isEnabled = mode.isChapter || scrollView.zoomScale > 1
        onZoomChange?(scrollView.zoomScale > 1)
        updateVisiblePages()
    }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        guard mode.isChapter else { return }
        if gesture.state == .began {
            pinchedDuringDrag = scrollView.isZooming
            beganAtEnd = scrollView.zoomScale == 1 && scrollView.contentOffset.y + viewport.height >= layout.size.height - 8
        } else if gesture.state == .ended {
            let movement = gesture.translation(in: scrollView)
            if beganAtEnd, !pinchedDuringDrag, scrollView.zoomScale == 1,
               movement.y < -85, abs(movement.y) > abs(movement.x) * 1.5 { onEndOfChapter?() }
        }
    }
    func stop() { host.rootView = AnyView(EmptyView()); scrollView.delegate = nil }
}
