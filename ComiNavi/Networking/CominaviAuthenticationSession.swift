import Foundation
import Security
import Sentry

enum CominaviISO8601Date {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct CirclemsAuthorizationCompletionMarker: Codable, Equatable, Sendable {
    let flowRequestID: UUID
    let credentialReceipt: CirclemsCredentialReceipt
}

struct GoogleAuthenticationCompletionMarker: Codable, Equatable, Sendable {
    let flowRequestID: UUID
    let publicUserID: String
}

struct AppleAuthenticationCompletionMarker: Codable, Equatable, Sendable {
    let flowRequestID: UUID
    let publicUserID: String
}

/// Protected, immutable logout command retained until the backend acknowledges
/// the auth-epoch revocation. The exact payload and predecessor credentials are
/// kept in ThisDeviceOnly Keychain storage so an offline logout can retry after
/// the visible session has already been removed.
struct CominaviLogoutTransaction: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let requestId: String
    let publicUserID: String
    let authVersion: Int
    let predecessorAccessToken: String
    let predecessorRefreshToken: String
    let payload: Data
    let createdAt: Date

    init(
        requestID: UUID,
        publicUserID: String,
        authVersion: Int,
        predecessorAccessToken: String,
        predecessorRefreshToken: String,
        payload: Data,
        createdAt: Date = Date()
    ) {
        version = Self.schemaVersion
        requestId = requestID.uuidString.lowercased()
        self.publicUserID = publicUserID
        self.authVersion = authVersion
        self.predecessorAccessToken = predecessorAccessToken
        self.predecessorRefreshToken = predecessorRefreshToken
        self.payload = payload
        self.createdAt = createdAt
    }

    var requestID: UUID? { UUID(uuidString: requestId) }

    var isValid: Bool {
        guard version == Self.schemaVersion,
              let requestID,
              requestId == requestID.uuidString.lowercased(),
              !publicUserID.isEmpty,
              authVersion > 0,
              !predecessorAccessToken.isEmpty,
              predecessorRefreshToken.utf8.count == 43,
              predecessorRefreshToken.unicodeScalars.allSatisfy(Self.isBase64URL),
              let object = try? JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
              object.count == 2,
              object["requestId"] as? String == requestId,
              object["refreshToken"] as? String == predecessorRefreshToken
        else { return false }
        return true
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

/// Protected exact account-deletion command. The predecessor bearer is kept
/// only for idempotent 202 receipt recovery after the server has fenced and
/// removed the account.
struct CominaviAccountDeletionTransaction: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let requestId: String
    let publicUserID: String
    let authVersion: Int
    let predecessorAccessToken: String
    let payload: Data
    let createdAt: Date

    init(
        requestID: UUID,
        publicUserID: String,
        authVersion: Int,
        predecessorAccessToken: String,
        payload: Data,
        createdAt: Date = Date()
    ) {
        version = Self.schemaVersion
        requestId = requestID.uuidString.lowercased()
        self.publicUserID = publicUserID
        self.authVersion = authVersion
        self.predecessorAccessToken = predecessorAccessToken
        self.payload = payload
        self.createdAt = createdAt
    }

    var requestID: UUID? { UUID(uuidString: requestId) }

    var isValid: Bool {
        guard version == Self.schemaVersion,
              let requestID,
              requestId == requestID.uuidString.lowercased(),
              !publicUserID.isEmpty,
              authVersion > 0,
              !predecessorAccessToken.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object.count == 2,
              object["requestId"] as? String == requestId,
              object["confirmation"] as? String == "DELETE"
        else { return false }
        return true
    }
}

/// Protected proof that the backend accepted account deletion while local,
/// user-scoped files still need to be erased. This receipt deliberately keeps
/// the public user ID after the session binding is removed so a process death
/// between HTTP 202 and filesystem cleanup remains recoverable.
struct CominaviAccountDeletionCleanupReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let requestId: String
    let publicUserID: String
    let deletedOwnedPlanIDs: [String]
    let acknowledgedAt: Date

    init(
        requestID: UUID,
        publicUserID: String,
        deletedOwnedPlanIDs: [String],
        acknowledgedAt: Date = Date()
    ) {
        version = Self.schemaVersion
        requestId = requestID.uuidString.lowercased()
        self.publicUserID = publicUserID
        self.deletedOwnedPlanIDs = deletedOwnedPlanIDs
        self.acknowledgedAt = acknowledgedAt
    }

    var requestID: UUID? { UUID(uuidString: requestId) }

