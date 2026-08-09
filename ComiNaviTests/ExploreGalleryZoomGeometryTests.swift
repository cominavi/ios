import XCTest
@testable import ComiNavi

final class ExploreGalleryZoomGeometryTests: XCTestCase {
    @MainActor
    func testCollectionReportsInitialAndSubsequentBoundsSizes() async {
        let collectionView = ExploreTouchCancellingCollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 600),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        var callbackCount = 0
        collectionView.onBoundsSizeChange = {
            callbackCount += 1
        }

        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        await Task.yield()
        XCTAssertEqual(callbackCount, 1)

        collectionView.frame.size = CGSize(width: 600, height: 320)
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        await Task.yield()

        XCTAssertEqual(callbackCount, 2)
    }

    func testMagnificationChangesDensityInTheExpectedDirection() {
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.columns(initialColumns: 2, magnification: 2),
            1
        )
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.columns(initialColumns: 2, magnification: 0.4),
            5
        )
        XCTAssertEqual(ExploreGalleryZoomGeometry.nearestColumnLevel(to: 4.6), 5)
        XCTAssertEqual(ExploreGalleryZoomGeometry.nearestColumnLevel(to: 2.6), 3)
    }

    func testInitialDensityAdaptsToEffectiveContainerWidth() {
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.preferredInitialColumnCount(for: 390),
            2
        )
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.preferredInitialColumnCount(for: 744),
            3
        )
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.preferredInitialColumnCount(for: 1_366),
            4
        )
    }

    func testPlaceholderPhaseKeepsTheAnchoredItemInItsTargetColumn() {
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.leadingPlaceholderCount(
                aligningItemAtIndex: 7,
                with: 2,
                columns: 5
            ),
            0
        )
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.leadingPlaceholderCount(
                aligningItemAtIndex: 7,
                with: 3,
                columns: 5
            ),
            1
        )
        XCTAssertEqual(
            ExploreGalleryZoomGeometry.leadingPlaceholderCount(
                aligningItemAtIndex: 8,
                with: 2,
                columns: 5
            ),
            4
        )
    }

    func testAnchoredOffsetKeepsTheSamePointUnderTheGestureOrigin() {
        let itemFrame = CGRect(x: 180, y: 760, width: 120, height: 230)
        let itemUnitPoint = CGPoint(x: 0.25, y: 0.7)
        let viewportPoint = CGPoint(x: 210, y: 390)

        let offset = ExploreGalleryZoomGeometry.anchoredContentOffset(
            itemFrame: itemFrame,
            itemUnitPoint: itemUnitPoint,
            viewportPoint: viewportPoint,
            contentSize: CGSize(width: 390, height: 4_000),
            viewportSize: CGSize(width: 390, height: 760),
            adjustedInsets: .zero
        )

        let anchoredContentPoint = CGPoint(
            x: itemFrame.minX + itemFrame.width * itemUnitPoint.x,
            y: itemFrame.minY + itemFrame.height * itemUnitPoint.y
        )
        XCTAssertEqual(anchoredContentPoint.x - offset.x, viewportPoint.x, accuracy: 0.000_1)
        XCTAssertEqual(anchoredContentPoint.y - offset.y, viewportPoint.y, accuracy: 0.000_1)
    }

    func testAnchoredOffsetClampsAtScrollableEdges() {
        let topOffset = ExploreGalleryZoomGeometry.anchoredContentOffset(
            itemFrame: CGRect(x: 16, y: 10, width: 170, height: 300),
            itemUnitPoint: .zero,
            viewportPoint: CGPoint(x: 100, y: 400),
            contentSize: CGSize(width: 390, height: 2_000),
            viewportSize: CGSize(width: 390, height: 760),
            adjustedInsets: UIEdgeInsets(top: 12, left: 0, bottom: 28, right: 0)
        )
        XCTAssertEqual(topOffset.y, -12)

        let bottomOffset = ExploreGalleryZoomGeometry.anchoredContentOffset(
            itemFrame: CGRect(x: 16, y: 1_900, width: 170, height: 300),
            itemUnitPoint: CGPoint(x: 1, y: 1),
            viewportPoint: CGPoint(x: 100, y: 200),
            contentSize: CGSize(width: 390, height: 2_200),
            viewportSize: CGSize(width: 390, height: 760),
            adjustedInsets: UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        )
        XCTAssertEqual(bottomOffset.y, 1_468)
    }

    func testGesturePointIsClampedInsideItsItem() {
        let frame = CGRect(x: 40, y: 80, width: 100, height: 200)

        XCTAssertEqual(
            ExploreGalleryZoomGeometry.unitPoint(
                in: frame,
                at: CGPoint(x: -20, y: 400)
            ),
            CGPoint(x: 0, y: 1)
        )
    }
}
