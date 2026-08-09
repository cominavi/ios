@testable import ComiNavi
import XCTest

final class CominaviServiceClientTests: XCTestCase {
    func testAuthenticatesOnceThenSynchronizesFavoritesAndReadsRealtimeCursor() async throws {
        let transport = CominaviServiceTransportStub()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in
                try await transport.response(for: request)
            },
            circlemsTokenProvider: { "circlems-token" },
            circlemsEnvironmentProvider: { .production }
        )
        let bookmark = MapBookmark(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            catalogCircleID: 100,
            updateID: 100,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 1, spaceNumber: 1),
            subspace: 0,
            color: .magenta,
            memo: "",
            modifiedAt: Date(),
            syncState: .synced
        )

        try await client.synchronizeFavorites(
            eventNumber: 108,
            bookmarks: [bookmark]
        )
        let page = try await client.realtimeUpdates(eventNumber: 108, after: 40)
        try await client.revokeSession()

        XCTAssertEqual(page.nextCursor, 41)
        XCTAssertEqual(page.updates.first?.stateValue, "sold_out")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/v1/auth/circlems",
            "/api/v1/me/favorites/108",
            "/api/v1/me/favorites/108",
            "/api/v1/events/108/updates",
            "/api/v1/auth/logout",
        ])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            [
                "Bearer circlems-token",
                "Bearer service-jwt",
                "Bearer service-jwt",
                "Bearer service-jwt",
                "Bearer service-jwt",
            ]
        )
        let mutation = try XCTUnwrap(requests[2].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mutation) as? [String: Any]
        )
        let favorites = try XCTUnwrap(object["favorites"] as? [[String: Any]])
        XCTAssertEqual(favorites.first?["wcID"] as? Int, 23_000_001)
        XCTAssertEqual(favorites.first?["color"] as? Int, BookmarkColor.magenta.rawValue)
        XCTAssertEqual(favorites.first?["notificationsEnabled"] as? Bool, true)
    }
}

private actor CominaviServiceTransportStub {
    private var storedRequests: [URLRequest] = []

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        storedRequests.append(request)
        let path = request.url?.path
        let body: String
        let statusCode: Int
        switch (path, request.httpMethod) {
        case ("/api/v1/auth/circlems", "POST"):
            body = #"""
            {
              "accessToken": "service-jwt",
              "expiresAt": "2099-08-09T00:15:00.000Z"
            }
            """#
            statusCode = 200
        case ("/api/v1/me/favorites/108", "GET"):
            body = #"{"eventNumber":108,"revision":2,"favorites":[]}"#
            statusCode = 200
        case ("/api/v1/me/favorites/108", "PUT"):
            body = #"{"eventNumber":108,"revision":3,"favorites":[{"wcID":23000001,"color":2,"notificationsEnabled":true}]}"#
            statusCode = 200
        case ("/api/v1/events/108/updates", "GET"):
            body = #"{"eventNumber":108,"updates":[{"cursor":41,"eventKey":"twitterapi:1:inventory_sold_out","updateKind":"inventory_sold_out","stateKind":"inventory","stateValue":"sold_out","confidence":"high","occurredAt":"2026-08-15T03:00:00Z","sourceRevision":1,"post":{"id":"1","url":"https://x.com/circle/status/1","text":"完売しました","author":{"xUserID":"9","handle":"circle","name":"Circle","profileImageURL":null},"media":[]},"circles":[{"eventNumber":108,"wcID":23000001,"circleID":100,"circleName":"Circle","day":1,"areaName":"西","blockName":"ア","spaceNo":1,"spaceNoSub":0,"location":"1日目 西 ア01a"}]}],"nextCursor":41,"hasMore":false,"serverTime":"2026-08-15T03:00:01Z"}"#
            statusCode = 200
        case ("/api/v1/auth/logout", "POST"):
            body = ""
            statusCode = 204
        default:
            throw CominaviServiceError.invalidResponse
        }
        let response = try XCTUnwrap(
            try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] {
        storedRequests
    }
}