    var isValid: Bool {
        guard version == Self.schemaVersion,
              let requestID,
              requestId == requestID.uuidString.lowercased(),
              !publicUserID.isEmpty,
              publicUserID.utf8.count <= 256,
              acknowledgedAt.timeIntervalSinceReferenceDate.isFinite
        else { return false }
        return deletedOwnedPlanIDs.allSatisfy { value in
            guard let id = UUID(uuidString: value) else { return false }
            return value == id.uuidString.lowercased()
        }
    }
}

struct CominaviAccountDeletionResult: Codable, Equatable, Sendable {
    let status: String
    let requestId: String
    let deletedOwnedPlanIDs: [String]
}

struct CominaviAuthenticationSession: Codable, Equatable, Sendable {
    let tokenType: String
    let accessToken: String
    let expiresAt: Date
    let authVersion: Int
    let refreshToken: String?
    let refreshExpiresAt: Date?
    let user: CominaviUserProfile?
    let circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker?
    let googleAuthenticationCompletion: GoogleAuthenticationCompletionMarker?
    let appleAuthenticationCompletion: AppleAuthenticationCompletionMarker?

    init(
        tokenType: String = "Bearer",
        accessToken: String,
        expiresAt: Date,
        authVersion: Int = 1,
        refreshToken: String? = nil,
        refreshExpiresAt: Date? = nil,
        user: CominaviUserProfile? = nil,
        circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker? = nil,
        googleAuthenticationCompletion: GoogleAuthenticationCompletionMarker? = nil,
        appleAuthenticationCompletion: AppleAuthenticationCompletionMarker? = nil
    ) {
        self.tokenType = tokenType
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.authVersion = authVersion
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
        self.user = user
        self.circlemsAuthorizationCompletion = circlemsAuthorizationCompletion
        self.googleAuthenticationCompletion = googleAuthenticationCompletion
        self.appleAuthenticationCompletion = appleAuthenticationCompletion
    }

    private enum CodingKeys: String, CodingKey {
        case tokenType, accessToken, expiresAt, authVersion, refreshToken, refreshExpiresAt, user
        case circlemsAuthorizationCompletion
        case googleAuthenticationCompletion
        case appleAuthenticationCompletion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokenType = try values.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        accessToken = try values.decode(String.self, forKey: .accessToken)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        // Version 1 is the migration value for protected sessions written
        // before auth-version logout receipts were introduced.
        authVersion = try values.decodeIfPresent(Int.self, forKey: .authVersion) ?? 1
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        refreshExpiresAt = try values.decodeIfPresent(Date.self, forKey: .refreshExpiresAt)
        user = try values.decodeIfPresent(CominaviUserProfile.self, forKey: .user)
        circlemsAuthorizationCompletion = try values.decodeIfPresent(
            CirclemsAuthorizationCompletionMarker.self,
            forKey: .circlemsAuthorizationCompletion
        )
        googleAuthenticationCompletion = try values.decodeIfPresent(
            GoogleAuthenticationCompletionMarker.self,
            forKey: .googleAuthenticationCompletion
        )
        appleAuthenticationCompletion = try values.decodeIfPresent(
            AppleAuthenticationCompletionMarker.self,
            forKey: .appleAuthenticationCompletion
        )
    }
}

struct CominaviGoogleAuthenticationRequest: Codable, Equatable, Sendable {
    let requestId: String
    let idToken: String
    let entryGrant: String
    let nonce: String
}

struct CominaviGoogleEntryGrantRequest: Codable, Equatable, Sendable {
    let nonce: String
    let inviteToken: String
}

struct CominaviGoogleEntryGrant: Codable, Equatable, Sendable {
    let entryGrant: String
    let expiresAt: Date
}

struct CominaviAppleAuthenticationRequest: Codable, Equatable, Sendable {
    let requestId: String
    let identityToken: String
    let authorizationCode: String
    let entryGrant: String
    let nonce: String
    let displayName: String?
}

struct CominaviAppleEntryGrantRequest: Codable, Equatable, Sendable {
    let nonce: String
    let inviteToken: String
}

struct CominaviAppleEntryGrant: Codable, Equatable, Sendable {
    let entryGrant: String
    let expiresAt: Date
}

struct CominaviAuthenticationStorageState: Sendable {
    let session: CominaviAuthenticationSession?
    let boundUserID: String?
    let pendingLogout: CominaviLogoutTransaction?
    let pendingAccountDeletion: CominaviAccountDeletionTransaction?
    let pendingAccountDeletionCleanup: CominaviAccountDeletionCleanupReceipt?
    let requiresExplicitAuthentication: Bool
    let isLoggedOut: Bool
    let isAvailable: Bool

