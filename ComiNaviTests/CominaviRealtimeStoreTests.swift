import XCTest

@testable import ComiNavi

final class CominaviRealtimeStoreTests: XCTestCase {
    func testKeepsNewestHeadAndConvertsRealtimeArtworkAndAttendance() async throws {
        let client = RealtimeFetchingStub(pages: [
            (
                updates: [
                    try update(
                        cursor: 2,
                        stateKind: "shinagaki",
                        stateValue: "new",
                        occurredAt: "2026-08-15T03:05:00Z",
                        mediaURL: "https://pbs.twimg.com/media/new.jpg"
                    ),
                    try update(
                        cursor: 1,
                        stateKind: "shinagaki",
                        stateValue: "old",
                        occurredAt: "2026-08-15T03:00:00Z",
                        mediaURL: "https://pbs.twimg.com/media/old.jpg"
                    ),
                    try update(
                        cursor: 3,
                        stateKind: "attendance",
                        stateValue: "absent",
                        occurredAt: "2026-08-15T03:06:00Z"
                    ),
                ],
                nextCursor: 3,
                hasMore: false
            ),
        ])
        let store = CominaviRealtimeStore(client: client)

        try await store.refresh(eventNumber: 108, minimumInterval: 60)
        try await store.refresh(eventNumber: 108, minimumInterval: 60)

        let current = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        let enrichment = try XCTUnwrap(current)
        let requestCount = await client.requestCount()
        XCTAssertEqual(enrichment.posts.map(\.id), ["new"])
        XCTAssertEqual(enrichment.attendanceClaims.map(\.status), [.withdrawn])
        XCTAssertEqual(requestCount, 1)
    }

    private func update(
        cursor: Int,
        stateKind: String,
        stateValue: String,
        occurredAt: String,
        mediaURL: String? = nil
    ) throws -> CominaviRealtimeUpdate {
        let media: String
        if let mediaURL {
            media = """
            [{"key":"media-\(cursor)","type":"photo","role":"\(stateKind)","url":"\(mediaURL)","previewURL":null}]
            """
        } else {
            media = "[]"
        }
        let updateKind = switch (stateKind, stateValue) {
        case ("attendance", "absent"): "attendance_absent"
        case ("shinagaki", _): "shinagaki_published"
        default: "realtime_update"
        }
        let data = Data(
            """
            {
              "cursor": \(cursor),
              "eventKey": "twitterapi:\(cursor):\(updateKind):v1:test",
              "updateKind": "\(updateKind)",
              "stateKind": "\(stateKind)",
              "stateValue": "\(stateValue)",
              "confidence": "high",
              "occurredAt": "\(occurredAt)",
              "sourceRevision": 1,
              "post": {
                "id": "\(stateValue)",
                "url": "https://x.com/circle/status/\(cursor)",
                "text": "update \(stateValue)",
                "author": {"xUserID":"9","handle":"circle","name":"Circle","profileImageURL":null},
                "media": \(media)
              },
              "circles": [{
                "eventNumber":108,"wcID":23000001,"circleID":100,
                "circleName":"Circle","day":1,"areaName":"西","blockName":"ア",
                "spaceNo":1,"spaceNoSub":0,"location":"1日目 西 ア01a"
              }]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CominaviRealtimeUpdate.self, from: data)
    }
}

private actor RealtimeFetchingStub: CominaviRealtimeFetching {
    typealias Page = (
        updates: [CominaviRealtimeUpdate],
        nextCursor: Int,
        hasMore: Bool
    )

    private var pages: [Page]
    private var requests = 0

    init(pages: [Page]) {
        self.pages = pages
    }

    func realtimeUpdates(
        eventNumber: Int,
        after cursor: Int,
        limit: Int
    ) async throws -> Page {
        XCTAssertEqual(eventNumber, 108)
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(limit, 500)
        requests += 1
        guard !pages.isEmpty else { throw CominaviServiceError.invalidResponse }
        return pages.removeFirst()
    }

    func requestCount() -> Int {
        requests
    }
}
