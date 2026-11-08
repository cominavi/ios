import XCTest

/// Runs only against a staging or local service with the test identity
/// provider enabled (see `XCUIApplication.configureTestSession`).
final class ComiNaviTestSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTestSessionSignsInThroughTheService() throws {
        let label = "ui-test-\(UUID().uuidString.prefix(8).lowercased())"
        let app = XCUIApplication()
        app.launchArguments = [
            "-cominavi-ui-testing-hide-debugger",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ] + XCUIApplication.initialTabArguments("profile")
        try app.configureTestSession(label: label)
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Test \(label)"].waitForExistence(timeout: 60),
            "the profile shows the test user"
        )
        let deleteAccount = app.buttons["profile-delete-account"]
        for _ in 0..<6 where !deleteAccount.exists {
            app.swipeUp()
        }
        XCTAssertTrue(deleteAccount.exists, "signed in with a profile")
    }
}
