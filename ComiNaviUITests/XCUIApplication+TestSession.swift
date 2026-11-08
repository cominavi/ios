import XCTest

extension XCUIApplication {
    /// Signs the next launch in through the service's test identity provider
    /// (`-cominavi-test-session`), so a UI test starts signed in without any
    /// third-party OAuth.
    ///
    /// The service comes from the test runner's environment. Pass it to
    /// `xcodebuild test` with the `TEST_RUNNER_` prefix:
    ///
    ///     TEST_RUNNER_COMINAVI_TEST_SERVICE_ORIGIN=http://127.0.0.1:4380 \
    ///     TEST_RUNNER_COMINAVI_TEST_IDENTITY_SECRET=... xcodebuild test ...
    ///
    /// Skips the calling test when either value is missing. The origin must be
    /// loopback, `*.test` or staging; the app refuses anything else.
    func configureTestSession(label: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["COMINAVI_TEST_SERVICE_ORIGIN"], !origin.isEmpty,
              let secret = environment["COMINAVI_TEST_IDENTITY_SECRET"], !secret.isEmpty
        else {
            throw XCTSkip(
                "Set COMINAVI_TEST_SERVICE_ORIGIN and COMINAVI_TEST_IDENTITY_SECRET (TEST_RUNNER_ prefix) to run test-session UI tests."
            )
        }
        launchArguments += [
            "-cominavi-service-origin", origin,
            "-cominavi-test-session", label,
        ]
        launchEnvironment["COMINAVI_TEST_IDENTITY_SECRET"] = secret
    }
}
