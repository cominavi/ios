import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

enum AppleAuthenticationFlowError: LocalizedError, Equatable {
    case unavailable
    case expired
    case invalidCredential
    case persistenceFailed
    case committedOrUnknown

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Sign in with Apple is unavailable right now.")
        case .expired:
            String(localized: "The Sign in with Apple request expired. Please try again.")
        case .invalidCredential:
            String(localized: "We could not verify Apple's sign-in response.")
        case .persistenceFailed:
            String(localized: "We could not securely save the Sign in with Apple request.")
        case .committedOrUnknown:
            String(localized: "We are confirming the Sign in with Apple result. No new sign-in was started.")
        }
    }
}

/// The exact protected Apple request retained for response-loss recovery.
/// Apple identity and authorization tokens never enter preferences or an
/// account database and are removed only after the ComiNavi session and local
/// completion marker have been saved together.
struct AppleAuthenticationFlow: Codable, Equatable, Sendable {
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
    var identityToken: String?
    var authorizationCode: String?
    var displayName: String?
    var submissionAttemptedAt: Date?

    init(
        requestID: UUID,
        nonce: String,
        entryContext: EntryContext,
        createdAt: Date,
        entryGrant: String? = nil,
        entryGrantExpiresAt: Date? = nil,
        identityToken: String? = nil,
        authorizationCode: String? = nil,
        displayName: String? = nil,
        submissionAttemptedAt: Date? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.requestID = requestID
        self.nonce = nonce
        self.entryContext = entryContext
        self.createdAt = createdAt
        self.entryGrant = entryGrant
        self.entryGrantExpiresAt = entryGrantExpiresAt
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.displayName = displayName
        self.submissionAttemptedAt = submissionAttemptedAt
    }

    var isReadyToAuthenticate: Bool {
        entryGrant != nil && entryGrantExpiresAt != nil
            && identityToken != nil && authorizationCode != nil
    }

    func validate(now: Date = Date()) throws {
        guard schemaVersion == Self.schemaVersion,
              Self.isCanonicalNonce(nonce),
              createdAt <= now.addingTimeInterval(60),
              createdAt > now.addingTimeInterval(
                  submissionAttemptedAt == nil ? -60 * 60 : -30 * 24 * 60 * 60
              )
        else { throw AppleAuthenticationFlowError.expired }

        if entryGrant != nil || entryGrantExpiresAt != nil {
            guard let entryGrant,
                  entryGrant.utf8.count == 43,
                  entryGrant.unicodeScalars.allSatisfy(Self.isBase64URL),
                  let entryGrantExpiresAt,
                  entryGrantExpiresAt > now || submissionAttemptedAt != nil
            else { throw AppleAuthenticationFlowError.expired }
        }
        if identityToken != nil || authorizationCode != nil {
            guard let identityToken,
                  !identityToken.isEmpty,
                  identityToken.utf8.count <= 16_384,
                  let authorizationCode,
                  !authorizationCode.isEmpty,
                  authorizationCode.utf8.count <= 4_096
            else { throw AppleAuthenticationFlowError.invalidCredential }
        }
        if let displayName {
            let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.count <= 80 else {
                throw AppleAuthenticationFlowError.invalidCredential
            }
        }
    }

    static func isCanonicalNonce(_ value: String) -> Bool {
        value.utf8.count == 43 && value.unicodeScalars.allSatisfy(isBase64URL)
    }

    fileprivate static func isBase64URL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}

protocol AppleAuthenticationFlowStoring: Sendable {
    func load() throws -> AppleAuthenticationFlow?
    func save(_ flow: AppleAuthenticationFlow) throws
    func clear() throws
}

struct KeychainAppleAuthenticationFlowStore: AppleAuthenticationFlowStoring, Sendable {
    private static let service = "net.cominavi.apple-authentication-flow"
    let account: String

