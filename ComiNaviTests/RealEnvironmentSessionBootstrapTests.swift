import Foundation
import XCTest

@testable import ComiNavi

/// Opt-in bridge for installing a laptop-minted ComiNavi service session into
/// a dedicated Simulator. This never accepts Circle.ms provider credentials;
/// the app receives only the backend-issued ComiNavi access/refresh family.
final class RealEnvironmentSessionBootstrapTests: XCTestCase {
    func testExportProductionSessionWhenExplicitlyRequired() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMINAVI_E2E_EXPORT_SERVICE_SESSION_REQUIRED"] == "1" else {
            return
        }

        let fileName = try XCTUnwrap(
            environment["COMINAVI_E2E_EXPORT_SERVICE_SESSION_FILE_NAME"]
        )
        let pattern = #"\Acominavi-session-export-[0-9a-f]{32}\.json\z"#
        XCTAssertNotNil(fileName.range(of: pattern, options: .regularExpression))

        #if DEBUG
            AppEnvironment.setDebugCirclemsEnvironment(.production)
        #endif
        let account = AppEnvironment.storageNamespace(
            build: .debug,
            circlems: .production
        )
        let store = KeychainCominaviAuthenticationSessionStore(account: account)
        let state = store.loadState()
        XCTAssertTrue(state.isAvailable)
        XCTAssertNil(state.pendingLogout)
        XCTAssertNil(state.pendingAccountDeletion)
        XCTAssertNil(state.pendingAccountDeletionCleanup)

        let session = try XCTUnwrap(state.session)
        let userID = try XCTUnwrap(session.user?.id)
        XCTAssertEqual(state.boundUserID, userID)
        XCTAssertEqual(session.tokenType.lowercased(), "bearer")
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertGreaterThan(session.authVersion, 0)
        let refreshToken = try XCTUnwrap(session.refreshToken)
        XCTAssertEqual(refreshToken.utf8.count, 43)
        XCTAssertTrue(refreshToken.unicodeScalars.allSatisfy(Self.isBase64URL))
        XCTAssertGreaterThan(try XCTUnwrap(session.refreshExpiresAt), Date())

        let root = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        ).appendingPathComponent("CominaviE2EExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = root.appendingPathComponent(fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    func testInstallProductionSessionWhenExplicitlyRequired() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMINAVI_E2E_SERVICE_SESSION_REQUIRED"] == "1" else {
            return
        }

        let encodedSession = try XCTUnwrap(
            environment["COMINAVI_E2E_SERVICE_SESSION_BASE64"],
            "The required ComiNavi session was not injected into the test host"
        )
        let data = try XCTUnwrap(Data(base64Encoded: encodedSession))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CominaviAuthenticationSession.self, from: data)

        let userID = try XCTUnwrap(session.user?.id)
        XCTAssertFalse(userID.isEmpty)
        XCTAssertEqual(session.tokenType.lowercased(), "bearer")
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertGreaterThan(session.authVersion, 0)
        let refreshToken = try XCTUnwrap(session.refreshToken)
        XCTAssertEqual(refreshToken.utf8.count, 43)
        XCTAssertTrue(refreshToken.unicodeScalars.allSatisfy(Self.isBase64URL))
        XCTAssertGreaterThan(try XCTUnwrap(session.refreshExpiresAt), Date())

        let account = AppEnvironment.storageNamespace(
            build: .debug,
            circlems: .production
        )
        let store = KeychainCominaviAuthenticationSessionStore(account: account)
        let existing = store.loadState()
        XCTAssertTrue(existing.isAvailable)
        XCTAssertNil(existing.pendingLogout)
        XCTAssertNil(existing.pendingAccountDeletion)
        XCTAssertNil(existing.pendingAccountDeletionCleanup)
        if let existingUserID = existing.boundUserID {
            XCTAssertEqual(existingUserID, userID)
        }

        #if DEBUG
            AppEnvironment.setDebugCirclemsEnvironment(.production)
        #endif
        let catalogModeKey = "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)"
        UserDefaults.standard.set(CatalogDataMode.cominavi.rawValue, forKey: catalogModeKey)

        // A refresh token is single-use. Once this Simulator has rotated the
        // injected family, replaying the laptop's older JSON would strand the
        // working session. Preserve an existing same-user login unless the
        // operator explicitly supplies a replacement session.
        if existing.session != nil,
           environment["COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION"] != "1"
        {
            XCTAssertFalse(existing.isLoggedOut)
            XCTAssertFalse(existing.requiresExplicitAuthentication)
            XCTAssertEqual(UserDefaults.standard.string(forKey: catalogModeKey), "cominavi")
            return
        }

        // Mirror the production fail-closed write order. Keychain has no
        // transaction, so a crash before the last line leaves reauthentication
        // required instead of exposing a partial or cross-account session.
        XCTAssertTrue(store.saveReauthenticationTombstone(true))
        XCTAssertTrue(store.saveBoundUserID(userID))
        XCTAssertTrue(store.save(session))
        XCTAssertTrue(store.saveLogoutTombstone(false))
        XCTAssertTrue(store.saveReauthenticationTombstone(false))

        let installed = store.loadState()
        XCTAssertTrue(installed.isAvailable)
        XCTAssertFalse(installed.isLoggedOut)
        XCTAssertFalse(installed.requiresExplicitAuthentication)
        XCTAssertEqual(installed.boundUserID, userID)
        XCTAssertEqual(installed.session, session)
        XCTAssertEqual(UserDefaults.standard.string(forKey: catalogModeKey), "cominavi")
    }

    private static func isBase64URL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}
