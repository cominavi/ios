import AuthenticationServices
import XCTest
@testable import ComiNavi

final class SpecialEntryAuthenticationStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 4_000_000_000)

    private func coordinators(
        google googleStorage: InMemoryGoogleAuthenticationFlowStore,
        apple appleStorage: InMemoryAppleAuthenticationFlowStore
    ) -> (GoogleAuthenticationFlowCoordinator, AppleAuthenticationFlowCoordinator) {
        (
            GoogleAuthenticationFlowCoordinator(
                storage: googleStorage,
                makeRequestID: { UUID() },
                makeNonce: { String(repeating: "g", count: 43) }
            ),
            AppleAuthenticationFlowCoordinator(
                storage: appleStorage,
                makeRequestID: { UUID() },
                makeNonce: { String(repeating: "a", count: 43) }
            )
        )
    }

    /// Google link opened → Apple sign-in succeeds → relaunch: the person
    /// stays signed in instead of returning to the special-entry screen.
    func testAppleSignInAfterGoogleLinkStaysSignedInAcrossRelaunch() throws {
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let (google, apple) = coordinators(google: googleStorage, apple: appleStorage)

        // `cominavi://auth/google` saves a Google flow before a provider is picked.
        _ = try google.prepare(entryContext: .special, now: now)
        // The person picks Apple instead. A successful Apple sign-in clears
        // its own flow, and the verified profile retires the rest.
        _ = try apple.prepare(entryContext: .special, now: now)
        try apple.clear()
        try SpecialEntryAuthenticationState.retireUnsubmittedFlows(
            google: google,
            apple: apple,
            now: now
        )

        // Relaunch a minute later, inside the Google flow's one-hour lifetime.
        let (relaunchedGoogle, relaunchedApple) = coordinators(
            google: googleStorage,
            apple: appleStorage
        )
        let later = now.addingTimeInterval(60)
        let googleFlow = try relaunchedGoogle.load(now: later)
        let appleFlow = try relaunchedApple.load(now: later)
        XCTAssertNil(googleFlow)
        XCTAssertNil(appleFlow)
        XCTAssertFalse(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: true,
            googleFlow: googleFlow,
            appleFlow: appleFlow
        ))
    }

    func testVerifiedProfileWinsOverLeftoverSpecialEntryFlow() throws {
        let (google, _) = coordinators(
            google: InMemoryGoogleAuthenticationFlowStore(),
            apple: InMemoryAppleAuthenticationFlowStore()
        )
        let leftover = try google.prepare(entryContext: .special, now: now)

        XCTAssertFalse(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: true,
            googleFlow: leftover,
            appleFlow: nil
        ))
        XCTAssertTrue(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: leftover,
            appleFlow: nil
        ))
    }

    func testOnlySpecialEntryFlowsRestoreTheSpecialEntry() throws {
        let (google, apple) = coordinators(
            google: InMemoryGoogleAuthenticationFlowStore(),
            apple: InMemoryAppleAuthenticationFlowStore()
        )
        let invitation = try google.prepare(entryContext: .invitation, now: now)
        let special = try apple.prepare(entryContext: .special, now: now)

        XCTAssertFalse(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: invitation,
            appleFlow: nil
        ))
        XCTAssertTrue(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: invitation,
            appleFlow: special
        ))
    }

    /// A submitted flow is committed-or-unknown: the backend may hold a
    /// session for it, so retirement keeps it for receipt recovery.
    func testRetirementKeepsSubmittedFlows() throws {
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let (google, apple) = coordinators(google: googleStorage, apple: appleStorage)
        let prepared = try google.prepare(entryContext: .special, now: now)
        let granted = try google.recordEntryGrant(
            String(repeating: "e", count: 43),
            expiresAt: now.addingTimeInterval(300),
            for: prepared,
            now: now
        )
        let ready = try google.recordIDToken(
            "header.payload.signature",
            for: granted,
            now: now
        )
        let submitted = try google.recordSubmissionAttempt(for: ready, now: now)
        _ = try apple.prepare(entryContext: .special, now: now)

        try SpecialEntryAuthenticationState.retireUnsubmittedFlows(
            google: google,
            apple: apple,
            now: now
        )

        XCTAssertEqual(try googleStorage.load(), submitted)
        XCTAssertNil(try appleStorage.load())
    }

    func testAppleSheetCancelStaysSilentAndOtherFailuresAreLocalized() {
        let canceled = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )
        let mappedCancel = AppleAuthenticationFlowError.fromSystemAuthorization(canceled) as NSError
        XCTAssertEqual(mappedCancel.domain, ASAuthorizationError.errorDomain)
        XCTAssertEqual(mappedCancel.code, ASAuthorizationError.canceled.rawValue)

        // 1000 is what closing "Sign in to your Apple Account" returns when
        // no Apple Account is signed in.
        for code in [ASAuthorizationError.unknown, .failed, .invalidResponse, .notHandled] {
            let error = NSError(domain: ASAuthorizationError.errorDomain, code: code.rawValue)
            let mapped = AppleAuthenticationFlowError.fromSystemAuthorization(error)
            XCTAssertEqual(
                mapped as? AppleAuthenticationFlowError,
                .authorizationFailed,
                "code \(code.rawValue)"
            )
            XCTAssertFalse(mapped.localizedDescription.contains("AuthorizationError"))
        }
    }
}
