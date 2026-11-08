//
//  CominaviTestSession.swift
//  ComiNavi
//

#if DEBUG
import Foundation

/// Debug-only sign-in through the service's test identity provider
/// (`POST /api/v2/auth/test/session`, staging and local dev only).
///
/// Launch with `-cominavi-test-session <label>` together with a non-production
/// `-cominavi-service-origin`, and put the service's test identity secret in
/// the `COMINAVI_TEST_IDENTITY_SECRET` environment variable (with `simctl`:
/// `SIMCTL_CHILD_COMINAVI_TEST_IDENTITY_SECRET`). The app signs in as the
/// stable test user named by `label` and installs the session through the
/// same protected persistence path as every other provider.
///
/// Allowed only when the service origin is loopback, a `*.test` host or the
/// staging host. Production is refused, and so is any malformed request: the
/// app stops instead of silently continuing signed out or signed in as
/// someone else. Compiled out of every non-Debug build.
enum CominaviTestSession {
    static let launchArgument = "-cominavi-test-session"
    static let secretEnvironmentVariable = "COMINAVI_TEST_IDENTITY_SECRET"
    static let secretHeader = "X-ComiNavi-Test-Identity-Secret"
    static let path = "api/v2/auth/test/session"

    struct Request: Equatable, Sendable {
        let label: String
        let secret: String
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case missingLabel
        case invalidLabel(String)
        case missingSecret
        case originNotAllowed(String)

        var description: String {
            switch self {
            case .missingLabel:
                "\(CominaviTestSession.launchArgument) needs a label."
            case let .invalidLabel(label):
                "Test session label \(label) must match ^[a-z0-9][a-z0-9-]{0,63}$."
            case .missingSecret:
                "\(CominaviTestSession.launchArgument) needs the \(CominaviTestSession.secretEnvironmentVariable) environment variable."
            case let .originNotAllowed(origin):
                "Test sessions are refused for \(origin). Use a loopback, *.test or staging service origin."
            }
        }
    }

    /// The test session requested for this launch, or `nil` when the launch
    /// argument is absent.
    static func request(
        arguments: [String],
        environment: [String: String],
        serviceOrigin: URL
    ) throws -> Request? {
        guard let index = arguments.lastIndex(of: launchArgument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { throw Rejection.missingLabel }
        let label = arguments[valueIndex]
        guard isValidLabel(label) else { throw Rejection.invalidLabel(label) }
        guard let secret = environment[secretEnvironmentVariable], !secret.isEmpty else {
            throw Rejection.missingSecret
        }
        guard isAllowedOrigin(serviceOrigin) else {
            throw Rejection.originNotAllowed(serviceOrigin.absoluteString)
        }
        return Request(label: label, secret: secret)
    }

    static func isValidLabel(_ label: String) -> Bool {
        let scalars = Array(label.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        return isLowerAlphanumeric(scalars[0])
            && scalars.allSatisfy { isLowerAlphanumeric($0) || $0 == "-" }
    }

    /// Exactly the non-production origins the origin switch accepts:
    /// loopback, `*.test` and the staging host.
    static func isAllowedOrigin(_ origin: URL) -> Bool {
        guard !CominaviServiceOrigin.isProduction(origin),
              let validated = try? CominaviServiceOriginSwitch.validate(origin.absoluteString)
        else { return false }
        return !CominaviServiceOrigin.isProduction(validated)
    }

    /// Decodes the provider's session response. The service writes
    /// JavaScript `toISOString()` timestamps, which carry milliseconds.
    static func decodeSession(_ data: Data) throws -> CominaviAuthenticationSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 timestamp."
            )
        }
        do {
            return try decoder.decode(CominaviAuthenticationSession.self, from: data)
        } catch {
            throw CominaviServiceError.invalidResponse
        }
    }

    /// Signs in at launch when `-cominavi-test-session` is present. Call before
    /// the profile store loads so the rest of launch sees the new session.
    static func installIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        client: CominaviServiceClient = .shared,
        serviceOrigin: URL = AppEnvironment.current.serviceOrigin
    ) async {
        let request: Request?
        do {
            request = try self.request(
                arguments: arguments,
                environment: environment,
                serviceOrigin: serviceOrigin
            )
        } catch {
            fatalError("ComiNavi test session: \(error)")
        }
        guard let request else { return }
        do {
            let session = try await client.authenticateWithTestIdentity(
                label: request.label,
                secret: request.secret
            )
            print("ComiNavi test session: signed in as \(session.user?.id ?? "?") (\(request.label))")
        } catch {
            print("ComiNavi test session failed for \(request.label): \(error)")
        }
    }
}
#endif
