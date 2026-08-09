import CoreGraphics
import XCTest
@testable import ComiNavi

final class CircleFavoriteAppearanceTests: XCTestCase {
    func testFavoriteMarkMatchesOfficialCircleCutBox() {
        XCTAssertEqual(
            CircleFavoriteMarkGeometry.rect(in: CGSize(width: 211, height: 300)),
            CGRect(x: 8, y: 8, width: 46, height: 46)
        )
    }

    func testFavoriteMarkScalesWithRenderedArtwork() {
        let rect = CircleFavoriteMarkGeometry.rect(in: CGSize(width: 105.5, height: 150))

        XCTAssertEqual(rect.minX, 4, accuracy: 0.000_001)
        XCTAssertEqual(rect.minY, 4, accuracy: 0.000_001)
        XCTAssertEqual(rect.width, 23, accuracy: 0.000_001)
        XCTAssertEqual(rect.height, 23, accuracy: 0.000_001)
    }

    func testFavoriteMarkRejectsInvalidContainerGeometry() {
        XCTAssertEqual(CircleFavoriteMarkGeometry.rect(in: .zero), .zero)
    }
}
