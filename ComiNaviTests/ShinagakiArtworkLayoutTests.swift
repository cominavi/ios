import XCTest
import UIKit
@testable import ComiNavi

final class ShinagakiArtworkLayoutTests: XCTestCase {
    func testDefaultPreviewAspectRatioMatchesPortraitA4() {
        XCTAssertEqual(
            ShinagakiArtworkLayout.a4PortraitAspectRatio,
            210.0 / 297.0,
            accuracy: 0.000_001
        )
    }

    func testMinimumZoomScaleFitsWholeImageInsideViewport() {
        XCTAssertEqual(
            ShinagakiArtworkLayout.minimumZoomScale(
                imageSize: CGSize(width: 210, height: 297),
                viewportSize: CGSize(width: 390, height: 844)
            ),
            390.0 / 210.0,
            accuracy: 0.000_001
        )
    }

    func testMinimumZoomScaleUsesWidthForWideImages() {
        XCTAssertEqual(
            ShinagakiArtworkLayout.minimumZoomScale(
                imageSize: CGSize(width: 1_200, height: 600),
                viewportSize: CGSize(width: 390, height: 844)
            ),
            390.0 / 1_200.0,
            accuracy: 0.000_001
        )
    }

    func testMinimumZoomScaleRejectsInvalidGeometry() {
        XCTAssertEqual(
            ShinagakiArtworkLayout.minimumZoomScale(
                imageSize: .zero,
                viewportSize: CGSize(width: 390, height: 844)
            ),
            1
        )
    }

    func testDoubleTapZoomsInThenReturnsToFittedScale() {
        XCTAssertEqual(
            ShinagakiArtworkLayout.doubleTapTargetScale(
                currentScale: 2,
                minimumScale: 2,
                maximumScale: 12
            ),
            5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ShinagakiArtworkLayout.doubleTapTargetScale(
                currentScale: 5,
                minimumScale: 2,
                maximumScale: 12
            ),
            2,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testRotatedImageUsesItsLogicalOrientationAwareSize() throws {
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 120, height: 60)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        let sourceCGImage = try XCTUnwrap(source.cgImage)
        let rotatedImage = UIImage(
            cgImage: sourceCGImage,
            scale: source.scale,
            orientation: .right
        )
        let viewportSize = CGSize(width: 300, height: 500)
        let scrollView = ShinagakiZoomScrollView(
            frame: CGRect(origin: .zero, size: viewportSize)
        )

        scrollView.configure(
            image: rotatedImage,
            accessibilityLabel: "Rotated artwork"
        )
        scrollView.layoutIfNeeded()

        XCTAssertEqual(
            scrollView.minimumZoomScale,
            ShinagakiArtworkLayout.minimumZoomScale(
                imageSize: rotatedImage.size,
                viewportSize: viewportSize
            ),
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testAnimatedDoubleTapKeepsTheTappedPointAtViewportCenter() async throws {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 210, height: 297)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 210, height: 297))
        }
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: viewport)
        let viewController = UIViewController()
        let scrollView = ShinagakiZoomScrollView(frame: viewport)
        window.rootViewController = viewController
        viewController.view.addSubview(scrollView)
        window.isHidden = false
        defer { window.isHidden = true }

        scrollView.configure(image: image, accessibilityLabel: "Animated artwork")
        scrollView.layoutIfNeeded()
        let zoomImageView = try XCTUnwrap(scrollView.subviews.first(where: {
            $0.accessibilityIdentifier == "shinagaki-zoom-image"
        }))
        let tappedImagePoint = CGPoint(x: 140, y: 180)

        scrollView.toggleZoom(at: tappedImagePoint, animated: true)
        try await Task.sleep(for: .milliseconds(600))

        let tappedViewportPoint = scrollView.convert(
            tappedImagePoint,
            from: zoomImageView
        )
        XCTAssertEqual(tappedViewportPoint.x, scrollView.bounds.midX, accuracy: 1)
        XCTAssertEqual(tappedViewportPoint.y, scrollView.bounds.midY, accuracy: 1)
    }

    @MainActor
    func testNativeZoomViewStartsFittedAndAllowsSixTimesZoom() throws {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 210, height: 297)
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 210, height: 297))
        }
        let scrollView = ShinagakiZoomScrollView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )

        scrollView.configure(image: image, accessibilityLabel: "Test artwork")
        scrollView.layoutIfNeeded()

        let fittedScale = 390.0 / 210.0
        XCTAssertEqual(scrollView.minimumZoomScale, fittedScale, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.zoomScale, fittedScale, accuracy: 0.000_001)
        let zoomImageView = try XCTUnwrap(scrollView.subviews.first(where: {
            $0.accessibilityIdentifier == "shinagaki-zoom-image"
        }))
        let fittedAccessibilityValue = zoomImageView.accessibilityValue
        XCTAssertNotNil(fittedAccessibilityValue)
        XCTAssertEqual(
            scrollView.maximumZoomScale,
            fittedScale * 6,
            accuracy: 0.000_001
        )
        XCTAssertTrue(scrollView.pinchGestureRecognizer?.isEnabled == true)
        XCTAssertTrue(
            scrollView.gestureRecognizers?.contains { recognizer in
                guard let tap = recognizer as? UITapGestureRecognizer else { return false }
                return tap.numberOfTapsRequired == 2
            } == true
        )

        let tappedImagePoint = CGPoint(x: 140, y: 180)
        scrollView.toggleZoom(
            at: tappedImagePoint,
            animated: false
        )
        XCTAssertEqual(
            scrollView.zoomScale,
            fittedScale * ShinagakiArtworkLayout.doubleTapZoomMultiplier,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(scrollView.contentOffset.x, 0)
        XCTAssertNotEqual(
            zoomImageView.accessibilityValue,
            fittedAccessibilityValue
        )
        let tappedViewportPoint = scrollView.convert(
            tappedImagePoint,
            from: zoomImageView
        )
        XCTAssertEqual(tappedViewportPoint.x, scrollView.bounds.midX, accuracy: 1)
        XCTAssertEqual(tappedViewportPoint.y, scrollView.bounds.midY, accuracy: 1)

        scrollView.toggleZoom(
            at: tappedImagePoint,
            animated: false
        )
        XCTAssertEqual(scrollView.zoomScale, fittedScale, accuracy: 0.000_001)
        XCTAssertEqual(
            zoomImageView.accessibilityValue,
            fittedAccessibilityValue
        )
        let fittedImageCenter = scrollView.convert(
            CGPoint(x: zoomImageView.bounds.midX, y: zoomImageView.bounds.midY),
            from: zoomImageView
        )
        XCTAssertEqual(fittedImageCenter.x, scrollView.bounds.midX, accuracy: 1)
        XCTAssertEqual(fittedImageCenter.y, scrollView.bounds.midY, accuracy: 1)
    }
}
