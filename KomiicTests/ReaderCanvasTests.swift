import XCTest
import SwiftUI
import UIKit
@testable import Komiic

@MainActor
final class ReaderCanvasTests: XCTestCase {
    func testWholeChapterUsesOneCanvasAndEveryPageScalesTogether() throws {
        let controller = makeController(pageCount: 60)
        let canvas = try XCTUnwrap(controller.viewForZooming(in: controller.scrollView))
        controller.scrollView.setZoomScale(2, animated: false)
        for item in [controller.layout.items[0], controller.layout.items[40]] {
            let scaled = canvas.convert(item.frame, to: controller.scrollView)
            XCTAssertEqual(scaled.width, item.frame.width * 2, accuracy: 0.01)
            XCTAssertEqual(scaled.height, item.frame.height * 2, accuracy: 0.01)
        }
        XCTAssertGreaterThan(controller.scrollView.contentSize.height, 50_000)
    }

    func testLandscapePagesShareZoomAndKeepPhysicalReadingOrder() throws {
        let arrangements: [[Int?]] = [[0, 1], [1, 0]]
        for slots in arrangements {
            let controller = makeController(pageCount: 2, mode: .spread(slots))
            let canvas = try XCTUnwrap(controller.viewForZooming(in: controller.scrollView))
            XCTAssertEqual(controller.layout.items.map(\.id), slots.compactMap { $0 })
            let left = controller.layout.items[0], right = controller.layout.items[1]
            XCTAssertEqual(left.frame.maxX, right.frame.minX, accuracy: 0.01)
            controller.scrollView.setZoomScale(3, animated: false)
            XCTAssertEqual(canvas.convert(left.frame, to: controller.scrollView).width, left.frame.width * 3, accuracy: 0.01)
            XCTAssertEqual(canvas.convert(right.frame, to: controller.scrollView).width, right.frame.width * 3, accuracy: 0.01)
        }
    }

    func testIPadOriginalSpreadCentersAcrossTheFullViewport() {
        let viewport = CGSize(width: 1554, height: 1080)
        let pages = [
            ComicPage(id: "wide", kid: "wide", width: 900, height: 1000),
            ComicPage(id: "narrow", kid: "narrow", width: 700, height: 1000)
        ]
        for slots in [[1, 0], [nil, 0]] as [[Int?]] {
            let layout = ReaderCanvasLayout(pages: pages, viewport: viewport, mode: .spread(slots), landscapeSizing: .original)
            let artwork = layout.items.reduce(CGRect.null) { $0.union($1.frame) }
            XCTAssertEqual(layout.items.map(\.id), slots.compactMap { $0 })
            XCTAssertEqual(artwork.minX, viewport.width - artwork.maxX, accuracy: 0.01)
            XCTAssertEqual(artwork.minY, viewport.height - artwork.maxY, accuracy: 0.01)
            for item in layout.items {
                let page = pages[item.id]
                XCTAssertEqual(item.frame.width / item.frame.height, CGFloat(page.width) / CGFloat(page.height), accuracy: 0.001)
            }
        }
    }

    func testIPadFullScreenSpreadCoversBothAxesAndKeepsArtworkCentered() {
        let viewport = CGSize(width: 1554, height: 1080)
        let pages = [ComicPage(id: "page", kid: "page", width: 700, height: 1000)]
        let layout = ReaderCanvasLayout(pages: pages, viewport: viewport, mode: .spread([nil, 0]), landscapeSizing: .fullScreen)
        let frame = layout.items[0].frame
        XCTAssertGreaterThanOrEqual(frame.width + 0.01, viewport.width)
        XCTAssertGreaterThanOrEqual(frame.height + 0.01, viewport.height)
        XCTAssertEqual(frame.midX, viewport.width / 2, accuracy: 0.01)
        XCTAssertEqual(frame.midY, viewport.height / 2, accuracy: 0.01)
        XCTAssertEqual(frame.width / frame.height, 0.7, accuracy: 0.001)
    }

    func testPinchingStopsAtOriginalScaleInBothModes() {
        for mode in [ReaderCanvasMode.chapter, .spread([0, 1])] {
            let controller = makeController(mode: mode)
            controller.scrollView.setZoomScale(2, animated: false)
            controller.scrollView.setZoomScale(0.4, animated: false)
            XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
            XCTAssertFalse(controller.scrollView.bouncesZoom)
            XCTAssertEqual(controller.scrollView.panGestureRecognizer.isEnabled, mode.isChapter)
        }
    }

