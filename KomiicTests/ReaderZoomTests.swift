import XCTest
import UIKit
@testable import Komiic

@MainActor
final class ReaderZoomTests: XCTestCase {
    func testPinchingStopsAtOriginalSizeWithoutRubberBanding() {
        let view = makeView()
        view.setZoomScale(0.4, animated: false)
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.imageView.frame.size, view.bounds.size)
        XCTAssertFalse(view.bouncesZoom)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
    }

    func testZoomedPageCanPanAndReturningToOriginalSizeReleasesScrolling() {
        let view = makeView()
        view.setZoomScale(3, animated: false)
        XCTAssertEqual(view.zoomScale, 3, accuracy: 0.001)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        XCTAssertGreaterThan(view.contentSize.width, view.bounds.width)
        view.setContentOffset(CGPoint(x: 80, y: 120), animated: false)
        view.setZoomScale(0.5, animated: false)
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
    }

    func testSettingsUpdatesKeepZoomButPageNavigationResetsIt() {
        let view = makeView()
        let image = view.imageView.image!
        let resetID = UUID()
        view.update(image: image, resetID: resetID)
        view.setZoomScale(2, animated: false)
        view.update(image: image, resetID: resetID)
        XCTAssertEqual(view.zoomScale, 2, accuracy: 0.001)
        view.update(image: image, resetID: UUID())
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
    }

    func testRotationAndReplacingPageResetZoomAndFitNewBounds() {
        let view = makeView()
        view.setZoomScale(2, animated: false)
        view.frame.size = CGSize(width: 480, height: 320)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.imageView.frame.size, view.bounds.size)
        view.setZoomScale(2, animated: false)
        view.update(image: makeImage(), resetID: UUID())
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
    }

    func testNestedReaderAllowsSingleFingerPageTurnsAtOriginalSize() {
        let parent = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let view = makeView()
        parent.addSubview(view)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(parent.panGestureRecognizer.maximumNumberOfTouches, 1)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
        XCTAssertTrue(view.pinchGestureRecognizer?.isEnabled == true)
    }

    private func makeView() -> ReaderImageScrollView {
        let view = ReaderImageScrollView(frame: .zero)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.update(image: makeImage(), resetID: UUID())
        view.layoutIfNeeded()
        return view
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 960)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 960))
        }
    }
}
