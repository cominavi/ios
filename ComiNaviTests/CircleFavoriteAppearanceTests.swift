import CoreGraphics
import SwiftUI
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

    @MainActor
    func testFavoriteColorLabelBadgeUsesCircleWithoutCustomLabel() throws {
        let unlabeledSize = try renderedSize(
            FavoriteColorLabelBadge(color: .blue, label: nil)
        )
        let whitespaceSize = try renderedSize(
            FavoriteColorLabelBadge(color: .blue, label: "   ")
        )

        XCTAssertEqual(
            unlabeledSize.width,
            FavoriteColorLabelMetrics.baseHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(unlabeledSize, whitespaceSize)
    }

    @MainActor
    func testFavoriteColorLabelPillMatchesCircleHeightAndExpandsHorizontally() throws {
        let circleSize = try renderedSize(
            FavoriteColorLabelBadge(color: .blue, label: nil)
        )
        let pillSize = try renderedSize(
            FavoriteColorLabelBadge(color: .blue, label: "Must visit")
        )

        XCTAssertEqual(pillSize.height, circleSize.height, accuracy: 0.5)
        XCTAssertGreaterThan(pillSize.width, circleSize.width)
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

    @MainActor
    private func renderedSize<Content: View>(_ content: Content) throws -> CGSize {
        let renderer = ImageRenderer(content: content.fixedSize())
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage).size
    }
}
