@testable import ComiNavi
import XCTest

final class AccountDeletionConfirmationFlowTests: XCTestCase {
    func testFirstCountdownAdvancesToConsequencesWithoutAllowingDeletion() {
        var flow = AccountDeletionConfirmationFlow()

        XCTAssertEqual(flow.step, .accountSeparation)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.isFinalConfirmationAvailable)

        for _ in 1 ..< AccountDeletionConfirmationFlow.countdownDuration {
            XCTAssertNil(flow.tick())
            XCTAssertEqual(flow.step, .accountSeparation)
            XCTAssertFalse(flow.isFinalConfirmationAvailable)
        }

        XCTAssertEqual(flow.tick(), .showConsequences)
        XCTAssertEqual(flow.step, .consequences)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.isFinalConfirmationAvailable)
    }

    func testSecondCountdownMakesOnlySystemConfirmationAvailable() {
        var flow = AccountDeletionConfirmationFlow()
        advanceCountdown(&flow)

        for _ in 1 ..< AccountDeletionConfirmationFlow.countdownDuration {
            XCTAssertNil(flow.tick())
            XCTAssertFalse(flow.isFinalConfirmationAvailable)
        }

        XCTAssertEqual(flow.tick(), .showSystemConfirmation)
        XCTAssertEqual(flow.step, .consequences)
        XCTAssertEqual(flow.secondsRemaining, 0)
        XCTAssertTrue(flow.isFinalConfirmationAvailable)
        XCTAssertNil(flow.tick())
    }

    func testReturningToExplanationRestartsBothSafetyGates() {
        var flow = AccountDeletionConfirmationFlow()
        advanceCountdown(&flow)
        advanceCountdown(&flow)
        XCTAssertTrue(flow.isFinalConfirmationAvailable)

        flow.returnToAccountSeparation()

        XCTAssertEqual(flow.step, .accountSeparation)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.isFinalConfirmationAvailable)
    }

    private func advanceCountdown(_ flow: inout AccountDeletionConfirmationFlow) {
        for _ in 0 ..< AccountDeletionConfirmationFlow.countdownDuration {
            _ = flow.tick()
        }
    }
}
