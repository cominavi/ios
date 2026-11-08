//
//  CominaviServiceOrigin.swift
//  ComiNavi
//

import Foundation

/// The ComiNavi service origin (scheme, host and port) that this process talks
/// to. TestFlight and App Store builds always use production. Debug and
/// Staging builds may target a local or staging service instead, so agents and
/// developers can experiment without writing to production.
enum CominaviServiceOrigin {
    static let production = URL(string: "https://cominavi.net")!

    /// Reserved host for a hosted staging Worker. It is accepted by the
    /// non-release origin switch, but no staging deployment exists yet.
    static let stagingHost = "staging.cominavi.net"

    static func isProduction(_ origin: URL) -> Bool {
        origin.scheme?.lowercased() == "https"
            && origin.host?.lowercased() == production.host
            && (origin.port == nil || origin.port == 443)
    }

    /// Catalog artifacts must be downloaded over https. The only exception is
    /// a plain-http loopback service origin selected in a Debug/Staging build,
    /// and then only for URLs on exactly that origin.
    static func isAllowedDownloadURL(_ url: URL, serviceOrigin: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if COMINAVI_TESTFLIGHT
        return false
        #else
        return url.scheme?.lowercased() == "http"
            && serviceOrigin.scheme?.lowercased() == "http"
            && url.host?.lowercased() == serviceOrigin.host?.lowercased()
            && url.port == serviceOrigin.port
            && url.user == nil && url.password == nil
        #endif
    }

    /// The storage-namespace component that keeps sessions, flows, caches and
    /// account data of a non-production origin apart from production and from
    /// every other origin. Production returns `nil` so its existing storage
    /// keys and directories stay unchanged.
    static func storageComponent(for origin: URL) -> String? {
        guard !isProduction(origin) else { return nil }
        let scheme = origin.scheme?.lowercased() ?? "unknown"
        let host = (origin.host?.lowercased() ?? "unknown")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = origin.port.map(String.init) ?? "default"
        let raw = "origin-\(scheme)-\(host)-\(port)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return String(
            raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        )
    }
}

#if !COMINAVI_TESTFLIGHT
/// Debug/Staging-only service origin switch. It is compiled out of TestFlight
/// and App Store builds, which can only reach `https://cominavi.net`.
///
/// Select an origin with the launch argument
/// `-cominavi-service-origin http://127.0.0.1:8787` or the environment
/// variable `COMINAVI_SERVICE_ORIGIN` (the launch argument wins). Allowed:
///
/// - loopback (`127.0.0.1`, `::1`, `localhost`) over `http` or `https`, any port;
/// - `*.test` hosts over `https`, any port;
/// - the reserved staging host over `https`;
/// - production itself over `https`.
///
/// Anything else is refused. An invalid request stops the app instead of
/// silently falling back to production.
enum CominaviServiceOriginSwitch {
    static let launchArgument = "-cominavi-service-origin"
    static let environmentVariable = "COMINAVI_SERVICE_ORIGIN"

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case missingValue
        case malformed
        case notAnOrigin
        case unsupportedScheme(String)
        case hostNotAllowed(String)
        case insecureScheme(String)
        case unexpectedPort(String)

        var description: String {
            switch self {
            case .missingValue:
                "\(CominaviServiceOriginSwitch.launchArgument) needs an origin value."
            case .malformed:
                "The service origin is not a valid absolute URL."
            case .notAnOrigin:
                "The service origin must be scheme://host[:port] with no path, query, fragment or credentials."
            case let .unsupportedScheme(scheme):
                "Unsupported service origin scheme \(scheme). Use http (loopback only) or https."
            case let .hostNotAllowed(host):
                "Service origin host \(host) is not allowed. Use loopback, a *.test host or \(CominaviServiceOrigin.stagingHost)."
            case let .insecureScheme(host):
                "Service origin host \(host) requires https. Plain http is allowed only for loopback."
            case let .unexpectedPort(host):
                "Service origin host \(host) must use the default https port."
            }
        }
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// The raw origin requested for this launch, if any. `nil` means "use the
    /// configured default". A trailing launch argument without a value is a
    /// request too, and fails validation.
    static func requestedOrigin(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        if let index = arguments.lastIndex(of: launchArgument) {
            let valueIndex = arguments.index(after: index)
            return valueIndex < arguments.endIndex ? arguments[valueIndex] : ""
        }
        if let value = environment[environmentVariable] {
            return value
        }
        return nil
    }

    /// Validates a requested origin and returns its canonical form,
    /// `scheme://host[:port]` without a trailing slash.
    static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Rejection.missingValue }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host, !rawHost.isEmpty
        else {
            throw Rejection.malformed
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw Rejection.notAnOrigin
        }
        guard scheme == "http" || scheme == "https" else {
            throw Rejection.unsupportedScheme(scheme)
        }

        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = components.port
        if let port, !(1...65_535).contains(port) {
            throw Rejection.malformed
        }

        if loopbackHosts.contains(host) {
            // Loopback may use plain http and any port.
        } else if host == CominaviServiceOrigin.production.host || host == CominaviServiceOrigin.stagingHost {
            guard scheme == "https" else { throw Rejection.insecureScheme(host) }
            guard port == nil || port == 443 else { throw Rejection.unexpectedPort(host) }
        } else if isTestHost(host) {
            guard scheme == "https" else { throw Rejection.insecureScheme(host) }
        } else {
            throw Rejection.hostNotAllowed(host)
        }

        let urlHost = host.contains(":") ? "[\(host)]" : host
        let normalizedPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            ? nil : port
        let portSuffix = normalizedPort.map { ":\($0)" } ?? ""
        guard let origin = URL(string: "\(scheme)://\(urlHost)\(portSuffix)") else {
            throw Rejection.malformed
        }
        return origin
    }

    /// Resolves the origin for a Debug or Staging launch: the requested
    /// override if there is one, else the build's configured default. Both go
    /// through the same allow list.
    static func resolve(
        configured: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> URL {
        try validate(requestedOrigin(arguments: arguments, environment: environment) ?? configured)
    }

    /// `*.test` is reserved for testing (RFC 6761) and never resolves on the
    /// public internet. Require at least one label before it.
    private static func isTestHost(_ host: String) -> Bool {
        guard host.hasSuffix(".test") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
#endif
