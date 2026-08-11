import CryptoKit
import Foundation
import Security

struct CirclemsAuthorizationFlow: Codable, Equatable, Sendable {
    enum Purpose: String, Codable, Sendable {
        case authenticate
        case link
    }

    static let schemaVersion = 1

    let version: Int
    let requestID: UUID
    let clientInstanceID: UUID
    let purpose: Purpose
    let environment: CirclemsServiceEnvironment
    let codeVerifier: String
    let codeChallenge: String
    let expectedPublicUserID: String?
    let createdAt: Date
    var authorizationURL: URL?
    var startExpiresAt: Date?
    var completionCode: String?
    var completionExpiresAt: Date?
    var submissionAttemptedAt: Date?

    init(
        requestID: UUID,
        clientInstanceID: UUID,
        purpose: Purpose,
        environment: CirclemsServiceEnvironment,
        codeVerifier: String,
        codeChallenge: String,
        expectedPublicUserID: String?,
        createdAt: Date
    ) {
        version = Self.schemaVersion
        self.requestID = requestID
        self.clientInstanceID = clientInstanceID
        self.purpose = purpose
        self.environment = environment
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.expectedPublicUserID = expectedPublicUserID
        self.createdAt = createdAt
    }

    var isReadyToComplete: Bool {
        completionCode != nil && completionExpiresAt != nil
    }
}

struct CirclemsAuthorizationStart: Decodable, Equatable, Sendable {
    let authorizationURL: URL
    let expiresAt: Date
}

struct CirclemsAuthenticationCompletion: Sendable {
    let session: CominaviAuthenticationSession
    let credentialReceipt: CirclemsCredentialReceipt
}

struct CirclemsLinkCompletion: Sendable {
    let profile: CominaviUserProfile
    let credentialReceipt: CirclemsCredentialReceipt
}

struct CirclemsPersistedAuthorizationCompletion: Sendable {
    let marker: CirclemsAuthorizationCompletionMarker
    let profile: CominaviUserProfile
}

enum CirclemsAuthorizationCallback: Equatable, Sendable {
    case succeeded(completionCode: String)
    case failed
}

enum CirclemsAuthorizationFlowError: LocalizedError, Equatable, Sendable {
    case invalidCallback
    case authorizationFailed
    case expired
    case flowPending

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            String(localized: "The login response could not be verified. Please try again.")
        case .authorizationFailed:
            String(localized: "Authentication failed. Please try again.")
        case .expired:
            String(localized: "The login request expired. Please try again.")
        case .flowPending:
            String(localized: "Another Circle.ms login is already in progress.")
        }
    }
}

enum CirclemsAuthorizationCallbackParser {
    private static let successKeys: Set<String> = ["status", "completionCode"]
    private static let failureKeys: Set<String> = ["status", "error"]
    private static let forbiddenProviderTokenKeys: Set<String> = [
        "access_token", "refresh_token", "token_type", "expires_in",
    ]

    static func isCallbackURL(_ url: URL, callbackScheme: String) -> Bool {
        url.scheme == callbackScheme
            && url.host == "oauth"
            && url.path == "/circlems/landing"
    }

    static func parse(
        _ url: URL,
        callbackScheme: String
    ) throws -> CirclemsAuthorizationCallback {
        guard isCallbackURL(url, callbackScheme: callbackScheme),
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else { throw CirclemsAuthorizationFlowError.invalidCallback }

        var values: [String: String] = [:]
        for item in queryItems {
            guard !Self.forbiddenProviderTokenKeys.contains(item.name),
                  values[item.name] == nil,
                  let value = item.value,
                  !value.isEmpty
            else { throw CirclemsAuthorizationFlowError.invalidCallback }
            values[item.name] = value
        }

        guard let status = values["status"] else {
            throw CirclemsAuthorizationFlowError.invalidCallback
        }
        switch status {
        case "succeeded":
            guard Set(values.keys) == successKeys,
                  let completionCode = values["completionCode"]
            else { throw CirclemsAuthorizationFlowError.invalidCallback }
            return .succeeded(completionCode: completionCode)
        case "failed":
            guard Set(values.keys) == failureKeys,
                  values["error"] == "authorization_failed"
            else { throw CirclemsAuthorizationFlowError.invalidCallback }
            return .failed
        default:
            throw CirclemsAuthorizationFlowError.invalidCallback
        }
    }
}

enum CirclemsPKCE {
    static func generate() throws -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let verifier = Data(bytes).base64URLEncodedString
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }
}

