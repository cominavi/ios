import CoreGraphics
import XCTest
@testable import ComiNavi

final class CircleFavoriteAppearanceTests: XCTestCase {
    func testFavoriteMarkMatchesOfficialCircleCutBox() {
        XCTAssertEqual(
            CircleFavoriteMarkGeometry.rect(in: CGSize(width: 211, height: 300)),
            CGRect(x: 7, y: 7, width: 48, height: 48)
        )
    }

    func testFavoriteMarkScalesWithRenderedArtwork() {
        let rect = CircleFavoriteMarkGeometry.rect(in: CGSize(width: 105.5, height: 150))

        XCTAssertEqual(rect.minX, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(rect.minY, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(rect.width, 24, accuracy: 0.000_001)
        XCTAssertEqual(rect.height, 24, accuracy: 0.000_001)
    }

    func testFavoriteMarkRejectsInvalidContainerGeometry() {
        XCTAssertEqual(CircleFavoriteMarkGeometry.rect(in: .zero), .zero)
    }

    func testMemoOnlyIsNotAFavoriteColor() {
        XCTAssertFalse(BookmarkColor.memoOnly.isFavorite)
        XCTAssertTrue(BookmarkColor.orange.isFavorite)
    }

    func testExploreArtworkOnlyOutlinesShinagakiFavorites() {
        XCTAssertEqual(
            ExploreArtworkBorderStyle.resolve(
                isShowingShinagaki: false,
                bookmarkColor: nil
            ),
            .none
        )
        XCTAssertEqual(
            ExploreArtworkBorderStyle.resolve(
                isShowingShinagaki: true,
                bookmarkColor: nil
            ),
            .none
        )
        XCTAssertEqual(
            ExploreArtworkBorderStyle.resolve(
                isShowingShinagaki: true,
                bookmarkColor: .memoOnly
            ),
            .none
        )
        XCTAssertEqual(
            ExploreArtworkBorderStyle.resolve(
                isShowingShinagaki: false,
                bookmarkColor: .magenta
            ),
            .none
        )
        XCTAssertEqual(
            ExploreArtworkBorderStyle.resolve(
                isShowingShinagaki: true,
                bookmarkColor: .magenta
            ),
            .favorite(.magenta)
        )
    }
}