    init(
        session: CominaviAuthenticationSession?,
        boundUserID: String?,
        pendingLogout: CominaviLogoutTransaction?,
        pendingAccountDeletion: CominaviAccountDeletionTransaction? = nil,
        pendingAccountDeletionCleanup: CominaviAccountDeletionCleanupReceipt? = nil,
        requiresExplicitAuthentication: Bool,
        isLoggedOut: Bool,
        isAvailable: Bool
    ) {
        self.session = session
        self.boundUserID = boundUserID
        self.pendingLogout = pendingLogout
        self.pendingAccountDeletion = pendingAccountDeletion
        self.pendingAccountDeletionCleanup = pendingAccountDeletionCleanup
        self.requiresExplicitAuthentication = requiresExplicitAuthentication
        self.isLoggedOut = isLoggedOut
        self.isAvailable = isAvailable
    }
}

protocol CominaviAuthenticationSessionPersisting: Sendable {
    func load() -> CominaviAuthenticationSession?
    @discardableResult func save(_ session: CominaviAuthenticationSession?) -> Bool
    func loadBoundUserID() -> String?
    @discardableResult func saveBoundUserID(_ userID: String?) -> Bool
    func loadState() -> CominaviAuthenticationStorageState
    func loadPendingLogout() -> CominaviLogoutTransaction?
    @discardableResult func savePendingLogout(_ transaction: CominaviLogoutTransaction?) -> Bool
    func loadPendingAccountDeletion() -> CominaviAccountDeletionTransaction?
    @discardableResult func savePendingAccountDeletion(
        _ transaction: CominaviAccountDeletionTransaction?
    ) -> Bool
    func loadPendingAccountDeletionCleanup() -> CominaviAccountDeletionCleanupReceipt?
    @discardableResult func savePendingAccountDeletionCleanup(
        _ receipt: CominaviAccountDeletionCleanupReceipt?
    ) -> Bool
    @discardableResult func saveLogoutTombstone(_ present: Bool) -> Bool
    @discardableResult func saveReauthenticationTombstone(_ present: Bool) -> Bool
}

extension CominaviAuthenticationSessionPersisting {
    func loadBoundUserID() -> String? { nil }
    @discardableResult func saveBoundUserID(_ userID: String?) -> Bool { true }
    func loadState() -> CominaviAuthenticationStorageState {
        CominaviAuthenticationStorageState(
            session: load(),
            boundUserID: loadBoundUserID(),
            pendingLogout: loadPendingLogout(),
            pendingAccountDeletion: loadPendingAccountDeletion(),
            pendingAccountDeletionCleanup: loadPendingAccountDeletionCleanup(),
            requiresExplicitAuthentication: false,
            isLoggedOut: false,
            isAvailable: true
        )
    }
    func loadPendingLogout() -> CominaviLogoutTransaction? { nil }
    @discardableResult
    func savePendingLogout(_ transaction: CominaviLogoutTransaction?) -> Bool { true }
    func loadPendingAccountDeletion() -> CominaviAccountDeletionTransaction? { nil }
    @discardableResult
    func savePendingAccountDeletion(
        _ transaction: CominaviAccountDeletionTransaction?
    ) -> Bool { true }
    func loadPendingAccountDeletionCleanup() -> CominaviAccountDeletionCleanupReceipt? { nil }
    @discardableResult
    func savePendingAccountDeletionCleanup(
        _ receipt: CominaviAccountDeletionCleanupReceipt?
    ) -> Bool { true }
    @discardableResult func saveLogoutTombstone(_ present: Bool) -> Bool { true }
    @discardableResult func saveReauthenticationTombstone(_ present: Bool) -> Bool { true }
}

struct EphemeralCominaviAuthenticationSessionStore: CominaviAuthenticationSessionPersisting {
    func load() -> CominaviAuthenticationSession? { nil }
    func save(_ session: CominaviAuthenticationSession?) -> Bool { true }
}

struct KeychainCominaviAuthenticationSessionStore: CominaviAuthenticationSessionPersisting {
    private static let service = "net.cominavi.service-session"
    private static let bindingService = "net.cominavi.service-session-user-binding"
    private static let logoutService = "net.cominavi.service-session-logout-tombstone"
    private static let reauthenticationService =
        "net.cominavi.service-session-reauthentication-tombstone"
    private static let accountDeletionService =
        "net.cominavi.service-session-account-deletion"
    private static let accountDeletionCleanupService =
        "net.cominavi.service-session-account-deletion-cleanup"
    let account: String

