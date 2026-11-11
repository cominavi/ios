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

    // MARK: Allowlist refusal (cominavi/server#13)

    private let refusal = CominaviServiceError.server(
        code: "sign_in_not_allowlisted",
        message: "This Google account is not on the ComiNavi sign-in allowlist.",
        status: 403
    )
    private let otherForbidden = CominaviServiceError.server(
        code: "forbidden",
        message: "Forbidden.",
        status: 403
    )

    private func submittedGoogleFlow() -> GoogleAuthenticationFlow {
        GoogleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "g", count: 43),
            entryContext: .special,
            createdAt: now,
            entryGrant: String(repeating: "e", count: 43),
            entryGrantExpiresAt: now.addingTimeInterval(300),
            idToken: "header.payload.signature",
            submissionAttemptedAt: now
        )
    }

    private func submittedAppleFlow() -> AppleAuthenticationFlow {
        AppleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "a", count: 43),
            entryContext: .special,
            createdAt: now,
            entryGrant: String(repeating: "e", count: 43),
            entryGrantExpiresAt: now.addingTimeInterval(300),
            identityToken: "header.payload.signature",
            authorizationCode: "single-use-code",
            submissionAttemptedAt: now
        )
    }

    /// A refused Google sign-in whose request already reached the service
    /// clears its flow, so relaunch does not reopen the special entry.
    func testAllowlistRefusedGoogleSignInClearsFlowAndDoesNotReopen() throws {
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = submittedGoogleFlow()
        try googleStorage.save(flow)
        let (google, _) = coordinators(google: googleStorage, apple: appleStorage)
        XCTAssertNotNil(try google.load(now: now))

        XCTAssertTrue(SpecialEntryAuthenticationState.settleFailedSignIn(
            refusal,
            googleFlow: flow,
            clear: google.clear
        ))

        let (relaunchedGoogle, relaunchedApple) = coordinators(
            google: googleStorage,
            apple: appleStorage
        )
        let later = now.addingTimeInterval(60)
        let googleFlow = try relaunchedGoogle.load(now: later)
        XCTAssertNil(googleFlow)
        XCTAssertFalse(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: googleFlow,
            appleFlow: try relaunchedApple.load(now: later)
        ))
    }

    func testAllowlistRefusedAppleSignInClearsFlowAndDoesNotReopen() throws {
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = submittedAppleFlow()
        try appleStorage.save(flow)
        let (_, apple) = coordinators(google: googleStorage, apple: appleStorage)
        XCTAssertNotNil(try apple.load(now: now))

        XCTAssertTrue(SpecialEntryAuthenticationState.settleFailedSignIn(
            refusal,
            appleFlow: flow,
            clear: apple.clear
        ))

        let (relaunchedGoogle, relaunchedApple) = coordinators(
            google: googleStorage,
            apple: appleStorage
        )
        let later = now.addingTimeInterval(60)
        let appleFlow = try relaunchedApple.load(now: later)
        XCTAssertNil(appleFlow)
        XCTAssertFalse(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: try relaunchedGoogle.load(now: later),
            appleFlow: appleFlow
        ))
    }

    /// Any other failure after submission is committed-or-unknown: both
    /// providers keep their flow for receipt recovery.
    func testOtherFailuresAfterSubmissionKeepTheFlow() throws {
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let googleFlow = submittedGoogleFlow()
        let appleFlow = submittedAppleFlow()
        try googleStorage.save(googleFlow)
        try appleStorage.save(appleFlow)
        let (google, apple) = coordinators(google: googleStorage, apple: appleStorage)

        for error: Error in [
            otherForbidden,
            CominaviServiceError.server(
                code: "sign_in_not_allowlisted",
                message: "",
                status: 401
            ),
            CominaviServiceError.invalidResponse,
        ] {
            XCTAssertFalse(SpecialEntryAuthenticationState.settleFailedSignIn(
                error,
                googleFlow: googleFlow,
                clear: google.clear
            ))
            XCTAssertFalse(SpecialEntryAuthenticationState.settleFailedSignIn(
                error,
                appleFlow: appleFlow,
                clear: apple.clear
            ))
        }
        XCTAssertNotNil(try google.load(now: now))
        XCTAssertNotNil(try apple.load(now: now))
        XCTAssertTrue(SpecialEntryAuthenticationState.shouldRestore(
            hasVerifiedProfile: false,
            googleFlow: try google.load(now: now),
            appleFlow: try apple.load(now: now)
        ))
    }
}
