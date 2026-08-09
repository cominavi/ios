import XCTest

@testable import ComiNavi

final class BookmarkSyncCoordinatorTests: XCTestCase {
    func testConcurrentRequestsCoalesceIntoOneTrailingReconciliation() async throws {
        let localStore = InMemoryUserPlanStore()
        let remoteStore = BlockingFavoriteRemoteStore()
        let serviceSync = RecordingCominaviFavoriteSync()
        let bookmark = fixtureBookmark()
        try await localStore.upsert(bookmark)

        let coordinator = BookmarkSyncCoordinator(
            eventID: 3_248,
            eventNumber: 108,
            catalog: FixtureMapCatalog(),
            localStore: localStore,
            remoteStore: remoteStore,
            serviceFavoriteSync: serviceSync
        )

        let first = Task { try await coordinator.sync() }
        await remoteStore.waitUntilFirstFetchStarts()
        let trailing = (0..<7).map { _ in
            Task { try await coordinator.sync() }
        }
        await waitUntil {
            await coordinator.syncQueueSnapshot().requested == 8
        }

        await remoteStore.releaseFirstFetch()
        try await first.value
        for task in trailing {
            try await task.value
        }

        let snapshot = await coordinator.syncQueueSnapshot()
        XCTAssertEqual(snapshot.requested, 8)
        XCTAssertEqual(snapshot.completed, 8)
        XCTAssertFalse(snapshot.isRunning)
        let fetchCount = await remoteStore.fetchCount()
        let addCount = await remoteStore.addCount()
        let stored = try await localStore.bookmark(
            eventNumber: 108,
            publicCircleID: bookmark.publicCircleID
        )
        let serviceSyncCount = await serviceSync.syncCount()
        let servicePublicCircleIDs = await serviceSync.lastPublicCircleIDs()
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(addCount, 1)
        XCTAssertEqual(serviceSyncCount, 2)
        XCTAssertEqual(servicePublicCircleIDs, [bookmark.publicCircleID])
        XCTAssertEqual(stored?.syncState, .synced)
    }

    private func fixtureBookmark() -> MapBookmark {
        MapBookmark(
            eventNumber: 108,
            publicCircleID: 9_902,
            catalogCircleID: 9_902,
            updateID: 9_902,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 99, spaceNumber: 1),
            subspace: 0,
            color: .orange,
            memo: "offline first",
            modifiedAt: Date(),
            syncState: .pendingUpsert
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the sync queue")
    }
}

private actor RecordingCominaviFavoriteSync: CominaviFavoriteSyncing {
    private var calls: [[MapBookmark]] = []

    func synchronizeFavorites(eventNumber: Int, bookmarks: [MapBookmark]) async throws {
        XCTAssertEqual(eventNumber, 108)
        calls.append(bookmarks)
    }

    func syncCount() -> Int {
        calls.count
    }

    func lastPublicCircleIDs() -> [Int] {
        calls.last?.map(\.publicCircleID).sorted() ?? []
    }
}

private actor BlockingFavoriteRemoteStore: FavoriteRemoteStoring {
    private var stored: [Int: RemoteFavorite] = [:]
    private var fetches = 0
    private var adds = 0
    private var firstFetchContinuation: CheckedContinuation<Void, Never>?

    func favorites(eventID: Int) async throws -> [RemoteFavorite] {
        fetches += 1
        if fetches == 1 {
            await withCheckedContinuation { continuation in
                firstFetchContinuation = continuation
            }
        }
        return Array(stored.values)
    }

    func add(_ bookmark: MapBookmark) async throws {
        adds += 1
        stored[bookmark.publicCircleID] = RemoteFavorite(
            publicCircleID: bookmark.publicCircleID,
            updateID: bookmark.updateID ?? bookmark.catalogCircleID,
            color: bookmark.color,
            memo: bookmark.memo
        )
    }

    func update(_ bookmark: MapBookmark) async throws {
        try await add(bookmark)
    }

    func delete(publicCircleID: Int) async throws {
        stored[publicCircleID] = nil
    }

    func waitUntilFirstFetchStarts() async {
        while fetches == 0 {
            await Task.yield()
        }
    }

    func releaseFirstFetch() {
        firstFetchContinuation?.resume()
        firstFetchContinuation = nil
    }

    func fetchCount() -> Int { fetches }
    func addCount() -> Int { adds }
}
