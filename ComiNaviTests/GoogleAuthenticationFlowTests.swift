import XCTest
@testable import ComiNavi

final class GoogleAuthenticationFlowTests: XCTestCase {
    func testPreparePersistsStableRequestAndNonceBeforeAnyNetworkCredential() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let requestID = try XCTUnwrap(UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ))
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let coordinator = GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: { requestID },
            makeNonce: { String(repeating: "n", count: 43) }
        )

        let first = try coordinator.prepare(now: now)
        let relaunched = try GoogleAuthenticationFlowCoordinator(
            storage: storage
        ).prepare(now: now.addingTimeInterval(30))

        XCTAssertEqual(first, relaunched)
        XCTAssertEqual(first.requestID, requestID)
        XCTAssertNil(first.entryGrant)
        XCTAssertNil(first.idToken)
        XCTAssertEqual(try storage.load(), first)
    }

    func testExactProtectedPayloadSurvivesRelaunchUntilExplicitClear() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let coordinator = GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: { UUID() },
            makeNonce: { String(repeating: "n", count: 43) }
        )
        let prepared = try coordinator.prepare(now: now)
        let granted = try coordinator.recordEntryGrant(
            String(repeating: "g", count: 43),
            expiresAt: now.addingTimeInterval(300),
            for: prepared,
            now: now
        )
        let completed = try coordinator.recordIDToken(
            "header.payload.signature",
            for: granted,
            now: now
        )

        let relaunched = try GoogleAuthenticationFlowCoordinator(
            storage: storage
        ).load(now: now.addingTimeInterval(60))
        XCTAssertEqual(relaunched, completed)
        XCTAssertTrue(try XCTUnwrap(relaunched).isReadyToAuthenticate)

        try coordinator.clear()
        XCTAssertNil(try storage.load())
    }

    func testExpiredGrantIsScrubbedInsteadOfBeingReplayed() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        var expired = GoogleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "n", count: 43),
            createdAt: now.addingTimeInterval(-400)
        )
        expired.entryGrant = String(repeating: "g", count: 43)
        expired.entryGrantExpiresAt = now.addingTimeInterval(-1)
        expired.idToken = "header.payload.signature"
        try storage.save(expired)

        let loaded = try GoogleAuthenticationFlowCoordinator(
            storage: storage
        ).load(now: now)

        XCTAssertNil(loaded)
        XCTAssertNil(try storage.load())
    }

    func testGeneratedNonceMatchesServerBase64URLBounds() throws {
        let nonce = try GoogleAuthenticationNonce.make()
        XCTAssertEqual(nonce.utf8.count, 43)
        XCTAssertTrue(GoogleAuthenticationFlow.isCanonicalNonce(nonce))
        XCTAssertFalse(nonce.contains("="))
        XCTAssertFalse(nonce.contains("+"))
        XCTAssertFalse(nonce.contains("/"))
    }

    func testGoogleSDKConfigurationFailsClosedWithoutBothClientAndReversedScheme() {
        XCTAssertNil(GoogleSignInConfiguration.load(infoDictionary: [:]))
        XCTAssertNil(GoogleSignInConfiguration.load(infoDictionary: [
            "GIDClientID": "123.apps.googleusercontent.com",
            "CFBundleURLTypes": [],
        ]))
        XCTAssertEqual(
            GoogleSignInConfiguration.load(infoDictionary: [
                "GIDClientID": "123.apps.googleusercontent.com",
                "CFBundleURLTypes": [[
                    "CFBundleURLSchemes": ["com.googleusercontent.apps.123"],
                ]],
            ]),
            GoogleSignInConfiguration(
                clientID: "123.apps.googleusercontent.com",
                callbackScheme: "com.googleusercontent.apps.123"
            )
        )
    }

    func testSDKIdentityTokenMustEchoExactServerNonce() throws {
        let nonce = String(repeating: "n", count: 43)
        let header = base64URL(Data(#"{"alg":"RS256"}"#.utf8))
        let payload = base64URL(Data(#"{"nonce":"\#(nonce)"}"#.utf8))
        let token = "\(header).\(payload).signature"

        XCTAssertNoThrow(try GoogleIdentityTokenValidation.validateNonce(nonce, in: token))
        XCTAssertThrowsError(
            try GoogleIdentityTokenValidation.validateNonce("different", in: token)
        )
    }

    func testSpecialEntryTriggerAndCallbackAreExactAndNonceBound() throws {
        XCTAssertTrue(GoogleSpecialEntryLink.isTrigger(try XCTUnwrap(
            URL(string: "https://cominavi.net/auth/google")
        )))
        XCTAssertTrue(GoogleSpecialEntryLink.isTrigger(try XCTUnwrap(
            URL(string: "cominavi://auth/google")
        )))
        XCTAssertFalse(GoogleSpecialEntryLink.isTrigger(try XCTUnwrap(
            URL(string: "https://cominavi.net/auth/google?unlocked=true")
        )))

        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let nonce = String(repeating: "n", count: 43)
        let expiresAt = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(300)
        )
        let valid = try XCTUnwrap(URL(string:
            "cominavi://auth/google/grant?entryGrant=\(String(repeating: "g", count: 43))&expiresAt=\(expiresAt)&nonce=\(nonce)"
        ))
        let grant = try GoogleEntryGrantCallbackParser.parse(
            valid,
            expectedNonce: nonce,
            now: now
        )
        XCTAssertEqual(grant.entryGrant, String(repeating: "g", count: 43))

        let duplicate = try XCTUnwrap(URL(string: valid.absoluteString + "&nonce=\(nonce)"))
        XCTAssertThrowsError(try GoogleEntryGrantCallbackParser.parse(
            duplicate,
            expectedNonce: nonce,
            now: now
        ))
        XCTAssertThrowsError(try GoogleEntryGrantCallbackParser.parse(
            valid,
            expectedNonce: String(repeating: "x", count: 43),
            now: now
        ))
        XCTAssertThrowsError(try GoogleEntryGrantCallbackParser.parse(
            try XCTUnwrap(URL(string: valid.absoluteString + "&access_token=secret")),
            expectedNonce: nonce,
            now: now
        ))
    }

    func testSpecialEntryGrantSurvivesColdRelaunch() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let nonce = String(repeating: "n", count: 43)
        let coordinator = GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: UUID.init,
            makeNonce: { nonce }
        )
        let prepared = try coordinator.prepare(entryContext: .special, now: now)
        let granted = try coordinator.recordEntryGrant(
            String(repeating: "g", count: 43),
            expiresAt: now.addingTimeInterval(300),
            for: prepared,
            now: now
        )

        let relaunched = try GoogleAuthenticationFlowCoordinator(
            storage: storage
        ).load(now: now.addingTimeInterval(60))

        XCTAssertEqual(relaunched, granted)
        XCTAssertEqual(relaunched?.entryContext, .special)
        XCTAssertEqual(relaunched?.nonce, nonce)
    }

    func testSubmittedResponseLossBeyondGrantExpiryReplaysExactFlowWithoutNewFamily() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let coordinator = GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: UUID.init,
            makeNonce: { String(repeating: "n", count: 43) }
        )
        let prepared = try coordinator.prepare(entryContext: .special, now: now)
        let granted = try coordinator.recordEntryGrant(
            String(repeating: "g", count: 43),
            expiresAt: now.addingTimeInterval(300),
            for: prepared,
            now: now
        )
        let tokenized = try coordinator.recordIDToken(
            "header.payload.signature",
            for: granted,
            now: now
        )
        let submitted = try coordinator.recordSubmissionAttempt(for: tokenized, now: now)

        let afterReplayWindow = try GoogleAuthenticationFlowCoordinator(
            storage: storage
        ).load(now: now.addingTimeInterval(360))
        XCTAssertEqual(afterReplayWindow, submitted)
        let replay = try GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: { XCTFail("must not mint a second request"); return UUID() },
            makeNonce: { XCTFail("must not mint a second nonce"); return "" }
        ).prepare(entryContext: .special, now: now.addingTimeInterval(360))
        let resubmitted = try coordinator.recordSubmissionAttempt(
            for: replay,
            now: now.addingTimeInterval(360)
        )
        XCTAssertEqual(replay, submitted)
        XCTAssertEqual(resubmitted, submitted)
        XCTAssertThrowsError(try coordinator.prepare(
            entryContext: .invitation,
            now: now.addingTimeInterval(360)
        )) { error in
            XCTAssertEqual(error as? GoogleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertEqual(try storage.load(), submitted)
    }

    func testSubmittedFlowRejectsLateGrantOrIdentityTokenMutation() throws {
        let storage = InMemoryGoogleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let coordinator = GoogleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: UUID.init,
            makeNonce: { String(repeating: "n", count: 43) }
        )
        let prepared = try coordinator.prepare(entryContext: .special, now: now)
        let grant = String(repeating: "g", count: 43)
        let grantExpiry = now.addingTimeInterval(300)
        let granted = try coordinator.recordEntryGrant(
            grant,
            expiresAt: grantExpiry,
            for: prepared,
            now: now
        )
        let tokenized = try coordinator.recordIDToken(
            "header.payload.signature",
            for: granted,
            now: now
        )
        let submitted = try coordinator.recordSubmissionAttempt(for: tokenized, now: now)
        let afterGrantExpiry = now.addingTimeInterval(360)

        XCTAssertEqual(try coordinator.recordEntryGrant(
            grant,
            expiresAt: grantExpiry,
            for: submitted,
            now: afterGrantExpiry
        ), submitted)
        XCTAssertEqual(try coordinator.recordIDToken(
            "header.payload.signature",
            for: submitted,
            now: afterGrantExpiry
        ), submitted)
        XCTAssertThrowsError(try coordinator.recordEntryGrant(
            String(repeating: "x", count: 43),
            expiresAt: afterGrantExpiry.addingTimeInterval(300),
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? GoogleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertThrowsError(try coordinator.recordEntryGrant(
            grant,
            expiresAt: afterGrantExpiry.addingTimeInterval(300),
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? GoogleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertThrowsError(try coordinator.recordIDToken(
            "different.header.payload",
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? GoogleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertEqual(try storage.load(), submitted)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
