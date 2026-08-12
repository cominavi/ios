import XCTest

@testable import ComiNavi

final class CominaviRealtimeStoreTests: XCTestCase {
    func testFileCachePersistsBytesAcrossStoreInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("persisted realtime heads".utf8)

        try await FileCominaviRealtimeCacheStore(directory: directory).save(
            payload,
            eventNumber: 108
        )
        let restored = try await FileCominaviRealtimeCacheStore(
            directory: directory
        ).load(eventNumber: 108)

        XCTAssertEqual(restored, payload)
    }

    func testKeepsNewestHeadAndConvertsRealtimeArtworkAndAttendance() async throws {
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [
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
            ], hasMore: false),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

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

    func testSharedPlanExternalStatesRemainSourceAttributedAndSeparate() async throws {
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [
                try update(
                    cursor: 1,
                    stateKind: "inventory",
                    stateValue: "sold_out",
                    occurredAt: "2026-08-15T03:00:00Z"
                ),
                try update(
                    cursor: 2,
                    stateKind: "presence",
                    stateValue: "temporarily_away",
                    occurredAt: "2026-08-15T03:05:00Z"
                ),
            ], hasMore: false),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

        let states = try await store.sharedPlanExternalStates(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            minimumRefreshInterval: 60
        )

        XCTAssertEqual(states.map(\.kind), ["presence", "inventory"])
        XCTAssertEqual(states.map(\.value), ["temporarily_away", "sold_out"])
        XCTAssertEqual(states.map(\.sourceHandle), ["circle", "circle"])
        XCTAssertEqual(states.compactMap(\.sourceURL).count, 2)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testPagesFromZeroPersistsHeadsAndResumesAfterLastCursor() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let firstClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [
                try update(
                    cursor: 1,
                    stateKind: "shinagaki",
                    stateValue: "old",
                    occurredAt: "2026-08-15T03:00:00Z",
                    mediaURL: "https://pbs.twimg.com/media/old.jpg"
                ),
                try update(
                    cursor: 2,
                    stateKind: "attendance",
                    stateValue: "absent",
                    occurredAt: "2026-08-15T03:01:00Z"
                ),
            ], hasMore: true),
            CominaviRealtimeUpdatePage(updates: [
                try update(
                    cursor: 3,
                    stateKind: "shinagaki",
                    stateValue: "current",
                    occurredAt: "2026-08-15T03:02:00Z",
                    mediaURL: "https://pbs.twimg.com/media/current.jpg"
                ),
            ], hasMore: false),
        ])
        let firstStore = CominaviRealtimeStore(
            client: firstClient,
            cacheStore: cache
        )

        try await firstStore.refresh(eventNumber: 108, minimumInterval: 0)

        let initialCursors = await firstClient.requestedCursors()
        let cachedData = try await cache.load(eventNumber: 108)
        XCTAssertEqual(initialCursors, [0, 2])
        XCTAssertNotNil(cachedData)

        let nextClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [
                try update(
                    cursor: 4,
                    stateKind: "presence",
                    stateValue: "closed",
                    occurredAt: "2026-08-15T03:03:00Z"
                ),
            ], hasMore: false),
        ])
        let nextStore = CominaviRealtimeStore(client: nextClient, cacheStore: cache)

        try await nextStore.refresh(eventNumber: 108, minimumInterval: 0)
        await nextStore.waitForRevalidation(eventNumber: 108)

        let resumedCursors = await nextClient.requestedCursors()
        let current = await nextStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(resumedCursors, [3])
        XCTAssertEqual(current?.posts.map(\.id), ["current"])
        XCTAssertEqual(current?.attendanceClaims.map(\.status), [.withdrawn])
    }

    func testDiskSnapshotIsReturnedWhileNetworkRevalidates() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let seedClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [
                try update(
                    cursor: 1,
                    stateKind: "shinagaki",
                    stateValue: "cached",
                    occurredAt: "2026-08-15T03:00:00Z",
                    mediaURL: "https://pbs.twimg.com/media/cached.jpg"
                ),
            ], hasMore: false),
        ])
        let seedStore = CominaviRealtimeStore(client: seedClient, cacheStore: cache)
        try await seedStore.refresh(eventNumber: 108, minimumInterval: 0)

        let liveClient = ControlledRealtimeFetchingStub()
        let liveStore = CominaviRealtimeStore(client: liveClient, cacheStore: cache)

        try await liveStore.refresh(eventNumber: 108, minimumInterval: 0)
        await liveClient.waitUntilRequested()
        let stale = await liveStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )

        let requestedCursor = await liveClient.requestedCursor()
        XCTAssertEqual(stale?.posts.map(\.id), ["cached"])
        XCTAssertEqual(requestedCursor, 1)

        await liveClient.resolve(CominaviRealtimeUpdatePage(updates: [
            try update(
                cursor: 2,
                stateKind: "shinagaki",
                stateValue: "fresh",
                occurredAt: "2026-08-15T03:05:00Z",
                mediaURL: "https://pbs.twimg.com/media/fresh.jpg"
            ),
        ], hasMore: false))
        await liveStore.waitForRevalidation(eventNumber: 108)

        let fresh = await liveStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(fresh?.posts.map(\.id), ["fresh"])
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
    private var pages: [CominaviRealtimeUpdatePage]
    private var cursors: [Int] = []

    init(pages: [CominaviRealtimeUpdatePage]) {
        self.pages = pages
    }

    func realtimeUpdates(
        eventNumber: Int,
        afterCursor: Int
    ) async throws -> CominaviRealtimeUpdatePage {
        XCTAssertEqual(eventNumber, 108)
        cursors.append(afterCursor)
        guard !pages.isEmpty else { throw CominaviServiceError.invalidResponse }
        return pages.removeFirst()
    }

    func requestCount() -> Int {
        cursors.count
    }

    func requestedCursors() -> [Int] {
        cursors
    }
}

private actor ControlledRealtimeFetchingStub: CominaviRealtimeFetching {
    private var cursor: Int?
    private var responseContinuation:
        CheckedContinuation<CominaviRealtimeUpdatePage, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func realtimeUpdates(
        eventNumber: Int,
        afterCursor: Int
    ) async throws -> CominaviRealtimeUpdatePage {
        XCTAssertEqual(eventNumber, 108)
        cursor = afterCursor
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard cursor == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestedCursor() -> Int? {
        cursor
    }

    func resolve(_ page: CominaviRealtimeUpdatePage) {
        responseContinuation?.resume(returning: page)
        responseContinuation = nil
    }
}

private actor InMemoryRealtimeCacheStore: CominaviRealtimeCachePersisting {
    private var dataByEvent: [Int: Data] = [:]

    func load(eventNumber: Int) -> Data? {
        dataByEvent[eventNumber]
    }

    func save(_ data: Data, eventNumber: Int) {
        dataByEvent[eventNumber] = data
    }
}
