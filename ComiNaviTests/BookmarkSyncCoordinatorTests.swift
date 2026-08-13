import XCTest

@testable import ComiNavi

final class BookmarkSyncCoordinatorTests: XCTestCase {
    func testUntouchedCanonicalFavoritesImportCirclemsColorsOnce() async throws {
        let localStore = InMemoryUserPlanStore()
        let service = IdempotentFavoriteService(initialRevision: 0)
        let circlemsImport = CirclemsFavoriteImportStub(items: [
            CirclemsFavoriteImportItem(
                wcID: 9_902,
                updateID: 9_902,
                circleName: "Imported Circle",
                color: BookmarkColor.green.rawValue,
                memo: "buy new release"
            ),
        ])
        let coordinator = BookmarkSyncCoordinator(
            eventID: 3_248,
            eventNumber: 108,
            catalog: FixtureMapCatalog(),
            localStore: localStore,
            serviceFavoriteSync: service,
            circlemsImport: circlemsImport
        )

        try await coordinator.sync()
        try await coordinator.sync()

        let stored = try await localStore.bookmark(
            eventNumber: 108,
            publicCircleID: 9_902
        )
        let importedPages = await circlemsImport.requestCount()
        let snapshot = await service.currentSnapshot()
        XCTAssertEqual(stored?.color, .green)
        XCTAssertEqual(stored?.memo, "buy new release")
        XCTAssertEqual(stored?.syncState, .synced)
        XCTAssertEqual(snapshot.favorites.map(\.color), [.green])
        XCTAssertEqual(importedPages, 1)
    }

    func testConcurrentRequestsCoalesceIntoOneTrailingReconciliation() async throws {
        let localStore = InMemoryUserPlanStore()
        let serviceSync = BlockingCominaviFavoriteSync()
        let circlemsMirror = RecordingFavoriteRemoteStore()
        let bookmark = fixtureBookmark()
        try await localStore.upsert(bookmark)

        let coordinator = BookmarkSyncCoordinator(
            eventID: 3_248,
            eventNumber: 108,
            catalog: FixtureMapCatalog(),
            localStore: localStore,
            serviceFavoriteSync: serviceSync,
            circlemsMirror: circlemsMirror
        )

        let first = Task { try await coordinator.sync() }
        await serviceSync.waitUntilFirstFetchStarts()
        let trailing = (0..<7).map { _ in
            Task { try await coordinator.sync() }
        }
        await waitUntil {
            await coordinator.syncQueueSnapshot().requested == 8
        }

        await serviceSync.releaseFirstFetch()
        try await first.value
        for task in trailing {
            try await task.value
        }

        let snapshot = await coordinator.syncQueueSnapshot()
        XCTAssertEqual(snapshot.requested, 8)
        XCTAssertEqual(snapshot.completed, 8)
        XCTAssertFalse(snapshot.isRunning)
        let fetchCount = await serviceSync.fetchCount()
        let replacementCount = await serviceSync.replacementCount()
        let servicePublicCircleIDs = await serviceSync.lastPublicCircleIDs()
        let mirrorFetchCount = await circlemsMirror.fetchCount()
        let stored = try await localStore.bookmark(
            eventNumber: 108,
            publicCircleID: bookmark.publicCircleID
        )
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(servicePublicCircleIDs, [bookmark.publicCircleID])
        XCTAssertGreaterThanOrEqual(mirrorFetchCount, 1)
        XCTAssertEqual(stored?.syncState, .synced)
    }

    func testLostResponseReplaysPersistedMutationBeforeRefetchInSameProcess() async throws {
        let store = InMemoryUserPlanStore()
        try await store.upsert(fixtureBookmark())
        let service = IdempotentFavoriteService(failAfterFirstCommit: true)
        let coordinator = makeCoordinator(store: store, service: service)

        do {
            try await coordinator.sync()
            XCTFail("Expected the committed response to be lost")
        } catch is URLError {
            // The exact committed request remains in the durable outbox seam.
        }
        let pending = try await store.pendingCanonicalFavoriteMutation(eventNumber: 108)
        XCTAssertNotNil(pending)
        await service.resetOperationLog()

        try await coordinator.sync()

        let requests = await service.requestedMutations()
        let operations = await service.operationLog()
        let commitCount = await service.commitCount()
        let remainingPending = try await store.pendingCanonicalFavoriteMutation(eventNumber: 108)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(Set(requests.map(\.mutationID)).count, 1)
        XCTAssertEqual(operations.first, "replace")
        XCTAssertNil(remainingPending)
    }

