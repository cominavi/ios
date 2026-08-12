import XCTest

@testable import ComiNavi

final class FollowingImportAPITests: XCTestCase {
    func testClientDelegatesOnlyTheNormalizedUserNameToServiceSessionAuthority() async throws {
        let payload = FollowingImportPayload(
            twitterUserName: "owner",
            importedAt: Date(timeIntervalSince1970: 1_754_697_600),
            nextAllowedAt: Date(timeIntervalSince1970: 1_754_719_200),
            followings: [FollowingAccount(
                id: "x-1",
                userName: "circle_a",
                name: "Circle A",
                url: URL(string: "https://x.com/circle_a")!,
                profilePicture: URL(string: "https://pbs.twimg.com/a.jpg")
            )],
            source: .twitterAPI
        )
        let service = FollowingImportServiceStub(result: .success(payload))
        let client = FollowingImportAPIClient(service: service)

        let result = try await client.importFollowings(twitterUserName: "owner")
        let requestedUserNames = await service.requestedUserNames()

        XCTAssertEqual(result, payload)
        XCTAssertEqual(requestedUserNames, ["owner"])
    }

    func testClientPreservesTypedServiceError() async throws {
        let nextAllowedAt = Date(timeIntervalSince1970: 1_754_719_200)
        let service = FollowingImportServiceStub(result: .failure(
            FollowingImportAPIError.server(
                code: "following_import_rate_limited",
                message: "Try later.",
                nextAllowedAt: nextAllowedAt
            )
        ))
        let client = FollowingImportAPIClient(service: service)

        do {
            _ = try await client.importFollowings(twitterUserName: "owner")
            XCTFail("Expected the typed service error")
        } catch FollowingImportAPIError.server(let code, let message, let retryAt) {
            XCTAssertEqual(code, "following_import_rate_limited")
            XCTAssertEqual(message, "Try later.")
            XCTAssertEqual(retryAt, nextAllowedAt)
        }
    }

    func testFollowingLimitErrorUsesLocalizedUserMessage() {
        let error = FollowingImportAPIError.server(
            code: "twitter_following_limit_exceeded",
            message: "backend fallback",
            nextAllowedAt: nil
        )

        XCTAssertEqual(
            error.localizedDescription,
            "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts."
        )
    }
}

private actor FollowingImportServiceStub: FollowingImportServicing {
    private let result: Result<FollowingImportPayload, Error>
    private var userNames: [String] = []

    init(result: Result<FollowingImportPayload, Error>) {
        self.result = result
    }

    func importXFollowings(userName: String) async throws -> FollowingImportPayload {
        userNames.append(userName)
        return try result.get()
    }

    func requestedUserNames() -> [String] {
        userNames
    }
}
