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

enum CirclemsServiceEnvironment: String, Sendable {
    case testing
    case production

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

    let build: AppBuildEnvironment
    let circlems: CirclemsServiceEnvironment
    let circlemsClientID: String
    let oauthRedirectURL: URL
    let oauthCallbackScheme: String
    let circlemsTokenRefreshURL: URL

    var storageNamespace: String {
        "\(build.rawValue)/\(circlems.rawValue)"
    }

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
        precondition(
            circlems == .testing,
            "Circle.ms production is disabled until a production build and production OAuth credentials are added."
        )

        let clientID = requiredString(key: "ComiNaviCirclemsClientID", bundle: bundle)
        let redirectURL = requiredURL(key: "ComiNaviOAuthRedirectURL", bundle: bundle)
        let callbackScheme = requiredString(key: "ComiNaviOAuthCallbackScheme", bundle: bundle)
        let refreshURL = requiredURL(key: "ComiNaviCirclemsTokenRefreshURL", bundle: bundle)

        precondition(redirectURL.scheme == "https", "The OAuth redirect URL must use HTTPS.")
        precondition(refreshURL.scheme == "https", "The token refresh URL must use HTTPS.")

        return AppEnvironment(
            build: build,
            circlems: circlems,
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
