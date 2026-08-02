import CoreGraphics
import XCTest
@testable import ComiNavi

final class CircleArtworkGeometryTests: XCTestCase {
    private let c104CutSize = CGSize(width: 180, height: 256)

    func testPortraitCutPreservesDecodedAspectRatioOnHorizontalTable() {
        let geometry = CatalogCircleArtworkGeometry.fitting(
            pixelSize: c104CutSize,
            in: CGSize(width: 20, height: 40),
            orientation: .aLeft
        )

        XCTAssertEqual(geometry.imageSize.width / geometry.imageSize.height, 180.0 / 256.0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.imageSize.width, 18, accuracy: 0.000_001)
        XCTAssertEqual(geometry.imageSize.height, 25.6, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayedBoundsSize, geometry.imageSize)
    }

    func testPortraitCutFitsAfterQuarterTurnOnVerticalTable() {
        let geometry = CatalogCircleArtworkGeometry.fitting(
            pixelSize: c104CutSize,
            in: CGSize(width: 40, height: 20),
            orientation: .aBottom
        )

        XCTAssertEqual(geometry.imageSize.width / geometry.imageSize.height, 180.0 / 256.0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayedBoundsSize.width, 25.6, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayedBoundsSize.height, 18, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(geometry.displayedBoundsSize.width, 40)
        XCTAssertLessThanOrEqual(geometry.displayedBoundsSize.height, 20)
    }

    func testTableOrientationsComposeExpectedQuarterTurns() {
        XCTAssertEqual(geometry(for: .aLeft).rotation, 0, accuracy: 0.000_001)
        XCTAssertEqual(geometry(for: .aBottom).rotation, -.pi / 2, accuracy: 0.000_001)
        XCTAssertEqual(geometry(for: .aRight).rotation, .pi, accuracy: 0.000_001)
        XCTAssertEqual(geometry(for: .aTop).rotation, .pi / 2, accuracy: 0.000_001)
    }

    func testLandscapeImageUsesItsOwnDecodedRatio() {
        let geometry = CatalogCircleArtworkGeometry.fitting(
            pixelSize: CGSize(width: 300, height: 180),
            in: CGSize(width: 20, height: 40),
            orientation: .aRight
        )

        XCTAssertEqual(geometry.imageSize.width / geometry.imageSize.height, 300.0 / 180.0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayedBoundsSize.width, 18, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayedBoundsSize.height, 10.8, accuracy: 0.000_001)
    }

    private func geometry(for orientation: CatalogMapTable.Orientation) -> CatalogCircleArtworkGeometry {
        CatalogCircleArtworkGeometry.fitting(
            pixelSize: c104CutSize,
            in: CGSize(width: 40, height: 40),
            orientation: orientation
        )
    }
}
