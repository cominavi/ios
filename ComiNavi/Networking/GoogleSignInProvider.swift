import Foundation
import GoogleSignIn
import UIKit

struct GoogleSignInConfiguration: Equatable, Sendable {
    let clientID: String
    let callbackScheme: String

    static func load(bundle: Bundle = .main) -> Self? {
        load(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func load(infoDictionary: [String: Any]) -> Self? {
        guard let clientID = infoDictionary["GIDClientID"] as? String,
              !clientID.isEmpty,
              !clientID.contains("$("),
              let callbackScheme = callbackScheme(for: clientID),
              configuredSchemes(in: infoDictionary).contains(callbackScheme)
        else { return nil }
        return Self(clientID: clientID, callbackScheme: callbackScheme)
    }

    static func callbackScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let prefix = clientID.dropLast(suffix.count)
        guard !prefix.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(prefix)"
    }

    private static func configuredSchemes(in info: [String: Any]) -> Set<String> {
        guard let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] })
    }
}

enum GoogleIdentityTokenValidation {
    static func validateNonce(_ expectedNonce: String, in token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payload = decodeBase64URL(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["nonce"] as? String == expectedNonce
        else { throw GoogleAuthenticationFlowError.invalidIdentityToken }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

@MainActor
final class GoogleSignInIDTokenProvider: CominaviGoogleIDTokenProviding {
    private let configuration: GoogleSignInConfiguration

    init(configuration: GoogleSignInConfiguration? = .load()) throws {
        guard let configuration else { throw GoogleAuthenticationFlowError.unavailable }
        self.configuration = configuration
    }

    func idToken(nonce: String) async throws -> String {
        guard GoogleAuthenticationFlow.isCanonicalNonce(nonce),
              let presenter = Self.presentingViewController()
        else { throw GoogleAuthenticationFlowError.unavailable }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: configuration.clientID
        )
        let token: String = try await withCheckedThrowingContinuation {
            continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: nil,
                nonce: nonce,
                claims: nil
            ) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = result?.user.idToken?.tokenString,
                          !token.isEmpty
                {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(
                        throwing: GoogleAuthenticationFlowError.invalidIdentityToken
                    )
                }
            }
        }
        try GoogleIdentityTokenValidation.validateNonce(nonce, in: token)
        return token
    }

    static func handle(_ url: URL) -> Bool {
        guard let configuration = GoogleSignInConfiguration.load(),
              url.scheme?.caseInsensitiveCompare(configuration.callbackScheme) == .orderedSame
        else { return false }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: configuration.clientID
        )
        return GIDSignIn.sharedInstance.handle(url)
    }

    static func signOut() {
        guard GoogleSignInConfiguration.load() != nil else { return }
        GIDSignIn.sharedInstance.signOut()
    }

    static func disconnect() async {
        guard GoogleSignInConfiguration.load() != nil else { return }
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.disconnect { _ in
                GIDSignIn.sharedInstance.signOut()
                continuation.resume()
            }
        }
    }

    private static func presentingViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var presented = root
        while let next = presented?.presentedViewController {
            presented = next
        }
        return presented
    }
}
