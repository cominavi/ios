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
}
