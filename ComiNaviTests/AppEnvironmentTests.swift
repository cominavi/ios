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
        XCTAssertEqual(
            AppEnvironment.storageNamespace(build: .testFlight, circlems: .production),
            "pre-release-v2/testflight/production"
        )
    }

}