protocol CirclemsAuthorizationFlowPersisting: Sendable {
    func load() throws -> CirclemsAuthorizationFlow?
    func save(_ flow: CirclemsAuthorizationFlow) throws
    func clear() throws
}

protocol CirclemsClientInstanceIDPersisting: Sendable {
    func loadOrCreate() throws -> UUID
}

struct KeychainCirclemsClientInstanceIDStore: CirclemsClientInstanceIDPersisting, Sendable {
    private static let service = "net.cominavi.circlems-client-instance"
    let account: String

    func loadOrCreate() throws -> UUID {
        if let existing = try load() { return existing }
        let created = UUID()
        let value = created.uuidString.lowercased()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var item = itemQuery
        attributes.forEach { item[$0.key] = $0.value }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return created }
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        throw CominaviServiceError.authenticationStorageUnavailable
    }

    private func load() throws -> UUID? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: value),
                  value == uuid.uuidString.lowercased()
            else { throw CominaviServiceError.authenticationStorageUnavailable }
            return uuid
        case errSecItemNotFound:
            return nil
        default:
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryCirclemsClientInstanceIDStore: @unchecked Sendable,
    CirclemsClientInstanceIDPersisting
{
    private let lock = NSLock()
    private var value: UUID?

    init(value: UUID? = nil) { self.value = value }

    func loadOrCreate() -> UUID {
        lock.withLock {
            if let value { return value }
            let created = UUID()
            value = created
            return created
        }
    }
}

struct KeychainCirclemsAuthorizationFlowStore: CirclemsAuthorizationFlowPersisting, Sendable {
    private static let service = "net.cominavi.circlems-completion-flow"
    let account: String

    func load() throws -> CirclemsAuthorizationFlow? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CominaviServiceError.authenticationStorageUnavailable
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let flow = try? decoder.decode(CirclemsAuthorizationFlow.self, from: data),
                  flow.version == CirclemsAuthorizationFlow.schemaVersion
            else { throw CominaviServiceError.authenticationStorageUnavailable }
            return flow
        case errSecItemNotFound:
            return nil
        default:
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    func save(_ flow: CirclemsAuthorizationFlow) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(flow)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        var item = itemQuery
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    func clear() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryCirclemsAuthorizationFlowStore: @unchecked Sendable,
    CirclemsAuthorizationFlowPersisting
{
    private let lock = NSLock()
    private var value: CirclemsAuthorizationFlow?

    func load() -> CirclemsAuthorizationFlow? { lock.withLock { value } }
    func save(_ flow: CirclemsAuthorizationFlow) { lock.withLock { value = flow } }
    func clear() { lock.withLock { value = nil } }
}

struct CirclemsAuthorizationFlowCoordinator: Sendable {
    private let storage: any CirclemsAuthorizationFlowPersisting
    private let makePKCE: @Sendable () throws -> (verifier: String, challenge: String)

    init(
        storage: any CirclemsAuthorizationFlowPersisting,
        makePKCE: @escaping @Sendable () throws -> (verifier: String, challenge: String) = {
            try CirclemsPKCE.generate()
        }
    ) {
        self.storage = storage
        self.makePKCE = makePKCE
    }

    func prepare(
        purpose: CirclemsAuthorizationFlow.Purpose,
        environment: CirclemsServiceEnvironment,
        clientInstanceID: UUID,
        expectedPublicUserID: String?,
        now: Date = Date()
    ) throws -> CirclemsAuthorizationFlow {
        if let existing = try storage.load() {
            if isExpired(existing, now: now) {
                try storage.clear()
            } else if existing.purpose == purpose,
                      existing.environment == environment,
                      existing.clientInstanceID == clientInstanceID,
                      existing.expectedPublicUserID == expectedPublicUserID
            {
                return existing
            } else {
                throw CirclemsAuthorizationFlowError.flowPending
            }
        }
        let pkce = try makePKCE()
        guard pkce.verifier.utf8.count >= 43,
              pkce.verifier.utf8.count <= 128,
              pkce.challenge.utf8.count == 43
        else { throw CominaviServiceError.invalidResponse }
        let flow = CirclemsAuthorizationFlow(
            requestID: UUID(),
            clientInstanceID: clientInstanceID,
            purpose: purpose,
            environment: environment,
            codeVerifier: pkce.verifier,
            codeChallenge: pkce.challenge,
            expectedPublicUserID: expectedPublicUserID,
            createdAt: now
        )
        // The verifier and stable request ID cross the durable boundary before
        // either the start request or browser session can escape this process.
        try storage.save(flow)
        return flow
    }

