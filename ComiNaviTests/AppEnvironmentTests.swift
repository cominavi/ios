import Foundation
import XCTest
@testable import ComiNavi

final class AppEnvironmentTests: XCTestCase {
    func testDebugBuildAcceptsValidRuntimeOverride() {
        XCTAssertEqual(
            AppEnvironment.resolveCirclemsEnvironment(
                build: .debug,
                configured: .testing,
                debugOverrideRawValue: CirclemsServiceEnvironment.production.rawValue,
                debugOverridesEnabled: true
            ),
            .production
        )
    }

    func testRuntimeOverrideIsIgnoredOutsideDebugBuild() {
        let cases: [(
            build: AppBuildEnvironment,
            configured: CirclemsServiceEnvironment,
            attemptedOverride: CirclemsServiceEnvironment
        )] = [
            (.staging, .testing, .production),
            (.testFlight, .production, .testing),
        ]

        for testCase in cases {
            XCTAssertEqual(
                AppEnvironment.resolveCirclemsEnvironment(
                    build: testCase.build,
                    configured: testCase.configured,
                    debugOverrideRawValue: testCase.attemptedOverride.rawValue,
                    debugOverridesEnabled: true
                ),
                testCase.configured
            )
        }
    }

    func testInvalidOrDisabledRuntimeOverrideUsesConfiguredEnvironment() {
        XCTAssertEqual(
            AppEnvironment.resolveCirclemsEnvironment(
                build: .debug,
                configured: .testing,
                debugOverrideRawValue: "unsupported",
                debugOverridesEnabled: true
            ),
            .testing
        )
        XCTAssertEqual(
            AppEnvironment.resolveCirclemsEnvironment(
                build: .debug,
                configured: .testing,
                debugOverrideRawValue: CirclemsServiceEnvironment.production.rawValue,
                debugOverridesEnabled: false
            ),
            .testing
        )
    }

    func testCirclemsEnvironmentsUseDistinctEndpointsAndStorageNamespaces() {
        XCTAssertEqual(
            CirclemsServiceEnvironment.testing.authenticationBaseURL.host(),
            "auth1-sandbox.circle.ms"
        )
        XCTAssertEqual(
            CirclemsServiceEnvironment.production.authenticationBaseURL.host(),
            "auth1.circle.ms"
        )
        XCTAssertEqual(
            CirclemsServiceEnvironment.testing.apiBaseURL.host(),
            "api1-sandbox.circle.ms"
        )
        XCTAssertEqual(
            CirclemsServiceEnvironment.production.apiBaseURL.host(),
            "api1.circle.ms"
        )
        XCTAssertNotEqual(
            AppEnvironment.storageNamespace(build: .debug, circlems: .testing),
            AppEnvironment.storageNamespace(build: .debug, circlems: .production)
        )
    }

    func testAuthorizationURLUsesSelectedServiceAndRequiredParameters() throws {
        let redirectURL = try XCTUnwrap(URL(string: "https://example.com/oauth/circlems"))
        let cases: [(environment: CirclemsServiceEnvironment, host: String)] = [
            (.testing, "auth1-sandbox.circle.ms"),
            (.production, "auth1.circle.ms"),
        ]

        for testCase in cases {
            let url = try XCTUnwrap(
                CirclemsAuthorizationURLBuilder.makeURL(
                    serviceEnvironment: testCase.environment,
                    clientID: "client-id",
                    redirectURL: redirectURL,
                    state: "oauth-state"
                )
            )
            let components = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )

            XCTAssertEqual(components.host, testCase.host)
            XCTAssertEqual(components.path, "/OAuth2/")
            XCTAssertEqual(query["response_type"], "code")
            XCTAssertEqual(query["client_id"], "client-id")
            XCTAssertEqual(query["redirect_uri"], redirectURL.absoluteString)
            XCTAssertEqual(query["scope"], "circle_read favorite_read favorite_write user_info")
            XCTAssertEqual(query["state"], "oauth-state")
        }
    }
}
