import XCTest

extension XCUIApplication {
    /// The button that closes the front sheet: a "Done" confirmation or a
    /// "Close" button. Sheets moved from "Done" titles to symbol close
    /// buttons during the UX overhaul; both keep one of these accessibility
    /// labels. The query does not require a navigation bar, because iPhone
    /// Duo shows vertical bars.
    var sheetCloseButton: XCUIElement {
        buttons.matching(
            NSPredicate(
                format: "label IN %@ OR identifier ENDSWITH %@",
                ["Done", "Close"],
                "-close"
            )
        )
        .firstMatch
    }

    /// Launch arguments that open the app on one tab without a tap.
    static func initialTabArguments(_ tab: String) -> [String] {
        ["-cominavi-ui-testing-initial-tab", tab]
    }
}
