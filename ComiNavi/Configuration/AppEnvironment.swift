//
//  AppEnvironment.swift
//  ComiNavi
//

import Foundation

enum AppBuildEnvironment: String, Sendable {
    case debug
    case staging
    case testFlight = "testflight"
}

enum CirclemsServiceEnvironment: String, CaseIterable, Identifiable, Sendable {
    case testing
    case production

    var id: Self { self }

    var displayName: LocalizedStringResource {
        switch self {
        case .testing:
            "Testing"
        case .production:
            "Production"
        }
    }

    var signInDescription: LocalizedStringResource {
        switch self {
        case .testing:
            "Uses Circle.ms sandbox authentication and catalog data."
        case .production:
            "Uses live Circle.ms authentication and catalog data."
        }
    }

    var authenticationBaseURL: URL {
        switch self {
        case .testing:
            URL(string: "https://auth1-sandbox.circle.ms")!
        case .production:
            URL(string: "https://auth1.circle.ms")!
        }
    }

    var apiBaseURL: URL {
        switch self {
        case .testing:
            URL(string: "https://api1-sandbox.circle.ms")!
        case .production:
            URL(string: "https://api1.circle.ms")!
        }
    }
}

struct AppEnvironment: Sendable {
    static let current = load()

    #if DEBUG
    static let debugCirclemsEnvironmentDefaultsKey = "AppEnvironment.debug.circlems-environment"
    #endif

    let build: AppBuildEnvironment
    private let configuredCirclems: CirclemsServiceEnvironment
    let circlemsClientID: String
    let oauthRedirectURL: URL
    let oauthCallbackScheme: String
    let circlemsTokenRefreshURL: URL

    var circlems: CirclemsServiceEnvironment {
        #if DEBUG
        Self.resolveCirclemsEnvironment(
            build: build,
            configured: configuredCirclems,
            debugOverrideRawValue: UserDefaults.standard.string(
                forKey: Self.debugCirclemsEnvironmentDefaultsKey
            ),
            debugOverridesEnabled: true
        )
        #else
        configuredCirclems
        #endif
    }

    var storageNamespace: String {
        Self.storageNamespace(build: build, circlems: circlems)
    }

    static func storageNamespace(
        build: AppBuildEnvironment,
        circlems: CirclemsServiceEnvironment
    ) -> String {
        "\(build.rawValue)/\(circlems.rawValue)"
    }

    static func resolveCirclemsEnvironment(
        build: AppBuildEnvironment,
        configured: CirclemsServiceEnvironment,
        debugOverrideRawValue: String?,
        debugOverridesEnabled: Bool
    ) -> CirclemsServiceEnvironment {
        guard debugOverridesEnabled,
              build == .debug,
              let debugOverrideRawValue,
              let override = CirclemsServiceEnvironment(rawValue: debugOverrideRawValue)
        else {
            return configured
        }
        return override
    }

    #if DEBUG
    static func setDebugCirclemsEnvironment(
        _ environment: CirclemsServiceEnvironment,
        defaults: UserDefaults = .standard
    ) {
        guard current.build == .debug else { return }
        defaults.set(environment.rawValue, forKey: debugCirclemsEnvironmentDefaultsKey)
    }
    #endif

    private static var compiledBuild: AppBuildEnvironment {
        #if COMINAVI_TESTFLIGHT
        .testFlight
        #elseif COMINAVI_STAGING
        .staging
        #elseif DEBUG
        .debug
        #else
        #error("ComiNavi requires an explicit Debug, Staging, or TestFlight build environment.")
        #endif
    }

    private static func load(bundle: Bundle = .main) -> AppEnvironment {
        let build = requiredEnum(AppBuildEnvironment.self, key: "ComiNaviBuildEnvironment", bundle: bundle)
        let circlems = requiredEnum(CirclemsServiceEnvironment.self, key: "ComiNaviCirclemsEnvironment", bundle: bundle)

        precondition(
            build == compiledBuild,
            "Build-time environment \(compiledBuild.rawValue) does not match Info.plist environment \(build.rawValue)."
        )
        let expectedCirclemsEnvironment: CirclemsServiceEnvironment = switch build {
        case .debug, .staging:
            .testing
        case .testFlight:
            .production
        }
        precondition(
            circlems == expectedCirclemsEnvironment,
            "Circle.ms environment \(circlems.rawValue) is invalid for the \(build.rawValue) build."
        )

        let clientID = requiredString(key: "ComiNaviCirclemsClientID", bundle: bundle)
        let redirectURL = requiredURL(key: "ComiNaviOAuthRedirectURL", bundle: bundle)
        let callbackScheme = requiredString(key: "ComiNaviOAuthCallbackScheme", bundle: bundle)
        let refreshURL = requiredURL(key: "ComiNaviCirclemsTokenRefreshURL", bundle: bundle)

        precondition(redirectURL.scheme == "https", "The OAuth redirect URL must use HTTPS.")
        precondition(refreshURL.scheme == "https", "The token refresh URL must use HTTPS.")

        return AppEnvironment(
            build: build,
            configuredCirclems: circlems,
            circlemsClientID: clientID,
            oauthRedirectURL: redirectURL,
            oauthCallbackScheme: callbackScheme,
            circlemsTokenRefreshURL: refreshURL
        )
    }

    private static func requiredString(key: String, bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("$(")
        else {
            preconditionFailure("Missing build setting-backed Info.plist value for \(key).")
        }
        return value
    }

    private static func requiredURL(key: String, bundle: Bundle) -> URL {
        let value = requiredString(key: key, bundle: bundle)
        guard let url = URL(string: value), url.host != nil else {
            preconditionFailure("Invalid URL configured for \(key): \(value)")
        }
        return url
    }

    private static func requiredEnum<T: RawRepresentable>(
        _ type: T.Type,
        key: String,
        bundle: Bundle
    ) -> T where T.RawValue == String {
        let value = requiredString(key: key, bundle: bundle)
        guard let result = T(rawValue: value) else {
            preconditionFailure("Unsupported value for \(key): \(value)")
        }
        return result
    }
}
