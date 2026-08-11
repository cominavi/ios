import Foundation
import XCTest
@testable import ComiNavi

final class AppDataCirclemsTokenTests: XCTestCase {
    func testUnexpiredProviderAccessTokenRemainsAvailableForDirectCirclemsRequests() {
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let user = makeUser(
            accessToken: "  provider-access  ",
            accessTokenExpiresAt: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            AppData.availableCirclemsAccessToken(for: user, now: now),
            "provider-access"
        )
    }

    func testExpiredProviderAccessTokenIsUnavailableWithoutRotatingRefreshCredential() {
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let user = makeUser(
            accessToken: "expired-provider-access",
            accessTokenExpiresAt: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(AppData.availableCirclemsAccessToken(for: user, now: now), "")
        XCTAssertEqual(user.refreshToken, "preserved-provider-refresh")
    }

    func testBlankProviderAccessTokenIsUnavailableEvenBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let user = makeUser(
            accessToken: " \n\t ",
            accessTokenExpiresAt: now.addingTimeInterval(60)
        )

        XCTAssertEqual(AppData.availableCirclemsAccessToken(for: user, now: now), "")
    }

    func testProviderAccessTokenWithoutExpiryIsUnavailable() {
        let user = makeUser(
            accessToken: "provider-access",
            accessTokenExpiresAt: nil
        )

        XCTAssertEqual(AppData.availableCirclemsAccessToken(for: user), "")
    }

    private func makeUser(
        accessToken: String,
        accessTokenExpiresAt: Date?
    ) -> User {
        User(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshToken: "preserved-provider-refresh",
            userId: 42,
            nickname: "Circle.ms user",
            preferenceR18Enabled: false
        )
    }
}
