import XCTest

@testable import ComiNavi

@MainActor
final class AppHapticFeedbackTests: XCTestCase {
    func testRepeatedIdenticalCuesProduceDistinctEvents() {
        let feedback = AppHapticFeedback()

        feedback.play(.copyConfirmation)
        let first = feedback.event
        feedback.play(.copyConfirmation)
        let second = feedback.event

        XCTAssertEqual(first.cue, .copyConfirmation)
        XCTAssertEqual(second.cue, .copyConfirmation)
        XCTAssertEqual(second.sequence, first.sequence + 1)
        XCTAssertNotEqual(first, second)
    }

    func testEventRetainsTheLatestSemanticCue() {
        let feedback = AppHapticFeedback()

        feedback.play(.completion)
        feedback.play(.error)

        XCTAssertEqual(feedback.event.cue, .error)
        XCTAssertEqual(feedback.event.sequence, 2)
    }
}
