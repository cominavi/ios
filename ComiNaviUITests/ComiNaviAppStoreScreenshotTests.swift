import XCTest

/// Deterministic Japanese captures for App Store Connect.
///
/// Run these tests sequentially on an App Store-supported simulator, then
/// export the kept attachments from the resulting xcresult bundle.
final class ComiNaviAppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test01MapCampus() throws {
        let app = launchJapaneseDemo()

        XCTAssertTrue(app.buttons["global-event-day-banner"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.otherElements["campus-map-canvas"].waitForExistence(timeout: 20))
        waitForRenderingToSettle()

        capture(named: "ja-01-map-campus")
    }

    @MainActor
    func test02ExploreGallery() throws {
        let app = launchJapaneseDemo()

        // iPad's floating tab bar exposes a wrapper and its cell with the same
        // localized label. Either points at the same control.
        let exploreTab = app.buttons["探す"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 30))
        exploreTab.tap()

        XCTAssertTrue(app.otherElements["explore-screen"].waitForExistence(timeout: 10))
        let gallery = app.collectionViews["explore-gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(gallery.cells.count, 0)
        let discoveryLoading = app.otherElements["explore-discovery-loading"]
        if discoveryLoading.exists {
            expectation(
                for: NSPredicate(format: "exists == false"),
                evaluatedWith: discoveryLoading
            )
            waitForExpectations(timeout: 30)
        }
        waitForRenderingToSettle()

        capture(named: "ja-02-explore-gallery")
    }

    @MainActor
    func test03WhereAmI() throws {
        let app = launchJapaneseDemo(additionalArguments: ["-cominavi-ui-testing-where-am-i"])

        let entryButton = app.buttons["where-am-i-button"]
        XCTAssertTrue(entryButton.waitForExistence(timeout: 30))
        entryButton.tap()

        let manualMode = app.buttons["location-mode-manual"]
        XCTAssertTrue(manualMode.waitForExistence(timeout: 5))
        manualMode.tap()

        XCTAssertTrue(app.buttons["where-am-i-venue-1"].waitForExistence(timeout: 10))
        waitForRenderingToSettle()

        capture(named: "ja-03-where-am-i")
    }

    @MainActor
    private func launchJapaneseDemo(additionalArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-cominavi-demo-data",
        ] + additionalArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    @MainActor
    private func waitForRenderingToSettle() {
        let expectation = expectation(description: "Rendering settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 4)
    }

    @MainActor
    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
