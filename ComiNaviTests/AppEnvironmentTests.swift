import Foundation
import XCTest
@testable import ComiNavi

final class AppEnvironmentTests: XCTestCase {
    func testBuildsUseTheExpectedCirclemsEnvironment() {
        XCTAssertEqual(
            AppEnvironment.expectedCirclemsEnvironment(for: .debug),
            .production
        )
        XCTAssertEqual(
            AppEnvironment.expectedCirclemsEnvironment(for: .staging),
            .testing
        )
        XCTAssertEqual(
            AppEnvironment.expectedCirclemsEnvironment(for: .testFlight),
            .production
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
            AppEnvironment.storageNamespace(build: .staging, circlems: .testing),
            AppEnvironment.storageNamespace(build: .debug, circlems: .production)
        )
        XCTAssertEqual(
            AppEnvironment.storageNamespace(build: .debug, circlems: .production),
            "pre-release-v2/debug/production"
        )
        XCTAssertEqual(
            AppEnvironment.storageNamespace(build: .testFlight, circlems: .production),
            "pre-release-v2/testflight/production"
        )
    }

}
