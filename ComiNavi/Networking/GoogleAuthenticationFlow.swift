import Foundation
import Security

enum GoogleAuthenticationFlowError: LocalizedError, Equatable {
    case unavailable
    case expired
    case invalidIdentityToken
    case persistenceFailed
    case committedOrUnknown

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Sign in with Google is unavailable right now.")
        case .expired:
            String(localized: "The Sign in with Google request expired. Please try again.")
        case .invalidIdentityToken:
            String(localized: "We could not verify Google's sign-in response.")
        case .persistenceFailed:
            String(localized: "We could not securely save the Sign in with Google request.")
        case .committedOrUnknown:
            String(localized: "We are confirming the Sign in with Google result. No new sign-in was started.")
        }
    }
}

/// A protected, payload-bound Google authentication transaction. The ID token
/// and entry grant are retained only so an interrupted POST can retry the exact
/// request. They never enter UserDefaults or an account data database.
struct GoogleAuthenticationFlow: Codable, Equatable, Sendable {
    enum EntryContext: String, Codable, Equatable, Sendable {
        case invitation
        case special
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let nonce: String
    let entryContext: EntryContext
    let createdAt: Date
    var entryGrant: String?
    var entryGrantExpiresAt: Date?
    var idToken: String?
    var submissionAttemptedAt: Date?

    init(
        requestID: UUID,
        nonce: String,
        entryContext: EntryContext = .invitation,
        createdAt: Date,
        entryGrant: String? = nil,
        entryGrantExpiresAt: Date? = nil,
        idToken: String? = nil,
        submissionAttemptedAt: Date? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.requestID = requestID
        self.nonce = nonce
        self.entryContext = entryContext
        self.createdAt = createdAt
        self.entryGrant = entryGrant
        self.entryGrantExpiresAt = entryGrantExpiresAt
        self.idToken = idToken
        self.submissionAttemptedAt = submissionAttemptedAt
    }

    var isReadyToAuthenticate: Bool {
        entryGrant != nil && entryGrantExpiresAt != nil && idToken != nil
    }

    func validate(now: Date = Date()) throws {
        guard schemaVersion == Self.schemaVersion,
              Self.isCanonicalNonce(nonce),
              createdAt <= now.addingTimeInterval(60),
              createdAt > now.addingTimeInterval(
                  submissionAttemptedAt == nil ? -60 * 60 : -30 * 24 * 60 * 60
              )
        else { throw GoogleAuthenticationFlowError.expired }

        if entryGrant != nil || entryGrantExpiresAt != nil {
            guard let entryGrant,
                  entryGrant.utf8.count == 43,
                  entryGrant.unicodeScalars.allSatisfy(Self.isBase64URL),
                  let entryGrantExpiresAt,
                  entryGrantExpiresAt > now || submissionAttemptedAt != nil
            else { throw GoogleAuthenticationFlowError.expired }
        }
        if let idToken, idToken.isEmpty {
            throw GoogleAuthenticationFlowError.invalidIdentityToken
        }
    }

    static func isCanonicalNonce(_ value: String) -> Bool {
        (22...128).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy(isBase64URL)
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

protocol GoogleAuthenticationFlowStoring: Sendable {
    func load() throws -> GoogleAuthenticationFlow?
    func save(_ flow: GoogleAuthenticationFlow) throws
    func clear() throws
}

struct KeychainGoogleAuthenticationFlowStore: GoogleAuthenticationFlowStoring, Sendable {
    private static let service = "net.cominavi.google-authentication-flow"
    let account: String

    func load() throws -> GoogleAuthenticationFlow? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw GoogleAuthenticationFlowError.persistenceFailed
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let flow = try? decoder.decode(GoogleAuthenticationFlow.self, from: data)
            else { throw GoogleAuthenticationFlowError.persistenceFailed }
            return flow
        case errSecItemNotFound:
            return nil
        default:
            throw GoogleAuthenticationFlowError.persistenceFailed
        }
    }

    func save(_ flow: GoogleAuthenticationFlow) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(flow)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw GoogleAuthenticationFlowError.persistenceFailed
        }
        var item = itemQuery
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw GoogleAuthenticationFlowError.persistenceFailed
        }
    }

    func clear() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleAuthenticationFlowError.persistenceFailed
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

final class InMemoryGoogleAuthenticationFlowStore: GoogleAuthenticationFlowStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var flow: GoogleAuthenticationFlow?

    func load() throws -> GoogleAuthenticationFlow? { lock.withLock { flow } }
    func save(_ flow: GoogleAuthenticationFlow) throws {
        lock.withLock { self.flow = flow }
    }
    func clear() throws { lock.withLock { flow = nil } }
}

struct GoogleAuthenticationFlowCoordinator: Sendable {
    let storage: any GoogleAuthenticationFlowStoring
    var makeRequestID: @Sendable () -> UUID = UUID.init
    var makeNonce: @Sendable () throws -> String = GoogleAuthenticationNonce.make

