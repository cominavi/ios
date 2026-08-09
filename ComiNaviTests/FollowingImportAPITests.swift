import XCTest

@testable import ComiNavi

final class FollowingImportAPITests: XCTestCase {
    func testClientExchangesCirclemsTokenThenImportsBasicFollowingMetadata() async throws {
        let transport = FollowingImportTransportStub()
        let client = FollowingImportAPIClient(
            baseURL: URL(string: "https://cominavi.net")!,
            transport: { request in
                try await transport.response(for: request)
            }
        )

        let payload = try await client.importFollowings(
            twitterUserName: "owner",
            circlemsAccessToken: "circlems-token",
            circlemsEnvironment: .production
        )

        XCTAssertEqual(payload.twitterUserName, "owner")
        XCTAssertEqual(payload.source, .twitterAPI)
        XCTAssertEqual(payload.followings.map(\.userName), ["circle_a"])
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/v1/auth/circlems",
            "/api/v1/imports/x-followings",
        ])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer circlems-token", "Bearer cominavi-jwt"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[0].httpBody)),
            ["environment": "production"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[1].httpBody)),
            ["userName": "owner"]
        )
    }
}

private actor FollowingImportTransportStub {
    private var storedRequests: [URLRequest] = []

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        storedRequests.append(request)
        let body: String
        if storedRequests.count == 1 {
            body = #"{"accessToken":"cominavi-jwt"}"#
        } else {
            body = #"{"twitterUserName":"owner","importedAt":"2026-08-09T00:00:00Z","nextAllowedAt":"2026-08-09T06:00:00Z","followings":[{"id":"x-1","userName":"circle_a","name":"Circle A","url":"https://x.com/circle_a","profilePicture":"https://pbs.twimg.com/a.jpg"}],"source":"twitterapi.io"}"#
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] {
        storedRequests
    }
}
