@testable import ComiNavi
import XCTest

final class AppleAuthenticationFlowTests: XCTestCase {
    func testAppDeclaresSignInWithAppleEntitlement() throws {
        let entitlementURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ComiNavi/ComiNavi.entitlements")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: entitlementURL),
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            plist["com.apple.developer.applesignin"] as? [String],
            ["Default"]
        )
    }

    func testPreparePersistsStableRequestAndNonceBeforeProviderUI() throws {
        let storage = InMemoryAppleAuthenticationFlowStore()
        let requestID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ))
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let coordinator = AppleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: { requestID },
            makeNonce: { String(repeating: "n", count: 43) }
        )

        let first = try coordinator.prepare(entryContext: .invitation, now: now)
        let relaunched = try AppleAuthenticationFlowCoordinator(
            storage: storage
        ).prepare(entryContext: .invitation, now: now.addingTimeInterval(30))

        XCTAssertEqual(first, relaunched)
        XCTAssertEqual(first.requestID, requestID)
        XCTAssertNil(first.entryGrant)
        XCTAssertNil(first.identityToken)
        XCTAssertNil(first.authorizationCode)
        XCTAssertEqual(try storage.load(), first)
    }

    func testSubmittedExactCredentialSurvivesGrantExpiryAndRelaunch() throws {
        let storage = InMemoryAppleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let nonce = String(repeating: "n", count: 43)
        let coordinator = AppleAuthenticationFlowCoordinator(
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
        let token = appleToken(rawNonce: nonce)
        let credentialed = try coordinator.recordCredential(
            AppleAuthorizationCredential(
                identityToken: token,
                authorizationCode: "single-use-code",
                displayName: "Apple 利用者"
            ),
            for: granted,
            now: now
        )
        let submitted = try coordinator.recordSubmissionAttempt(
            for: credentialed,
            now: now
        )

        let relaunched = try AppleAuthenticationFlowCoordinator(
            storage: storage
        ).load(now: now.addingTimeInterval(360))
        let replay = try AppleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: { XCTFail("must not mint another request"); return UUID() },
            makeNonce: { XCTFail("must not mint another nonce"); return "" }
        ).prepare(entryContext: .special, now: now.addingTimeInterval(360))
        let resubmitted = try coordinator.recordSubmissionAttempt(
            for: replay,
            now: now.addingTimeInterval(360)
        )

        XCTAssertEqual(relaunched, submitted)
        XCTAssertEqual(replay, submitted)
        XCTAssertEqual(resubmitted, submitted)
        XCTAssertThrowsError(try coordinator.prepare(
            entryContext: .invitation,
            now: now.addingTimeInterval(360)
        )) { error in
            XCTAssertEqual(error as? AppleAuthenticationFlowError, .committedOrUnknown)
        }
    }

    func testSubmittedFlowRejectsLateGrantOrCredentialMutation() throws {
        let storage = InMemoryAppleAuthenticationFlowStore()
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let nonce = String(repeating: "n", count: 43)
        let coordinator = AppleAuthenticationFlowCoordinator(
            storage: storage,
            makeRequestID: UUID.init,
            makeNonce: { nonce }
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
        let credential = AppleAuthorizationCredential(
            identityToken: appleToken(rawNonce: nonce),
            authorizationCode: "single-use-code",
            displayName: "Apple 利用者"
        )
        let credentialed = try coordinator.recordCredential(
            credential,
            for: granted,
            now: now
        )
        let submitted = try coordinator.recordSubmissionAttempt(for: credentialed, now: now)
        let afterGrantExpiry = now.addingTimeInterval(360)

        XCTAssertEqual(try coordinator.recordEntryGrant(
            grant,
            expiresAt: grantExpiry,
            for: submitted,
            now: afterGrantExpiry
        ), submitted)
        XCTAssertEqual(try coordinator.recordCredential(
            credential,
            for: submitted,
            now: afterGrantExpiry
        ), submitted)
        XCTAssertThrowsError(try coordinator.recordEntryGrant(
            String(repeating: "x", count: 43),
            expiresAt: afterGrantExpiry.addingTimeInterval(300),
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? AppleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertThrowsError(try coordinator.recordEntryGrant(
            grant,
            expiresAt: afterGrantExpiry.addingTimeInterval(300),
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? AppleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertThrowsError(try coordinator.recordCredential(
            AppleAuthorizationCredential(
                identityToken: credential.identityToken,
                authorizationCode: "different-code",
                displayName: credential.displayName
            ),
            for: submitted,
            now: afterGrantExpiry
        )) { error in
            XCTAssertEqual(error as? AppleAuthenticationFlowError, .committedOrUnknown)
        }
        XCTAssertEqual(try storage.load(), submitted)
    }

    func testAppleIdentityTokenMustContainSHA256OfRawNonce() throws {
        let nonce = String(repeating: "n", count: 43)
        let token = appleToken(rawNonce: nonce)

        XCTAssertNoThrow(try AppleIdentityTokenValidation.validateNonce(nonce, in: token))
        XCTAssertThrowsError(
            try AppleIdentityTokenValidation.validateNonce(
                String(repeating: "x", count: 43),
                in: token
            )
        )
        XCTAssertEqual(AppleAuthenticationNonce.sha256(nonce).utf8.count, 64)
    }

    func testFrozenSpecialEntryAndCallbackAreStrictAndNonceBound() throws {
        let fixture = try fixtureObject()
        let apple = try XCTUnwrap(fixture["apple"] as? [String: Any])
        let specialURL = try XCTUnwrap(URL(
            string: try XCTUnwrap(apple["specialEntryURL"] as? String)
        ))
        let callback = try XCTUnwrap(URL(
            string: try XCTUnwrap(apple["entryCallback"] as? String)
        ))
        let request = try XCTUnwrap(apple["request"] as? [String: Any])
        let nonce = try XCTUnwrap(request["nonce"] as? String)
        let grantResponse = try XCTUnwrap(apple["entryGrantResponse"] as? [String: Any])
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = try XCTUnwrap(dateFormatter.date(
            from: try XCTUnwrap(grantResponse["expiresAt"] as? String)
        ))

        XCTAssertEqual(AppleSpecialEntryLink.authorizationURL(nonce: nonce), specialURL)
        XCTAssertTrue(AppleSpecialEntryLink.isTrigger(try XCTUnwrap(
            URL(string: "https://cominavi.net/auth/apple")
        )))
        XCTAssertTrue(AppleSpecialEntryLink.isTrigger(try XCTUnwrap(
            URL(string: "cominavi://auth/apple")
        )))
        XCTAssertFalse(AppleSpecialEntryLink.isTrigger(specialURL))

        let grant = try AppleEntryGrantCallbackParser.parse(
            callback,
            expectedNonce: nonce,
            now: expiresAt.addingTimeInterval(-300)
        )
        XCTAssertEqual(grant.entryGrant, grantResponse["entryGrant"] as? String)

        let duplicate = try XCTUnwrap(URL(string: callback.absoluteString + "&nonce=\(nonce)"))
        XCTAssertThrowsError(try AppleEntryGrantCallbackParser.parse(
            duplicate,
            expectedNonce: nonce,
            now: expiresAt.addingTimeInterval(-300)
        ))
        let tokenLeak = try XCTUnwrap(URL(
            string: callback.absoluteString + "&authorizationCode=secret"
        ))
        XCTAssertThrowsError(try AppleEntryGrantCallbackParser.parse(
            tokenLeak,
            expectedNonce: nonce,
            now: expiresAt.addingTimeInterval(-300)
        ))
    }

    private func appleToken(rawNonce: String) -> String {
        let header = base64URL(Data(#"{"alg":"RS256"}"#.utf8))
        let hash = AppleAuthenticationNonce.sha256(rawNonce)
        let payload = base64URL(Data(#"{"nonce":"\#(hash)"}"#.utf8))
        return "\(header).\(payload).signature"
    }

    private func fixtureObject() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "auth-providers-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "auth-providers-v1", withExtension: "json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(url)))
                as? [String: Any]
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
