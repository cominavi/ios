import XCTest
@testable import ComiNavi

final class LucideIconTests: XCTestCase {
    @MainActor
    func testEveryPrimaryTabIconResolvesToBundledArtwork() {
        for icon in ["map", "safari", "list-checks", "person.circle"] {
            XCTAssertNotNil(
                LucideIcon.uiImage(for: icon),
                "Primary tab icon '\(icon)' is missing from Assets.xcassets"
            )
        }
    }

    @MainActor
    func testLatestShinagakiSortIconResolvesToBundledArtwork() {
        XCTAssertEqual(LucideIcon.assetName(for: "clock.badge"), "lucide-clock")
        XCTAssertNotNil(
            LucideIcon.uiImage(for: "clock.badge"),
            "Latest shinagaki sort icon is missing from Assets.xcassets"
        )
    }

    @MainActor
    func testExternalBrandIconsResolveToBundledArtwork() {
        for icon in ["x", "pixiv"] {
            XCTAssertNotNil(
                IconifyBrandIcon.uiImage(for: icon),
                "External brand icon '\(icon)' is missing from Assets.xcassets"
            )
        }
    }
}