    func testLostResponseRelaunchRetriesSameSQLiteMutationIDAndCreatesOneEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("favorite-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("user-plan.sqlite").path
        let firstStore = try SQLiteUserPlanStore(path: path)
        try await firstStore.upsert(fixtureBookmark())
        let service = IdempotentFavoriteService(failAfterFirstCommit: true)

        do {
            try await makeCoordinator(store: firstStore, service: service).sync()
            XCTFail("Expected the first response to be lost")
        } catch is URLError {
            // Expected.
        }
        let persistedValue = try await firstStore.pendingCanonicalFavoriteMutation(eventNumber: 108)
        let persisted = try XCTUnwrap(persistedValue)
        await service.resetOperationLog()

        let relaunchedStore = try SQLiteUserPlanStore(path: path)
        try await makeCoordinator(store: relaunchedStore, service: service).sync()

        let requests = await service.requestedMutations()
        let operations = await service.operationLog()
        let commitCount = await service.commitCount()
        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(requests.allSatisfy { $0.mutationID == persisted.mutationID })
        XCTAssertEqual(operations.first, "replace")
        let stored = try await relaunchedStore.bookmark(
            eventNumber: 108,
            publicCircleID: fixtureBookmark().publicCircleID
        )
        XCTAssertEqual(stored?.syncState, .synced)
    }

    func testRevisionConflictDurablyRebasesWithNewMutationID() async throws {
        let store = InMemoryUserPlanStore()
        try await store.upsert(fixtureBookmark())
        let service = IdempotentFavoriteService(conflictFirstMutation: true)

        try await makeCoordinator(store: store, service: service).sync()

        let requests = await service.requestedMutations()
        let commitCount = await service.commitCount()
        let remainingPending = try await store.pendingCanonicalFavoriteMutation(eventNumber: 108)
        XCTAssertEqual(requests.map(\.baseRevision), [1, 2])
        XCTAssertEqual(Set(requests.map(\.mutationID)).count, 2)
        XCTAssertEqual(commitCount, 1)
        XCTAssertNil(remainingPending)
    }

    func testCircleMirrorIsAdditiveAndNeverDeletesUnrelatedProviderFavorite() async throws {
        let localStore = InMemoryUserPlanStore()
        try await localStore.upsert(fixtureBookmark())
        let service = IdempotentFavoriteService()
        let unrelated = RemoteFavorite(
            publicCircleID: 123,
            updateID: 123,
            color: .green,
            memo: "provider-owned"
        )
        let mirror = RecordingFavoriteRemoteStore(initial: [unrelated])
        let coordinator = BookmarkSyncCoordinator(
            eventID: 3_248,
            eventNumber: 108,
            catalog: FixtureMapCatalog(),
            localStore: localStore,
            serviceFavoriteSync: service,
            circlemsMirror: mirror
        )

        try await coordinator.sync()

        let remoteIDs = await mirror.publicCircleIDs()
        let deleteCount = await mirror.deleteCount()
        XCTAssertTrue(remoteIDs.contains(unrelated.publicCircleID))
        XCTAssertEqual(deleteCount, 0)
    }

    func testUnknownCircleIsDurablyQuarantinedAndLaterWritesRemainReachable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("favorite-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("user-plan.sqlite").path
        let firstStore = try SQLiteUserPlanStore(path: path)
        let invalid = fixtureBookmark(publicCircleID: 9_902, color: .orange)
        let valid = fixtureBookmark(publicCircleID: 9_903, color: .green)
        try await firstStore.upsert([invalid, valid])
        let service = TerminalRejectingFavoriteService(invalidPublicCircleID: invalid.publicCircleID)

        try await makeCoordinator(store: firstStore, service: service).sync()

        let firstRequests = await service.requestedPublicCircleIDs()
        let firstPending = try await firstStore.pendingCanonicalFavoriteMutation(
            eventNumber: 108
        )
        let invalidStored = try await firstStore.bookmark(
            eventNumber: 108,
            publicCircleID: invalid.publicCircleID
        )
        let validStored = try await firstStore.bookmark(
            eventNumber: 108,
            publicCircleID: valid.publicCircleID
        )
        XCTAssertEqual(firstRequests, [[9_902, 9_903], [9_903]])
        XCTAssertNil(firstPending)
        XCTAssertEqual(invalidStored?.syncState, .quarantined)
        XCTAssertEqual(validStored?.syncState, .synced)

        let relaunchedStore = try SQLiteUserPlanStore(path: path)
        let persistedQuarantines = try await relaunchedStore
            .quarantinedCanonicalFavoriteMutations(eventNumber: 108)
        let quarantine = try XCTUnwrap(persistedQuarantines.first)
        XCTAssertEqual(quarantine.code, "unknown_circle")
        XCTAssertEqual(quarantine.affectedPublicCircleIDs, [invalid.publicCircleID])
        XCTAssertEqual(quarantine.mutation.favorites.map(\.publicCircleID), [9_902, 9_903])

        let later = fixtureBookmark(publicCircleID: 9_904, color: .blue)
        try await relaunchedStore.upsert(later)
        try await makeCoordinator(store: relaunchedStore, service: service).sync()
        let allRequests = await service.requestedPublicCircleIDs()
        let laterStored = try await relaunchedStore.bookmark(
            eventNumber: 108,
            publicCircleID: later.publicCircleID
        )
        XCTAssertEqual(allRequests.last, [9_903, 9_904])
        XCTAssertEqual(laterStored?.syncState, .synced)

        try await relaunchedStore.discardQuarantinedCanonicalFavoriteMutation(
            eventNumber: 108,
            mutationID: quarantine.mutation.mutationID
        )
        let remainingQuarantines = try await relaunchedStore
            .quarantinedCanonicalFavoriteMutations(eventNumber: 108)
        let discardedBookmark = try await relaunchedStore.bookmark(
            eventNumber: 108,
            publicCircleID: invalid.publicCircleID
        )
        XCTAssertTrue(remainingQuarantines.isEmpty)
        XCTAssertNil(discardedBookmark)
    }

