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

enum CirclemsServiceEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case testing
    case production

    var id: Self { self }

    var apiValue: String {
        self == .production ? "production" : "sandbox"
    }

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
    // The app has not shipped yet. Keep pre-release persisted credentials and
    // databases behind an explicit epoch so an incompatible authentication
    // contract can start cleanly without deleting unrelated Keychain items.
    private static let storageEpoch = "pre-release-v2"

    static let current = load()

    let build: AppBuildEnvironment
    let circlems: CirclemsServiceEnvironment
    let oauthCallbackScheme: String
    /// The ComiNavi service origin. Always production in TestFlight/App Store
    /// builds; see `CominaviServiceOriginSwitch` for Debug and Staging.
    let serviceOrigin: URL

    var storageNamespace: String {
        Self.storageNamespace(build: build, circlems: circlems, serviceOrigin: serviceOrigin)
    }

    /// Path components under `environments/` for environment-scoped files.
    var storageDirectoryComponents: [String] {
        Self.storageDirectoryComponents(build: build, circlems: circlems, serviceOrigin: serviceOrigin)
    }

    /// Keychain accounts and defaults keys are bound to the build, the
    /// Circle.ms environment and the service origin, so a production session
    /// or cache is never read or sent while the app targets another origin,
    /// and the other way round. Production keeps its original namespace.
    static func storageNamespace(
        build: AppBuildEnvironment,
        circlems: CirclemsServiceEnvironment,
        serviceOrigin: URL = CominaviServiceOrigin.production
    ) -> String {
        ([storageEpoch] + storageDirectoryComponents(
            build: build,
            circlems: circlems,
            serviceOrigin: serviceOrigin
        )).joined(separator: "/")
    }

    static func storageDirectoryComponents(
        build: AppBuildEnvironment,
        circlems: CirclemsServiceEnvironment,
        serviceOrigin: URL = CominaviServiceOrigin.production
    ) -> [String] {
        var components = [build.rawValue, circlems.rawValue]
        if let origin = CominaviServiceOrigin.storageComponent(for: serviceOrigin) {
            components.append(origin)
        }
        return components
    }

    static func expectedCirclemsEnvironment(
        for build: AppBuildEnvironment
    ) -> CirclemsServiceEnvironment {
        switch build {
        case .debug, .testFlight:
            .production
        case .staging:
            .testing
        }
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
        let expectedCirclemsEnvironment = expectedCirclemsEnvironment(for: build)
        precondition(
            circlems == expectedCirclemsEnvironment,
            "Circle.ms environment \(circlems.rawValue) is invalid for the \(build.rawValue) build."
        )

        let callbackScheme = requiredString(key: "ComiNaviOAuthCallbackScheme", bundle: bundle)
        let configuredOrigin = requiredString(key: "ComiNaviServiceBaseURL", bundle: bundle)
        return AppEnvironment(
            build: build,
            circlems: circlems,
            oauthCallbackScheme: callbackScheme,
            serviceOrigin: resolveServiceOrigin(configured: configuredOrigin)
        )
    }

    private static func resolveServiceOrigin(configured: String) -> URL {
        #if COMINAVI_TESTFLIGHT
        // Release builds have no origin switch: the origin is fixed at compile
        // time, and the Info.plist value must agree with it.
        precondition(
            URL(string: configured).map(CominaviServiceOrigin.isProduction) == true,
            "TestFlight builds must use \(CominaviServiceOrigin.production.absoluteString)."
        )
        return CominaviServiceOrigin.production
        #else
        let processInfo = ProcessInfo.processInfo
        do {
            return try CominaviServiceOriginSwitch.resolve(
                configured: configured,
                arguments: processInfo.arguments,
                environment: processInfo.environment
            )
        } catch {
            // Never fall back to production after an explicit request for
            // another origin: that is exactly the write we want to prevent.
            preconditionFailure("Refusing ComiNavi service origin: \(error)")
        }
        #endif
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
