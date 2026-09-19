import XCTest
import UIKit

/// Exercises the same screens while their window changes size; no device-name checks.
final class ComiNaviAdaptiveLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-cominavi-ui-testing-hide-debugger",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[name]
    }

    @MainActor
    func testPrimaryScreensAndSearchRetainStateAcrossRotation() throws {
        let app = launch(["-cominavi-demo-data"])
        defer { XCUIDevice.shared.orientation = .portrait }
        let day = app.buttons["global-event-day-banner"]
        XCTAssertTrue(day.waitForExistence(timeout: 40))
        XCTAssertTrue(app.otherElements["unified-map-canvas"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Shared Plan could not be updated"].exists)
        capture(app, "duo-map-portrait")
        day.tap()
        let dayTwo = app.buttons["global-day-2"]
        XCTAssertTrue(dayTwo.waitForExistence(timeout: 5))
        dayTwo.tap()
        app.buttons["catalog-settings-done"].tap()
        XCTAssertTrue(day.label.contains("Day 2"))

        tab("Explore", in: app).tap()
        let search = app.textFields["explore-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        capture(app, "duo-explore-portrait")
        search.tap()
        search.typeText("duo continuity")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(search.value as? String, "duo continuity")
        XCTAssertTrue(day.label.contains("Day 2"))
        XCTAssertTrue(app.buttons["explore-filter-button"].isHittable)
        capture(app, "duo-explore-search-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(search.value as? String, "duo continuity")

        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tab("Profile", in: app).tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        capture(app, "duo-profile-portrait")
        tab("Shared Plans", in: app).tap()
        XCTAssertTrue(tab("Shared Plans", in: app).isSelected)
        capture(app, "duo-plans-portrait")
        tab("Map", in: app).tap()
        XCTAssertTrue(day.label.contains("Day 2"))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.buttons["where-am-i-button"].isHittable)
        XCTAssertTrue(app.buttons["find-table-button"].isHittable)
        capture(app, "duo-map-landscape")
    }

    @MainActor
    func testLightboxRetainsPageAndReachableControlsAcrossRotation() throws {
        let app = launch(["-cominavi-ui-testing-shinagaki-lightbox-cancel-save"])
        defer { XCUIDevice.shared.orientation = .portrait }
        let first = app.images["Test Shinagaki page 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.collectionViews["shinagaki-lightbox"].swipeLeft()
        let second = app.images["Test Shinagaki page 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(second.isHittable)
            for id in ["shinagaki-lightbox-close", "shinagaki-lightbox-share", "shinagaki-lightbox-save"] {
                let button = app.buttons[id]
                let reachable = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"), object: button
                )
                XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, id)
                XCTAssertTrue(app.frame.contains(button.frame), "Control outside the viewport: \(id)")
            }
            capture(app, "duo-lightbox-\(orientation.rawValue)")
        }
        app.buttons["shinagaki-lightbox-close"].tap()
        XCTAssertTrue(app.staticTexts["shinagaki-test-lightbox-dismissed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shinagaki-lightbox-close"].exists)
    }

    @MainActor
    func testAccessibilityPurchaseRowsKeepNamesAndActionsUsable() throws {
        let app = launch([
            "-cominavi-ui-testing-shared-plan-purchases",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let surface = app.descendants(matching: .any)["shared-plan-purchase-test-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let title = app.staticTexts["Purchases"]
        XCTAssertGreaterThan(title.frame.width, 180)
        XCTAssertLessThan(title.frame.height, 90, "The heading must not wrap into syllables")
        let name = app.staticTexts["新刊セット"].firstMatch
        XCTAssertGreaterThan(name.frame.width, 180, "Accessible item names need the row's full width")
        capture(app, "duo-purchases-accessibility")
        let progress = app.buttons["shared-plan-editor-need-progress-10000000-0000-4000-8000-000000000001"]
        for _ in 0..<4 {
            if progress.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(progress.isHittable)
        progress.tap()
        XCTAssertTrue(app.navigationBars["Purchase progress"].waitForExistence(timeout: 5))
        let requested = app.steppers["Requested, 2"]
        for _ in 0..<4 where !requested.exists {
            app.swipeUp()
        }
        XCTAssertTrue(requested.exists)
        let bought = app.steppers["Bought, 0"]
        let increment = bought.buttons["Increment"]
        for _ in 0..<4 {
            if increment.exists && increment.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(increment.isHittable)
        increment.tap()
        XCTAssertTrue(app.steppers["Bought, 1"].exists)
        capture(app, "duo-purchase-progress-accessibility")
        app.buttons["Done"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
    }
}
