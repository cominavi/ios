@testable import ComiNavi
import Foundation
import XCTest

final class FeatureOnboardingStoreTests: XCTestCase {
    func testCompletionPersistsWithoutAffectingOtherOnboardingFlows() throws {
        let suiteName = "FeatureOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureOnboardingStore(defaults: defaults)
        let sharedPlansOnboarding = FeatureOnboardingID(
            rawValue: "shared-plans-collaboration-v1"
        )

        XCTAssertTrue(store.shouldPresent(.exploreGalleryZoom))
        XCTAssertTrue(store.shouldPresent(.gpsLocationModeWarning))
        XCTAssertTrue(store.shouldPresent(sharedPlansOnboarding))

        store.markCompleted(.exploreGalleryZoom)

        XCTAssertFalse(store.shouldPresent(.exploreGalleryZoom))
        XCTAssertTrue(store.shouldPresent(.gpsLocationModeWarning))
        XCTAssertTrue(store.shouldPresent(sharedPlansOnboarding))

        store.markCompleted(.gpsLocationModeWarning)

        XCTAssertFalse(store.shouldPresent(.gpsLocationModeWarning))
        XCTAssertFalse(store.shouldPresent(.exploreGalleryZoom))
        XCTAssertTrue(store.shouldPresent(sharedPlansOnboarding))

        store.reset(.gpsLocationModeWarning)

        XCTAssertTrue(store.shouldPresent(.gpsLocationModeWarning))
        XCTAssertFalse(store.shouldPresent(.exploreGalleryZoom))
    }
}