    func load() -> CominaviAuthenticationSession? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(CominaviAuthenticationSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            report(operation: "read", status: status)
            return nil
        }
    }

    @discardableResult
    func save(_ session: CominaviAuthenticationSession?) -> Bool {
        guard let session else {
            let status = SecItemDelete(itemQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            report(operation: "update", status: update)
            return false
        }
        var item = itemQuery
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            report(operation: "add", status: add)
            return false
        }
        return true
    }

    func loadBoundUserID() -> String? {
        var query = bindingItemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { return nil }
            return value
        case errSecItemNotFound:
            return nil
        default:
            report(operation: "read binding", status: status)
            return nil
        }
    }

    func loadState() -> CominaviAuthenticationStorageState {
        let sessionRead = readData(query: itemQuery)
        let bindingRead = readData(query: bindingItemQuery)
        let logoutRead = readData(query: logoutItemQuery)
        let reauthenticationRead = readData(query: reauthenticationItemQuery)
        let accountDeletionRead = readData(query: accountDeletionItemQuery)
        let accountDeletionCleanupRead = readData(query: accountDeletionCleanupItemQuery)
        guard sessionRead.isAvailable,
              bindingRead.isAvailable,
              logoutRead.isAvailable,
              reauthenticationRead.isAvailable,
              accountDeletionRead.isAvailable,
              accountDeletionCleanupRead.isAvailable
        else {
            return CominaviAuthenticationStorageState(
                session: nil,
                boundUserID: nil,
                pendingLogout: nil,
                pendingAccountDeletion: nil,
                requiresExplicitAuthentication: true,
                isLoggedOut: false,
                isAvailable: false
            )
        }
        let decodedSession: CominaviAuthenticationSession?
        if let data = sessionRead.data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(CominaviAuthenticationSession.self, from: data)
            else {
                return CominaviAuthenticationStorageState(
                    session: nil,
                    boundUserID: nil,
                    pendingLogout: nil,
                    pendingAccountDeletion: nil,
                    requiresExplicitAuthentication: true,
                    isLoggedOut: false,
                    isAvailable: false
                )
            }
            decodedSession = value
        } else {
            decodedSession = nil
        }
        let boundUserID = bindingRead.data.flatMap { String(data: $0, encoding: .utf8) }
        let pendingLogout: CominaviLogoutTransaction?
        if let data = logoutRead.data, data != Data([1]) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(CominaviLogoutTransaction.self, from: data),
                  value.isValid
            else {
                return CominaviAuthenticationStorageState(
                    session: nil,
                    boundUserID: boundUserID,
                    pendingLogout: nil,
                    pendingAccountDeletion: nil,
                    requiresExplicitAuthentication: true,
                    isLoggedOut: true,
                    isAvailable: false
                )
            }
            pendingLogout = value
        } else {
            pendingLogout = nil
        }
        let pendingAccountDeletion: CominaviAccountDeletionTransaction?
        if let data = accountDeletionRead.data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(
                CominaviAccountDeletionTransaction.self,
                from: data
            ), value.isValid else {
                return CominaviAuthenticationStorageState(
                    session: nil,
                    boundUserID: boundUserID,
                    pendingLogout: pendingLogout,
                    pendingAccountDeletion: nil,
                    requiresExplicitAuthentication: true,
                    isLoggedOut: false,
                    isAvailable: false
                )
            }
            pendingAccountDeletion = value
        } else {
            pendingAccountDeletion = nil
        }
        let pendingAccountDeletionCleanup: CominaviAccountDeletionCleanupReceipt?
        if let data = accountDeletionCleanupRead.data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let value = try? decoder.decode(
                CominaviAccountDeletionCleanupReceipt.self,
                from: data
            ), value.isValid else {
                return CominaviAuthenticationStorageState(
                    session: nil,
                    boundUserID: boundUserID,
                    pendingLogout: pendingLogout,
                    pendingAccountDeletion: pendingAccountDeletion,
                    pendingAccountDeletionCleanup: nil,
                    requiresExplicitAuthentication: true,
                    isLoggedOut: true,
                    isAvailable: false
                )
            }
            pendingAccountDeletionCleanup = value
        } else {
            pendingAccountDeletionCleanup = nil
        }
        return CominaviAuthenticationStorageState(
            session: decodedSession,
            boundUserID: boundUserID?.isEmpty == false ? boundUserID : nil,
            pendingLogout: pendingLogout,
            pendingAccountDeletion: pendingAccountDeletion,
            pendingAccountDeletionCleanup: pendingAccountDeletionCleanup,
            requiresExplicitAuthentication: logoutRead.data != nil
                || reauthenticationRead.data != nil
                || accountDeletionRead.data != nil
                || accountDeletionCleanupRead.data != nil,
            isLoggedOut: logoutRead.data != nil || accountDeletionCleanupRead.data != nil,
            isAvailable: true
        )
    }

    func loadPendingLogout() -> CominaviLogoutTransaction? {
        loadState().pendingLogout
    }

    func loadPendingAccountDeletion() -> CominaviAccountDeletionTransaction? {
        loadState().pendingAccountDeletion
    }

    func loadPendingAccountDeletionCleanup() -> CominaviAccountDeletionCleanupReceipt? {
        loadState().pendingAccountDeletionCleanup
    }

    @discardableResult
    func savePendingLogout(_ transaction: CominaviLogoutTransaction?) -> Bool {
        guard let transaction else {
            return saveMarker(false, query: logoutItemQuery, operation: "logout transaction")
        }
        guard transaction.isValid else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transaction) else { return false }
        return saveData(data, query: logoutItemQuery, operation: "logout transaction")
    }

    @discardableResult
    func savePendingAccountDeletion(
        _ transaction: CominaviAccountDeletionTransaction?
    ) -> Bool {
        guard let transaction else {
            return saveMarker(
                false,
                query: accountDeletionItemQuery,
                operation: "account deletion transaction"
            )
        }
        guard transaction.isValid else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transaction) else { return false }
        return saveData(
            data,
            query: accountDeletionItemQuery,
            operation: "account deletion transaction"
        )
    }

    @discardableResult
    func savePendingAccountDeletionCleanup(
        _ receipt: CominaviAccountDeletionCleanupReceipt?
    ) -> Bool {
        guard let receipt else {
            return saveMarker(
                false,
                query: accountDeletionCleanupItemQuery,
                operation: "account deletion cleanup receipt"
            )
        }
        guard receipt.isValid else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(receipt) else { return false }
        return saveData(
            data,
            query: accountDeletionCleanupItemQuery,
            operation: "account deletion cleanup receipt"
        )
    }

    @discardableResult
    func saveBoundUserID(_ userID: String?) -> Bool {
        guard let userID else {
            let status = SecItemDelete(bindingItemQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard !userID.isEmpty, let data = userID.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(bindingItemQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            report(operation: "update binding", status: update)
            return false
        }
        var item = bindingItemQuery
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            report(operation: "add binding", status: add)
            return false
        }
        return true
    }

    @discardableResult
    func saveLogoutTombstone(_ present: Bool) -> Bool {
        saveMarker(present, query: logoutItemQuery, operation: "logout tombstone")
    }

    @discardableResult
    func saveReauthenticationTombstone(_ present: Bool) -> Bool {
        saveMarker(
            present,
            query: reauthenticationItemQuery,
            operation: "reauthentication tombstone"
        )
    }

    private func saveMarker(
        _ present: Bool,
        query: [String: Any],
        operation: String
    ) -> Bool {
        guard present else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        return saveData(Data([1]), query: query, operation: operation)
    }

    private func saveData(
        _ data: Data,
        query: [String: Any],
        operation: String
    ) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            report(operation: "update \(operation)", status: update)
            return false
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            report(operation: "add \(operation)", status: add)
            return false
        }
        return true
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private var bindingItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bindingService,
            kSecAttrAccount as String: account,
        ]
    }

    private var logoutItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.logoutService,
            kSecAttrAccount as String: account,
        ]
    }

    private var reauthenticationItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.reauthenticationService,
            kSecAttrAccount as String: account,
        ]
    }

    private var accountDeletionItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.accountDeletionService,
            kSecAttrAccount as String: account,
        ]
    }

    private var accountDeletionCleanupItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.accountDeletionCleanupService,
            kSecAttrAccount as String: account,
        ]
    }

    private func readData(query: [String: Any]) -> (data: Data?, isAvailable: Bool) {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data, result is Data)
        case errSecItemNotFound:
            return (nil, true)
        default:
            report(operation: "read auth state", status: status)
            return (nil, false)
        }
    }

    private func report(operation: String, status: OSStatus) {
        SentrySDK.capture(message: "ComiNavi session Keychain \(operation) failed: \(status)")
    }
}

/// Acquisition is SDK-specific and intentionally separate from server auth.
/// Implementations must provide the nonce used to mint the server entryGrant.
@MainActor
protocol CominaviGoogleIDTokenProviding {
    func idToken(nonce: String) async throws -> String
}
