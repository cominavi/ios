@testable import ComiNavi
import XCTest

final class AccountDeletionConfirmationFlowTests: XCTestCase {
    func testFirstCountdownUnlocksNextWithoutAdvancing() {
        var flow = AccountDeletionConfirmationFlow()

        XCTAssertEqual(flow.step, .accountSeparation)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.canContinue)
        XCTAssertFalse(flow.canDelete)

        for _ in 1 ..< AccountDeletionConfirmationFlow.countdownDuration {
            flow.tick()
            XCTAssertEqual(flow.step, .accountSeparation)
            XCTAssertFalse(flow.canContinue)
        }

        flow.tick()

        XCTAssertEqual(flow.step, .accountSeparation)
        XCTAssertEqual(flow.secondsRemaining, 0)
        XCTAssertTrue(flow.canContinue)
        XCTAssertFalse(flow.canDelete)
    }

    func testNextRequiresFirstCountdownAndStartsSecondCountdown() {
        var flow = AccountDeletionConfirmationFlow()

        XCTAssertFalse(flow.continueToConsequences())
        advanceCountdown(&flow)
        XCTAssertTrue(flow.continueToConsequences())

        XCTAssertEqual(flow.step, .consequences)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.canContinue)
        XCTAssertFalse(flow.canDelete)
    }

    func testSecondCountdownUnlocksDeleteWithoutOpeningConfirmation() {
        var flow = AccountDeletionConfirmationFlow()
        advanceCountdown(&flow)
        XCTAssertTrue(flow.continueToConsequences())

        for _ in 1 ..< AccountDeletionConfirmationFlow.countdownDuration {
            flow.tick()
            XCTAssertEqual(flow.step, .consequences)
            XCTAssertFalse(flow.canDelete)
        }

        flow.tick()

        XCTAssertEqual(flow.step, .consequences)
        XCTAssertEqual(flow.secondsRemaining, 0)
        XCTAssertTrue(flow.canDelete)
        flow.tick()
        XCTAssertEqual(flow.secondsRemaining, 0)
    }

    func testReturningToExplanationRestartsBothSafetyGates() {
        var flow = AccountDeletionConfirmationFlow()
        advanceCountdown(&flow)
        XCTAssertTrue(flow.continueToConsequences())
        advanceCountdown(&flow)
        XCTAssertTrue(flow.canDelete)

        flow.returnToAccountSeparation()

        XCTAssertEqual(flow.step, .accountSeparation)
        XCTAssertEqual(
            flow.secondsRemaining,
            AccountDeletionConfirmationFlow.countdownDuration
        )
        XCTAssertFalse(flow.canContinue)
        XCTAssertFalse(flow.canDelete)
    }

    private func advanceCountdown(_ flow: inout AccountDeletionConfirmationFlow) {
        for _ in 0 ..< AccountDeletionConfirmationFlow.countdownDuration {
            flow.tick()
        }
    }
}