    func load() throws -> AppleAuthenticationFlow? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AppleAuthenticationFlowError.persistenceFailed
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let flow = try? decoder.decode(AppleAuthenticationFlow.self, from: data)
            else { throw AppleAuthenticationFlowError.persistenceFailed }
            return flow
        case errSecItemNotFound:
            return nil
        default:
            throw AppleAuthenticationFlowError.persistenceFailed
        }
    }

    func save(_ flow: AppleAuthenticationFlow) throws {
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
            throw AppleAuthenticationFlowError.persistenceFailed
        }
        var item = itemQuery
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw AppleAuthenticationFlowError.persistenceFailed
        }
    }

    func clear() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleAuthenticationFlowError.persistenceFailed
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

final class InMemoryAppleAuthenticationFlowStore: AppleAuthenticationFlowStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var flow: AppleAuthenticationFlow?

    func load() throws -> AppleAuthenticationFlow? { lock.withLock { flow } }
    func save(_ flow: AppleAuthenticationFlow) throws {
        lock.withLock { self.flow = flow }
    }
    func clear() throws { lock.withLock { flow = nil } }
}

struct AppleAuthenticationFlowCoordinator: Sendable {
    let storage: any AppleAuthenticationFlowStoring
    var makeRequestID: @Sendable () -> UUID = UUID.init
    var makeNonce: @Sendable () throws -> String = AppleAuthenticationNonce.make

    func prepare(
        entryContext: AppleAuthenticationFlow.EntryContext,
        now: Date = Date()
    ) throws -> AppleAuthenticationFlow {
        if let existing = try storage.load() {
            do {
                try existing.validate(now: now)
                if existing.entryContext == entryContext { return existing }
                guard existing.submissionAttemptedAt == nil else {
                    throw AppleAuthenticationFlowError.committedOrUnknown
                }
                try storage.clear()
            } catch AppleAuthenticationFlowError.committedOrUnknown {
                throw AppleAuthenticationFlowError.committedOrUnknown
            } catch {
                try storage.clear()
            }
        }
        let flow = AppleAuthenticationFlow(
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
        for original: AppleAuthenticationFlow,
        now: Date = Date()
    ) throws -> AppleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.entryGrant == entryGrant,
                  stored.entryGrantExpiresAt == expiresAt
            else { throw AppleAuthenticationFlowError.committedOrUnknown }
            return stored
        }
        guard entryGrant.utf8.count == 43,
              entryGrant.unicodeScalars.allSatisfy(AppleAuthenticationFlow.isBase64URL),
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(10 * 60)
        else { throw AppleAuthenticationFlowError.expired }
        stored.entryGrant = entryGrant
        stored.entryGrantExpiresAt = expiresAt
        try stored.validate(now: now)
        try storage.save(stored)
        return stored
    }

    func recordCredential(
        _ credential: AppleAuthorizationCredential,
        for original: AppleAuthenticationFlow,
        now: Date = Date()
    ) throws -> AppleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.identityToken == credential.identityToken,
                  stored.authorizationCode == credential.authorizationCode,
                  stored.displayName == credential.displayName
            else { throw AppleAuthenticationFlowError.committedOrUnknown }
            return stored
        }
        guard stored.entryGrant != nil else {
            throw AppleAuthenticationFlowError.invalidCredential
        }
        try AppleIdentityTokenValidation.validateNonce(stored.nonce, in: credential.identityToken)
        stored.identityToken = credential.identityToken
        stored.authorizationCode = credential.authorizationCode
        stored.displayName = credential.displayName
        try stored.validate(now: now)
        try storage.save(stored)
        return stored
    }

    func recordSubmissionAttempt(
        for original: AppleAuthenticationFlow,
        now: Date = Date()
    ) throws -> AppleAuthenticationFlow {
        var stored = try requireStored(original, now: now)
        if stored.submissionAttemptedAt != nil {
            guard stored.isReadyToAuthenticate else {
                throw AppleAuthenticationFlowError.committedOrUnknown
            }
            return stored
        }
        guard stored.isReadyToAuthenticate,
              stored.entryGrantExpiresAt.map({ $0 > now }) == true
        else { throw AppleAuthenticationFlowError.expired }
        stored.submissionAttemptedAt = now
        try storage.save(stored)
        return stored
    }

    func load(now: Date = Date()) throws -> AppleAuthenticationFlow? {
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
        _ original: AppleAuthenticationFlow,
        now: Date
    ) throws -> AppleAuthenticationFlow {
        guard let stored = try storage.load(),
              stored.requestID == original.requestID,
              stored.nonce == original.nonce
        else { throw AppleAuthenticationFlowError.persistenceFailed }
        try stored.validate(now: now)
        return stored
    }
}