    func prepare(
        entryContext: GoogleAuthenticationFlow.EntryContext = .invitation,
        now: Date = Date()
    ) throws -> GoogleAuthenticationFlow {
        if let existing = try storage.load() {
            do {
                try existing.validate(now: now)
                if existing.entryContext == entryContext {
                    // After the first POST, the protected bytes are the only
                    // safe way to recover a response whose commit is unknown.
                    // Provider/grant freshness gates the first send, not an
                    // idempotent receipt lookup with the same request body.
                    return existing
                }
                guard existing.submissionAttemptedAt == nil else {
                    throw GoogleAuthenticationFlowError.committedOrUnknown
                }
                try storage.clear()
            } catch GoogleAuthenticationFlowError.committedOrUnknown {
                throw GoogleAuthenticationFlowError.committedOrUnknown
            } catch {
                try storage.clear()
            }
        }
        let flow = GoogleAuthenticationFlow(
            requestID: makeRequestID(),
            nonce: try makeNonce(),
            entryContext: entryContext,
            createdAt: now
        )
        try flow.validate(now: now)
        try storage.save(flow)
        return flow
    }

    func recordEntryGrant(
        _ entryGrant: String,
        expiresAt: Date,
        for original: GoogleAuthenticationFlow,
        now: Date = Date()
    ) throws -> GoogleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.entryGrant == entryGrant,
                  stored.entryGrantExpiresAt == expiresAt
            else { throw GoogleAuthenticationFlowError.committedOrUnknown }
            return stored
        }
        guard entryGrant.utf8.count == 43,
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(10 * 60)
        else { throw GoogleAuthenticationFlowError.expired }
        stored.entryGrant = entryGrant
        stored.entryGrantExpiresAt = expiresAt
        try stored.validate(now: now)
        try storage.save(stored)
        return stored
    }

    func recordIDToken(
        _ idToken: String,
        for original: GoogleAuthenticationFlow,
        now: Date = Date()
    ) throws -> GoogleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.idToken == idToken else {
                throw GoogleAuthenticationFlowError.committedOrUnknown
            }
            return stored
        }
        guard stored.entryGrant != nil, !idToken.isEmpty else {
            throw GoogleAuthenticationFlowError.invalidIdentityToken
        }
        stored.idToken = idToken
        try stored.validate(now: now)
        try storage.save(stored)
        return stored
    }

    func recordSubmissionAttempt(
        for original: GoogleAuthenticationFlow,
        now: Date = Date()
    ) throws -> GoogleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.isReadyToAuthenticate else {
                throw GoogleAuthenticationFlowError.committedOrUnknown
            }
            return stored
        }
        guard stored.isReadyToAuthenticate,
              stored.entryGrantExpiresAt.map({ $0 > now }) == true
        else { throw GoogleAuthenticationFlowError.expired }
        stored.submissionAttemptedAt = now
        try storage.save(stored)
        return stored
    }

    func load(now: Date = Date()) throws -> GoogleAuthenticationFlow? {
        guard let flow = try storage.load() else { return nil }
        do {
            try flow.validate(now: now)
            return flow
        } catch {
            try storage.clear()
            return nil
        }
    }

    func clear() throws { try storage.clear() }

    private func requireStored(
        _ original: GoogleAuthenticationFlow,
        now: Date
    ) throws -> GoogleAuthenticationFlow {
        guard let stored = try storage.load(),
              stored.requestID == original.requestID,
              stored.nonce == original.nonce
        else { throw GoogleAuthenticationFlowError.persistenceFailed }
        try stored.validate(now: now)
        return stored
    }
}

enum GoogleSpecialEntryLink {
    static func isTrigger(_ url: URL) -> Bool {
        guard url.query == nil, url.fragment == nil, url.user == nil,
              url.password == nil, url.port == nil
        else { return false }
        if url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "cominavi.net"
        {
            return url.path == "/auth/google"
        }
        return url.scheme?.lowercased() == "cominavi"
            && url.host?.lowercased() == "auth"
            && url.path == "/google"
    }

    static func authorizationURL(nonce: String) -> URL? {
        guard GoogleAuthenticationFlow.isCanonicalNonce(nonce) else { return nil }
        var components = URLComponents(string: "https://cominavi.net/auth/google")
        components?.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        return components?.url
    }
}

enum GoogleEntryGrantCallbackParser {
    static func parse(
        _ url: URL,
        expectedNonce: String,
        now: Date = Date()
    ) throws -> CominaviGoogleEntryGrant {
        guard url.scheme?.lowercased() == "cominavi",
              url.host?.lowercased() == "auth",
              url.path == "/google/grant",
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 3,
              Set(items.map(\.name)) == Set(["entryGrant", "expiresAt", "nonce"]),
              Dictionary(grouping: items, by: \.name).values.allSatisfy({ $0.count == 1 }),
              let entryGrant = items.first(where: { $0.name == "entryGrant" })?.value,
              let expiresValue = items.first(where: { $0.name == "expiresAt" })?.value,
              let nonce = items.first(where: { $0.name == "nonce" })?.value,
              nonce == expectedNonce,
              entryGrant.utf8.count == 43,
              entryGrant.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }),
              let expiresAt = CominaviISO8601Date.parse(expiresValue),
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(10 * 60)
        else { throw GoogleAuthenticationFlowError.unavailable }
        return CominaviGoogleEntryGrant(entryGrant: entryGrant, expiresAt: expiresAt)
    }

    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "cominavi"
            && url.host?.lowercased() == "auth"
            && url.path == "/google/grant"
    }
}

enum GoogleAuthenticationNonce {
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw GoogleAuthenticationFlowError.persistenceFailed }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
