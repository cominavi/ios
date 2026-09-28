import Foundation
import XCTest

@testable import ComiNavi

final class AppPowerPolicyTests: XCTestCase {
    @MainActor
    func testPowerStateNotificationUpdatesAndRestoresRenderingPolicy() {
        let source = StubPowerStateSource(isLowPowerModeEnabled: false)
        let notificationCenter = NotificationCenter()
        let policy = AppPowerPolicy(source: source, notificationCenter: notificationCenter)

        XCTAssertFalse(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 120)
        XCTAssertFalse(policy.suppressesNonessentialAnimation)
        XCTAssertFalse(policy.pausesNonessentialBackdrop)

        source.isLowPowerModeEnabled = true
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

        XCTAssertTrue(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 30)
        XCTAssertTrue(policy.suppressesNonessentialAnimation)
        XCTAssertTrue(policy.pausesNonessentialBackdrop)

        source.isLowPowerModeEnabled = false
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

        XCTAssertFalse(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 120)
        XCTAssertFalse(policy.suppressesNonessentialAnimation)
        XCTAssertFalse(policy.pausesNonessentialBackdrop)
    }

    func testConventionFloorBackdropPausesForEveryResourceSavingCondition() {
        XCTAssertFalse(
            ConventionFloorBackdropPolicy.shouldPause(
                accessibilityReduceMotion: false,
                isSceneActive: true,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertTrue(
            ConventionFloorBackdropPolicy.shouldPause(
                accessibilityReduceMotion: true,
                isSceneActive: true,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertTrue(
            ConventionFloorBackdropPolicy.shouldPause(
                accessibilityReduceMotion: false,
                isSceneActive: false,
                isLowPowerModeEnabled: false
            )
        )
        XCTAssertTrue(
            ConventionFloorBackdropPolicy.shouldPause(
                accessibilityReduceMotion: false,
                isSceneActive: true,
                isLowPowerModeEnabled: true
            )
        )
    }
}

@MainActor
private final class StubPowerStateSource: AppPowerStateProviding {
    var isLowPowerModeEnabled: Bool

    init(isLowPowerModeEnabled: Bool) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}