struct AppleAuthorizationCredential: Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String
    let displayName: String?
}

enum AppleIdentityTokenValidation {
    static func validateNonce(_ rawNonce: String, in token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payload = decodeBase64URL(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let nonce = claims["nonce"] as? String,
              nonce.lowercased() == AppleAuthenticationNonce.sha256(rawNonce)
        else { throw AppleAuthenticationFlowError.invalidCredential }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

enum AppleSpecialEntryLink {
    static func isTrigger(_ url: URL) -> Bool {
        guard url.query == nil, url.fragment == nil, url.user == nil,
              url.password == nil, url.port == nil
        else { return false }
        if url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "cominavi.net"
        {
            return url.path == "/auth/apple"
        }
        return url.scheme?.lowercased() == "cominavi"
            && url.host?.lowercased() == "auth"
            && url.path == "/apple"
    }

    static func authorizationURL(nonce: String) -> URL? {
        guard AppleAuthenticationFlow.isCanonicalNonce(nonce) else { return nil }
        var components = URLComponents(string: "https://cominavi.net/auth/apple")
        components?.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        return components?.url
    }
}

enum AppleEntryGrantCallbackParser {
    static func parse(
        _ url: URL,
        expectedNonce: String,
        now: Date = Date()
    ) throws -> CominaviAppleEntryGrant {
        guard url.scheme?.lowercased() == "cominavi",
              url.host?.lowercased() == "auth",
              url.path == "/apple/grant",
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
              entryGrant.unicodeScalars.allSatisfy(AppleAuthenticationFlow.isBase64URL),
              let expiresAt = CominaviISO8601Date.parse(expiresValue),
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(10 * 60)
        else { throw AppleAuthenticationFlowError.unavailable }
        return CominaviAppleEntryGrant(entryGrant: entryGrant, expiresAt: expiresAt)
    }

    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "cominavi"
            && url.host?.lowercased() == "auth"
            && url.path == "/apple/grant"
    }
}

enum AppleAuthenticationNonce {
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw AppleAuthenticationFlowError.persistenceFailed }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class AppleSignInAuthorizationProvider: NSObject,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<AppleAuthorizationCredential, Error>?
    private var controller: ASAuthorizationController?

    func credential(nonce: String) async throws -> AppleAuthorizationCredential {
        guard continuation == nil, AppleAuthenticationFlow.isCanonicalNonce(nonce) else {
            throw AppleAuthenticationFlowError.unavailable
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleAuthenticationNonce.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let appleID = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityData = appleID.identityToken,
              let identityToken = String(data: identityData, encoding: .utf8),
              let codeData = appleID.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8),
              !identityToken.isEmpty,
              !authorizationCode.isEmpty
        else {
            finish(.failure(AppleAuthenticationFlowError.invalidCredential))
            return
        }
        let name = appleID.fullName.flatMap { components -> String? in
            let value = PersonNameComponentsFormatter.localizedString(
                from: components,
                style: .default,
                options: []
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        finish(.success(AppleAuthorizationCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            displayName: name
        )))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<AppleAuthorizationCredential, Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

/// Uses Apple's required native control while allowing the app to acquire the
/// short-lived ComiNavi entry grant before presenting the Apple sheet.
struct AppleSignInControl: UIViewRepresentable {
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        button.cornerRadius = 12
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.activate),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) { self.action = action }

        @objc func activate() { action() }
    }
}