    private func makeCoordinator(
        store: any UserPlanStoring,
        service: any CominaviFavoriteSyncing
    ) -> BookmarkSyncCoordinator {
        BookmarkSyncCoordinator(
            eventID: 3_248,
            eventNumber: 108,
            catalog: FixtureMapCatalog(),
            localStore: store,
            serviceFavoriteSync: service
        )
    }

    private func fixtureBookmark(
        publicCircleID: Int = 9_902,
        color: BookmarkColor = .orange
    ) -> MapBookmark {
        MapBookmark(
            eventNumber: 108,
            publicCircleID: publicCircleID,
            catalogCircleID: publicCircleID,
            updateID: publicCircleID,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 99, spaceNumber: 1),
            subspace: 0,
            color: color,
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

private actor TerminalRejectingFavoriteService: CominaviFavoriteSyncing {
    private let invalidPublicCircleID: Int
    private var snapshot = CominaviFavoriteSnapshot(
        eventNumber: 108,
        revision: 1,
        favorites: []
    )
    private var requests: [[Int]] = []

    init(invalidPublicCircleID: Int) {
        self.invalidPublicCircleID = invalidPublicCircleID
    }

    func favoriteSnapshot(eventNumber: Int) async throws -> CominaviFavoriteSnapshot {
        XCTAssertEqual(eventNumber, snapshot.eventNumber)
        return snapshot
    }

    func replaceFavorites(
        eventNumber: Int,
        baseRevision: Int,
        mutationID: UUID,
        favorites: [CominaviFavorite]
    ) async throws -> CominaviFavoriteSnapshot {
        let publicCircleIDs = favorites.map(\.publicCircleID).sorted()
        requests.append(publicCircleIDs)
        if publicCircleIDs.contains(invalidPublicCircleID) {
            throw CominaviServiceError.favoriteMutationRejected(
                code: "unknown_circle",
                message: "One or more favorites are not in the current service catalog.",
                invalidPublicCircleIDs: [invalidPublicCircleID]
            )
        }
        XCTAssertEqual(baseRevision, snapshot.revision)
        snapshot = CominaviFavoriteSnapshot(
            eventNumber: eventNumber,
            revision: snapshot.revision + 1,
            favorites: favorites
        )
        return snapshot
    }

    func requestedPublicCircleIDs() -> [[Int]] { requests }
}

private actor BlockingCominaviFavoriteSync: CominaviFavoriteSyncing {
    private var snapshot = CominaviFavoriteSnapshot(
        eventNumber: 108,
        revision: 1,
        favorites: []
    )
    private var fetches = 0
    private var replacements: [[CominaviFavorite]] = []
    private var firstFetchContinuation: CheckedContinuation<Void, Never>?

    func favoriteSnapshot(eventNumber: Int) async throws -> CominaviFavoriteSnapshot {
        XCTAssertEqual(eventNumber, 108)
        fetches += 1
        if fetches == 1 {
            await withCheckedContinuation { continuation in
                firstFetchContinuation = continuation
            }
        }
        return snapshot
    }

    func replaceFavorites(
        eventNumber: Int,
        baseRevision: Int,
        mutationID: UUID,
        favorites: [CominaviFavorite]
    ) async throws -> CominaviFavoriteSnapshot {
        XCTAssertEqual(eventNumber, 108)
        XCTAssertEqual(baseRevision, snapshot.revision)
        replacements.append(favorites)
        snapshot = CominaviFavoriteSnapshot(
            eventNumber: eventNumber,
            revision: snapshot.revision + 1,
            favorites: favorites
        )
        return snapshot
    }

    func waitUntilFirstFetchStarts() async {
        while fetches == 0 { await Task.yield() }
    }

    func releaseFirstFetch() {
        firstFetchContinuation?.resume()
        firstFetchContinuation = nil
    }

    func fetchCount() -> Int { fetches }
    func replacementCount() -> Int { replacements.count }
    func lastPublicCircleIDs() -> [Int] {
        replacements.last?.map(\.publicCircleID).sorted() ?? []
    }
}

private actor IdempotentFavoriteService: CominaviFavoriteSyncing {
    struct RequestedMutation: Equatable, Sendable {
        let mutationID: UUID
        let baseRevision: Int
        let favorites: [CominaviFavorite]
    }

    private var snapshot: CominaviFavoriteSnapshot
    private var receipts: [UUID: CominaviFavoriteSnapshot] = [:]
    private var requests: [RequestedMutation] = []
    private var operations: [String] = []
    private var commits = 0
    private var shouldLoseFirstResponse: Bool
    private var shouldConflictFirstMutation: Bool

    init(
        initialRevision: Int = 1,
        failAfterFirstCommit: Bool = false,
        conflictFirstMutation: Bool = false
    ) {
        snapshot = CominaviFavoriteSnapshot(
            eventNumber: 108,
            revision: initialRevision,
            favorites: []
        )
        shouldLoseFirstResponse = failAfterFirstCommit
        shouldConflictFirstMutation = conflictFirstMutation
    }

    func favoriteSnapshot(eventNumber: Int) async throws -> CominaviFavoriteSnapshot {
        operations.append("fetch")
        XCTAssertEqual(eventNumber, snapshot.eventNumber)
        return snapshot
    }

    func replaceFavorites(
        eventNumber: Int,
        baseRevision: Int,
        mutationID: UUID,
        favorites: [CominaviFavorite]
    ) async throws -> CominaviFavoriteSnapshot {
        operations.append("replace")
        requests.append(RequestedMutation(
            mutationID: mutationID,
            baseRevision: baseRevision,
            favorites: favorites
        ))
        if let receipt = receipts[mutationID] {
            return receipt
        }
        if shouldConflictFirstMutation {
            shouldConflictFirstMutation = false
            snapshot = CominaviFavoriteSnapshot(
                eventNumber: eventNumber,
                revision: snapshot.revision + 1,
                favorites: []
            )
            throw CominaviServiceError.revisionConflict(
                code: "favorite_revision_conflict",
                message: "Favorite revision changed.",
                currentRevision: snapshot.revision,
                currentPlan: nil
            )
        }
        guard baseRevision == snapshot.revision else {
            throw CominaviServiceError.revisionConflict(
                code: "favorite_revision_conflict",
                message: "Favorite revision changed.",
                currentRevision: snapshot.revision,
                currentPlan: nil
            )
        }
        snapshot = CominaviFavoriteSnapshot(
            eventNumber: eventNumber,
            revision: snapshot.revision + 1,
            favorites: favorites
        )
        receipts[mutationID] = snapshot
        commits += 1
        if shouldLoseFirstResponse {
            shouldLoseFirstResponse = false
            throw URLError(.networkConnectionLost)
        }
        return snapshot
    }

    func requestedMutations() -> [RequestedMutation] { requests }
    func operationLog() -> [String] { operations }
    func commitCount() -> Int { commits }
    func currentSnapshot() -> CominaviFavoriteSnapshot { snapshot }
    func resetOperationLog() { operations = [] }
}

private actor CirclemsFavoriteImportStub: CirclemsFavoriteImportServicing {
    private let items: [CirclemsFavoriteImportItem]
    private var requests = 0

    init(items: [CirclemsFavoriteImportItem]) {
        self.items = items
    }

    func circlemsFavoriteImportPage(
        eventNumber: Int,
        cursor: String?
    ) async throws -> CirclemsFavoriteImportPage {
        XCTAssertEqual(eventNumber, 108)
        XCTAssertNil(cursor)
        requests += 1
        return CirclemsFavoriteImportPage(
            eventNumber: eventNumber,
            items: items,
            nextCursor: nil
        )
    }

    func requestCount() -> Int { requests }
}

private actor RecordingFavoriteRemoteStore: FavoriteRemoteStoring {
    private var stored: [Int: RemoteFavorite] = [:]
    private var fetches = 0
    private var adds = 0
    private var deletes = 0

    init(initial: [RemoteFavorite] = []) {
        stored = Dictionary(uniqueKeysWithValues: initial.map { ($0.publicCircleID, $0) })
    }

    func favorites(eventID: Int) async throws -> [RemoteFavorite] {
        fetches += 1
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
        deletes += 1
        stored[publicCircleID] = nil
    }

    func fetchCount() -> Int { fetches }
    func addCount() -> Int { adds }
    func deleteCount() -> Int { deletes }
    func publicCircleIDs() -> Set<Int> { Set(stored.keys) }
}
