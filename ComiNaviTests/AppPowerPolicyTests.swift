import Foundation
import XCTest

@testable import ComiNavi

final class AppPowerPolicyTests: XCTestCase {
    @MainActor
    func testPowerStateNotificationUpdatesAndRestoresRenderingPolicy() async {
        let source = StubPowerStateSource(isLowPowerModeEnabled: false)
        let notificationCenter = NotificationCenter()
        let policy = AppPowerPolicy(source: source, notificationCenter: notificationCenter)

        XCTAssertFalse(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 120)
        XCTAssertNil(policy.mapFrameRateCap)
        XCTAssertFalse(policy.suppressesNonessentialAnimation)
        XCTAssertFalse(policy.pausesNonessentialBackdrop)

        source.isLowPowerModeEnabled = true
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await waitUntil { policy.isLowPowerModeEnabled }

        XCTAssertTrue(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 30)
        XCTAssertEqual(policy.mapFrameRateCap, 30)
        XCTAssertTrue(policy.suppressesNonessentialAnimation)
        XCTAssertTrue(policy.pausesNonessentialBackdrop)

        source.isLowPowerModeEnabled = false
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await waitUntil { !policy.isLowPowerModeEnabled }

        XCTAssertFalse(policy.isLowPowerModeEnabled)
        XCTAssertEqual(policy.preferredMapFramesPerSecond(maximum: 120), 120)
        XCTAssertNil(policy.mapFrameRateCap)
        XCTAssertFalse(policy.suppressesNonessentialAnimation)
        XCTAssertFalse(policy.pausesNonessentialBackdrop)
    }

    @MainActor
    func testPowerStateNotificationPostedOffTheMainThreadUpdatesThePolicy() async {
        let source = StubPowerStateSource(isLowPowerModeEnabled: false)
        let notificationCenter = NotificationCenter()
        let policy = AppPowerPolicy(source: source, notificationCenter: notificationCenter)

        // The system posts power-state notifications on a global queue.
        source.isLowPowerModeEnabled = true
        await Task.detached {
            notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }.value
        await waitUntil { policy.isLowPowerModeEnabled }
        XCTAssertEqual(policy.mapFrameRateCap, 30)

        source.isLowPowerModeEnabled = false
        await Task.detached {
            notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }.value
        await waitUntil { !policy.isLowPowerModeEnabled }
        XCTAssertNil(policy.mapFrameRateCap)
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The power policy did not update", file: file, line: line)
    }
}

@MainActor
private final class StubPowerStateSource: AppPowerStateProviding {
    var isLowPowerModeEnabled: Bool

    init(isLowPowerModeEnabled: Bool) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}