    func recordStart(
        _ start: CirclemsAuthorizationStart,
        for original: CirclemsAuthorizationFlow,
        now: Date = Date()
    ) throws -> CirclemsAuthorizationFlow {
        guard var current = try storage.load(),
              sameFlow(current, original),
              start.authorizationURL.scheme?.lowercased() == "https",
              start.authorizationURL.host?.lowercased()
                == current.environment.authenticationBaseURL.host?.lowercased(),
              start.authorizationURL.port == current.environment.authenticationBaseURL.port,
              start.authorizationURL.user == nil,
              start.authorizationURL.password == nil,
              start.expiresAt > now,
              start.expiresAt.timeIntervalSince(now) <= 660
        else { throw CominaviServiceError.invalidResponse }
        current.authorizationURL = start.authorizationURL
        current.startExpiresAt = start.expiresAt
        try storage.save(current)
        return current
    }

    func recordCallback(
        _ callbackURL: URL,
        callbackScheme: String,
        for original: CirclemsAuthorizationFlow,
        now: Date = Date()
    ) throws -> CirclemsAuthorizationFlow {
        let callback = try CirclemsAuthorizationCallbackParser.parse(
            callbackURL,
            callbackScheme: callbackScheme
        )
        guard var current = try storage.load(),
              sameFlow(current, original),
              current.startExpiresAt.map({ $0 > now }) == true
        else { throw CirclemsAuthorizationFlowError.expired }

        switch callback {
        case .succeeded(let completionCode):
            guard completionCode.utf8.count <= 4_096
            else { throw CirclemsAuthorizationFlowError.invalidCallback }
            if current.completionCode == completionCode,
               current.completionExpiresAt.map({ $0 > now }) == true
            {
                return current
            }
            guard current.completionCode == nil else {
                throw CirclemsAuthorizationFlowError.invalidCallback
            }
            current.completionCode = completionCode
            current.completionExpiresAt = now.addingTimeInterval(120)
            // Persist the opaque one-time code before the completion request.
            // A lost response retries the exact request ID/verifier/code tuple.
            try storage.save(current)
            return current
        case .failed:
            try storage.clear()
            throw CirclemsAuthorizationFlowError.authorizationFailed
        }
    }

    func load(now: Date = Date()) throws -> CirclemsAuthorizationFlow? {
        guard let flow = try storage.load() else { return nil }
        guard !isExpired(flow, now: now) else {
            try storage.clear()
            return nil
        }
        return flow
    }

    func recordSubmissionAttempt(
        for original: CirclemsAuthorizationFlow,
        now: Date = Date()
    ) throws -> CirclemsAuthorizationFlow {
        guard var current = try storage.load(),
              sameFlow(current, original),
              current.isReadyToComplete
        else { throw CirclemsAuthorizationFlowError.expired }
        if current.submissionAttemptedAt != nil {
            return current
        }
        guard current.completionExpiresAt.map({ $0 > now }) == true else {
            throw CirclemsAuthorizationFlowError.expired
        }
        // Cross the protected durability boundary before the one-time
        // completion capability can reach the network. Exact retries retain
        // this immutable request/code/verifier tuple after capability expiry.
        current.submissionAttemptedAt = now
        try storage.save(current)
        return current
    }

    func clear() throws { try storage.clear() }

    private func isExpired(_ flow: CirclemsAuthorizationFlow, now: Date) -> Bool {
        if let submissionAttemptedAt = flow.submissionAttemptedAt {
            return submissionAttemptedAt.addingTimeInterval(30 * 24 * 60 * 60) <= now
        }
        if let completionExpiresAt = flow.completionExpiresAt {
            return completionExpiresAt <= now
        }
        if let startExpiresAt = flow.startExpiresAt {
            return startExpiresAt <= now
        }
        return flow.createdAt.addingTimeInterval(600) <= now
    }

    private func sameFlow(
        _ lhs: CirclemsAuthorizationFlow,
        _ rhs: CirclemsAuthorizationFlow
    ) -> Bool {
        lhs.version == rhs.version
            && lhs.requestID == rhs.requestID
            && lhs.clientInstanceID == rhs.clientInstanceID
            && lhs.purpose == rhs.purpose
            && lhs.environment == rhs.environment
            && lhs.codeVerifier == rhs.codeVerifier
            && lhs.codeChallenge == rhs.codeChallenge
            && lhs.expectedPublicUserID == rhs.expectedPublicUserID
    }
}