    func testZoomedLongStripStillScrollsAcrossPagesAndTracksProgress() {
        let controller = makeController(pageCount: 30)
        var reported = -1
        controller.onPageChange = { reported = $0 }
        controller.scrollView.setZoomScale(2, animated: false)
        let top = controller.layout.items[8].frame.minY * 2
        controller.scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        controller.scrollViewDidScroll(controller.scrollView)
        XCTAssertEqual(reported, 8)
        XCTAssertTrue(controller.renderedPages.contains(8))
        XCTAssertEqual(controller.scrollView.zoomScale, 2, accuracy: 0.001)
    }

    func testLongChapterInstallsOnlyVisibleAndNearbyImages() {
        let controller = makeController(pageCount: 100)
        XCTAssertLessThanOrEqual(controller.renderedPages.count, 4)
        controller.scrollView.setContentOffset(CGPoint(x: 0, y: controller.layout.items[50].frame.minY), animated: false)
        controller.scrollViewDidScroll(controller.scrollView)
        XCTAssertTrue(controller.renderedPages.contains(50))
        XCTAssertFalse(controller.renderedPages.contains(0))
        XCTAssertLessThanOrEqual(controller.renderedPages.count, 5)
    }

    func testProgressUpdatesKeepZoomAndExplicitJumpRestoresOriginalScale() {
        let controller = makeController(pageCount: 20)
        let requestID = UUID(), resetID = UUID()
        configure(controller, pageCount: 20, requestID: requestID, resetID: resetID)
        controller.scrollView.setZoomScale(2, animated: false)
        configure(controller, pageCount: 20, requestID: requestID, resetID: resetID)
        XCTAssertEqual(controller.scrollView.zoomScale, 2, accuracy: 0.001)
        configure(controller, pageCount: 20, target: 8, requestID: UUID(), resetID: UUID())
        XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset.y, controller.layout.items[8].frame.minY, accuracy: 0.01)
    }

    func testRotatingToSpreadResetsZoomAndKeepsOddLastPage() {
        let controller = makeController(pageCount: 5)
        controller.scrollView.setZoomScale(2, animated: false)
        controller.view.frame.size = CGSize(width: 640, height: 320)
        configure(controller, pageCount: 5, mode: .spread([nil, 4]))
        XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(controller.layout.items.map(\.id), [4])
        XCTAssertEqual(controller.layout.items.first?.frame.minX, 320)
        XCTAssertNil(controller.layout.footerFrame)
    }

    func testReaderControlsSitBelowDynamicIslandAndLegacySafeAreas() {
        XCTAssertEqual(ReaderChromePlacement.topPadding(safeAreaTop: 59, isPhone: true), 53)
        XCTAssertEqual(ReaderChromePlacement.topPadding(safeAreaTop: 62, isPhone: true), 56)
        XCTAssertEqual(ReaderChromePlacement.topPadding(safeAreaTop: 47, isPhone: true), 55)
        XCTAssertEqual(ReaderChromePlacement.topPadding(safeAreaTop: 0, isPhone: true), 8)
        XCTAssertEqual(ReaderChromePlacement.topPadding(safeAreaTop: 24, isPhone: false), 32)
    }

    private func makeController(pageCount: Int = 4, mode: ReaderCanvasMode = .chapter) -> ReaderCanvasController {
        let controller = ReaderCanvasController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        configure(controller, pageCount: pageCount, mode: mode)
        controller.view.layoutIfNeeded()
        return controller
    }
    private func configure(_ controller: ReaderCanvasController, pageCount: Int, mode: ReaderCanvasMode = .chapter,
                           target: Int = 0, requestID: UUID = UUID(), resetID: UUID = UUID()) {
        let pages = (0..<pageCount).map { ComicPage(id: "\($0)", kid: "\($0)", width: 640, height: 960) }
        controller.configure(pages: pages, scopeID: "chapter", mode: mode, targetPage: target,
            requestID: requestID, resetID: resetID, spacing: 8, footer: "下一话", renderPage: { _ in AnyView(Color.white) })
    }
}
