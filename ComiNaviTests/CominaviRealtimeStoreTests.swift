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

    func testFileCacheMigratesFromPurgeableCacheToApplicationSupport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durableDirectory = root.appendingPathComponent("Application Support")
        let legacyDirectory = root.appendingPathComponent("Caches")
        let payload = Data("last usable realtime snapshot".utf8)
        try await FileCominaviRealtimeCacheStore(directory: legacyDirectory).save(
            payload,
            eventNumber: 108
        )

        let store = FileCominaviRealtimeCacheStore(
            directory: durableDirectory,
            legacyDirectory: legacyDirectory
        )
        let migrated = try await store.load(eventNumber: 108)
        XCTAssertEqual(migrated, payload)

        try FileManager.default.removeItem(at: legacyDirectory)
        let restored = try await store.load(eventNumber: 108)
        XCTAssertEqual(restored, payload)
    }

    func testLegacyFileCacheRemainsUsableWhenMigrationCannotWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDirectory = root.appendingPathComponent("Caches")
        let blockedDirectory = root.appendingPathComponent("Blocked")
        let payload = Data("usable even without migration".utf8)
        try await FileCominaviRealtimeCacheStore(directory: legacyDirectory).save(
            payload,
            eventNumber: 108
        )
        try Data("not a directory".utf8).write(to: blockedDirectory)

        let loadResult = try await FileCominaviRealtimeCacheStore(
            directory: blockedDirectory,
            legacyDirectory: legacyDirectory
        ).loadResult(eventNumber: 108)

        XCTAssertEqual(loadResult?.data, payload)
        XCTAssertEqual(loadResult?.requiresRewrite, true)
    }

    func testKeepsNewestHeadAndConvertsRealtimeArtworkAndAttendance() async throws {
        let client = RealtimeFetchingStub(pages: [
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
                    stateKind: "shinagaki",
                    stateValue: "new",
                    occurredAt: "2026-08-15T03:05:00Z",
                    mediaURL: "https://pbs.twimg.com/media/new.jpg"
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
        let cachedData = await cache.load(eventNumber: 108)
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

    func testUnchangedCachedSnapshotIsNotReencodedOrRewritten() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(updates: [], hasMore: false),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(eventNumber: 108, minimumInterval: 0)
        let initialSaveCount = await cache.saveCount()
        XCTAssertEqual(initialSaveCount, 1, "The first empty snapshot is still durable")
        await cache.resetSaveCount()

        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [], hasMore: false),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        await store.waitForRevalidation(eventNumber: 108)

        let unchangedSaveCount = await cache.saveCount()
        let initialRequestCount = await client.requestCount()
        XCTAssertEqual(unchangedSaveCount, 0)
        XCTAssertEqual(initialRequestCount, 1)

        try await store.refresh(eventNumber: 108, minimumInterval: 60)
        let throttledRequestCount = await client.requestCount()
        XCTAssertEqual(
            throttledRequestCount,
            1,
            "A no-op refresh must still advance the refresh throttle"
        )
    }

    func testChangedCachedSnapshotIsWrittenOnce() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(updates: [], hasMore: false),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(eventNumber: 108, minimumInterval: 0)
        await cache.resetSaveCount()

        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [try update(
                    cursor: 1,
                    stateKind: "presence",
                    stateValue: "open",
                    occurredAt: "2026-08-15T03:00:00Z"
                )],
                hasMore: false
            ),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        await store.waitForRevalidation(eventNumber: 108)

        let changedSaveCount = await cache.saveCount()
        XCTAssertEqual(changedSaveCount, 1)
    }

    func testUnchangedCacheIsRewrittenWhenDurableMigrationIsRequired() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(updates: [], hasMore: false),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(eventNumber: 108, minimumInterval: 0)
        await cache.resetSaveCount()
        await cache.requireRewriteOnNextLoad()

        let store = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(updates: [], hasMore: false),
            ]),
            cacheStore: cache
        )
        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        await store.waitForRevalidation(eventNumber: 108)

        let saveCount = await cache.saveCount()
        XCTAssertEqual(saveCount, 1)
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
        let requestedTagRevision = await liveClient.requestedTagRevision()
        XCTAssertEqual(stale?.posts.map(\.id), ["cached"])
        XCTAssertEqual(requestedCursor, 1)
        XCTAssertNil(requestedTagRevision)

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

    func testBackgroundRefreshDoesNotWaitForNetworkWithoutDiskSnapshot() async throws {
        let client = ControlledRealtimeFetchingStub()
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

        try await store.refresh(
            eventNumber: 108,
            minimumInterval: 0,
            behavior: .staleWhileRevalidate
        )
        await client.waitUntilRequested()
        let whileRevalidating = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertNil(whileRevalidating)

        await client.resolve(CominaviRealtimeUpdatePage(updates: [
            try update(
                cursor: 1,
                stateKind: "shinagaki",
                stateValue: "fresh",
                occurredAt: "2026-08-15T03:05:00Z",
                mediaURL: "https://pbs.twimg.com/media/fresh.jpg"
            ),
        ], hasMore: false))
        await store.waitForRevalidation(eventNumber: 108)

        let fresh = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(fresh?.posts.map(\.id), ["fresh"])
    }

    func testFreshTagOverlayReplacesCachedTagsDuringSameRevalidationFlow() async throws {
        let cachedOverlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )
        let freshOverlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "theme.yuri", label: "百合", kind: .theme),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["theme.yuri"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [],
                    hasMore: false,
                    tagOverlay: cachedOverlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: cachedOverlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let liveClient = ControlledRealtimeFetchingStub()
        let liveStore = CominaviRealtimeStore(client: liveClient, cacheStore: cache)
        try await liveStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: cachedOverlay.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await liveClient.waitUntilRequested()

        let stale = await liveStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: cachedOverlay.catalogPayloadSHA256
        )
        XCTAssertEqual(stale?.tagLabels, ["R-18"])
        let requestedRevision = await liveClient.requestedTagRevision()
        XCTAssertEqual(requestedRevision, cachedOverlay.revision)

        await liveClient.resolve(CominaviRealtimeUpdatePage(
            updates: [],
            hasMore: false,
            tagOverlay: freshOverlay,
            tagOverlayStatus: .current
        ))
        await liveStore.waitForRevalidation(eventNumber: 108)

        let fresh = await liveStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: freshOverlay.catalogPayloadSHA256
        )
        XCTAssertEqual(fresh?.tagLabels, ["百合"])
    }

    func testCachedTagOverlayRemainsAvailableOffline() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "work.arknights",
                    label: "アークナイツ",
                    kind: .work
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["work.arknights"]
                ),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [],
                    hasMore: false,
                    tagOverlay: overlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let offlineClient = RealtimeFetchingStub(pages: [])
        let offlineStore = CominaviRealtimeStore(client: offlineClient, cacheStore: cache)
        try await offlineStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await offlineStore.waitForRevalidation(eventNumber: 108)

        let cached = await offlineStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        XCTAssertEqual(cached?.tagLabels, ["アークナイツ"])
        let requestedRevisions = await offlineClient.requestedTagRevisions()
        XCTAssertEqual(requestedRevisions, [overlay.revision])
    }

    func testUnavailableStatusRetainsCompatibleCachedOverlay() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.bl", label: "BL", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.bl"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [],
                    hasMore: false,
                    tagOverlay: overlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlayStatus: .unavailable
            ),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let cached = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        XCTAssertEqual(cached?.tagLabels, ["BL"])
    }

    func testAbsentStatusClearsCompatibleCachedOverlay() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "theme.yuri", label: "百合", kind: .theme),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["theme.yuri"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: overlay,
                tagOverlayStatus: .current
            ),
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlayStatus: .absent
            ),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let cleared = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        XCTAssertNil(cleared)
        let revision = await store.tagOverlayRevision(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        XCTAssertNil(revision)
    }

    func testCatalogDigestMismatchClearsTagsButPreservesRealtimeHeads() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [try update(
                        cursor: 1,
                        stateKind: "shinagaki",
                        stateValue: "cached",
                        occurredAt: "2026-08-15T03:00:00Z",
                        mediaURL: "https://pbs.twimg.com/media/cached.jpg"
                    )],
                    hasMore: false,
                    tagOverlay: overlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let newCatalogDigest = String(repeating: "b", count: 64)
        let client = ControlledRealtimeFetchingStub()
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: newCatalogDigest,
            minimumInterval: 0
        )
        await client.waitUntilRequested()

        let whileRevalidating = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: newCatalogDigest
        )
        XCTAssertEqual(whileRevalidating?.posts.map(\.id), ["cached"])
        XCTAssertTrue(whileRevalidating?.tags.isEmpty == true)
        let requestedRevision = await client.requestedTagRevision()
        XCTAssertEqual(requestedRevision, CominaviCircleTagOverlay.absentRevision)

        await client.resolve(CominaviRealtimeUpdatePage(
            updates: [],
            hasMore: false,
            tagOverlayStatus: .invalidated
        ))
        await store.waitForRevalidation(eventNumber: 108)

        let final = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: newCatalogDigest
        )
        XCTAssertEqual(final?.posts.map(\.id), ["cached"])
        XCTAssertTrue(final?.tags.isEmpty == true)
    }

    func testNetworkOverlayForDifferentCatalogDigestIsRejected() async throws {
        let wrongOverlay = makeOverlay(
            catalogPayloadSHA256: String(repeating: "b", count: 64),
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let store = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [],
                    hasMore: false,
                    tagOverlay: wrongOverlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )

        do {
            try await store.refresh(
                eventNumber: 108,
                expectedTagCatalogPayloadSHA256: String(repeating: "a", count: 64),
                minimumInterval: 0
            )
            XCTFail("An overlay for another catalog must not become authoritative")
        } catch CominaviServiceError.invalidResponse {}

        let saveCount = await cache.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testLegacyRealtimeModeNeverAppliesCachedBackendOverlay() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "work.arknights", label: "アークナイツ", kind: .work),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["work.arknights"]),
            ]
        )
        let cache = InMemoryRealtimeCacheStore()
        let seedStore = CominaviRealtimeStore(
            client: RealtimeFetchingStub(pages: [
                CominaviRealtimeUpdatePage(
                    updates: [],
                    hasMore: false,
                    tagOverlay: overlay,
                    tagOverlayStatus: .current
                ),
            ]),
            cacheStore: cache
        )
        try await seedStore.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [], hasMore: false),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)
        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        await store.waitForRevalidation(eventNumber: 108)

        let enrichment = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        let requestedRevisions = await client.requestedTagRevisions()
        XCTAssertNil(enrichment)
        XCTAssertEqual(requestedRevisions.count, 1)
        XCTAssertNil(requestedRevisions[0])
    }

    func testFreshLegacyRefreshCannotDelayFirstTagAwareRefresh() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "character.hatsune-miku",
                    label: "初音ミク",
                    kind: .character
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["character.hatsune-miku"]
                ),
            ]
        )
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [], hasMore: false),
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: overlay,
                tagOverlayStatus: .current
            ),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

        try await store.refresh(eventNumber: 108, minimumInterval: 60)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
            minimumInterval: 60
        )
        await store.waitForRevalidation(eventNumber: 108)

        let enrichment = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        let revisions = await client.requestedTagRevisions()
        XCTAssertEqual(enrichment?.tagLabels, ["初音ミク"])
        XCTAssertEqual(revisions.count, 2)
        XCTAssertNil(revisions[0])
        XCTAssertEqual(revisions[1], CominaviCircleTagOverlay.absentRevision)
    }

    func testTagOverlayCreatesTagOnlyCircleAndExplicitEmptyReplacementClearsIt() async throws {
        let firstOverlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "work.blue-archive",
                    label: "ブルーアーカイブ",
                    kind: .work
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["work.blue-archive"]
                ),
            ]
        )
        let emptyOverlay = makeOverlay(terms: [], circles: [])
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: firstOverlay,
                tagOverlayStatus: .current
            ),
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: emptyOverlay,
                tagOverlayStatus: .current
            ),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: firstOverlay.catalogPayloadSHA256,
            minimumInterval: 0
        )

        let tagged = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: firstOverlay.catalogPayloadSHA256
        )
        XCTAssertEqual(tagged?.tagLabels, ["ブルーアーカイブ"])
        XCTAssertTrue(tagged?.posts.isEmpty == true)

        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: firstOverlay.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let cleared = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: firstOverlay.catalogPayloadSHA256
        )
        let requestedRevisions = await client.requestedTagRevisions()
        XCTAssertNil(cleared)
        XCTAssertEqual(requestedRevisions, [
            CominaviCircleTagOverlay.absentRevision,
            firstOverlay.revision,
        ])
        let currentRevision = await store.tagOverlayRevision(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: firstOverlay.catalogPayloadSHA256
        )
        XCTAssertEqual(currentRevision, emptyOverlay.revision)
    }

    func testPaginationAdvancesTagRevisionAndPublishesNoPartialState() async throws {
        let overlay = makeOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "character.hatsune-miku",
                    label: "初音ミク",
                    kind: .character
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["character.hatsune-miku"]
                ),
            ]
        )
        let client = PausedSecondPageRealtimeFetchingStub(
            firstPage: CominaviRealtimeUpdatePage(
                updates: [try update(
                    cursor: 1,
                    stateKind: "attendance",
                    stateValue: "absent",
                    occurredAt: "2026-08-15T03:00:00Z"
                )],
                hasMore: true,
                tagOverlay: overlay,
                tagOverlayStatus: .current
            )
        )
        let cache = InMemoryRealtimeCacheStore()
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)

        let refresh = Task {
            try await store.refresh(
                eventNumber: 108,
                expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256,
                minimumInterval: 0
            )
        }
        await client.waitUntilSecondPageRequested()

        let whileFetching = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        let revisions = await client.requestedTagRevisions()
        let savesBeforeCompletion = await cache.saveCount()
        XCTAssertNil(whileFetching)
        XCTAssertEqual(revisions, [
            CominaviCircleTagOverlay.absentRevision,
            overlay.revision,
        ])
        XCTAssertEqual(savesBeforeCompletion, 0)

        await client.resolveSecondPage(CominaviRealtimeUpdatePage(
            updates: [try update(
                cursor: 2,
                stateKind: "presence",
                stateValue: "closed",
                occurredAt: "2026-08-15T03:05:00Z"
            )],
            hasMore: false,
            tagOverlayStatus: .current
        ))
        try await refresh.value

        let completed = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: overlay.catalogPayloadSHA256
        )
        let savesAfterCompletion = await cache.saveCount()
        XCTAssertEqual(completed?.tagLabels, ["初音ミク"])
        XCTAssertEqual(completed?.withdrawalClaims.count, 1)
        XCTAssertEqual(savesAfterCompletion, 1)
    }

    func testPaginationRejectsHasMoreWithoutCursorProgress() async throws {
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(updates: [], hasMore: true),
        ])
        let cache = InMemoryRealtimeCacheStore()
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)

        do {
            try await store.refresh(eventNumber: 108, minimumInterval: 0)
            XCTFail("A paginated response must advance the cursor")
        } catch CominaviServiceError.invalidResponse {}

        let requestCount = await client.requestCount()
        let saveCount = await cache.saveCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(saveCount, 0)
    }

    func testLegacyVersionOneDiskSnapshotMigratesAndRequestsInitialTagOverlay() async throws {
        let cache = InMemoryRealtimeCacheStore()
        let cachedUpdate = try update(
            cursor: 1,
            stateKind: "shinagaki",
            stateValue: "legacy",
            occurredAt: "2026-08-15T03:00:00Z",
            mediaURL: "https://pbs.twimg.com/media/legacy.jpg"
        )
        let legacy = LegacyRealtimeCacheSnapshot(
            version: 1,
            eventNumber: 108,
            lastCursor: 1,
            heads: [cachedUpdate]
        )
        await cache.save(try JSONEncoder().encode(legacy), eventNumber: 108)
        await cache.resetSaveCount()
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlayStatus: .absent
            ),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)

        let expectedDigest = String(repeating: "a", count: 64)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: expectedDigest,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let restored = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        let cursors = await client.requestedCursors()
        let revisions = await client.requestedTagRevisions()
        let saveCount = await cache.saveCount()
        let cachedData = await cache.load(eventNumber: 108)
        let rewrittenData = try XCTUnwrap(cachedData)
        let rewrittenJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        )
        XCTAssertNil(restored)
        XCTAssertEqual(cursors, [0])
        XCTAssertEqual(revisions, [CominaviCircleTagOverlay.absentRevision])
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(rewrittenJSON["version"] as? Int, 3)
    }

    func testPublicationResetDropsLegacyBlueCivetTargetBeforeRevalidationCompletes() async throws {
        let postID = "2085317159560060995"
        let blueCivetWCID = 23_011_889
        let shiraLandWCID = 23_005_830
        let cache = InMemoryRealtimeCacheStore()
        let stale = try update(
            cursor: 1_925,
            stateKind: "shinagaki",
            stateValue: postID,
            occurredAt: "2026-08-08T19:11:24Z",
            mediaURL: "https://pbs.twimg.com/media/stale.jpg",
            wcID: blueCivetWCID
        )
        await cache.save(
            try JSONEncoder().encode(LegacyRealtimeCacheSnapshot(
                version: 2,
                eventNumber: 108,
                lastCursor: 3_406,
                heads: [stale]
            )),
            eventNumber: 108
        )

        let publicationRevision = String(repeating: "a", count: 64)
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [try update(
                    cursor: 3_407,
                    stateKind: "shinagaki",
                    stateValue: postID,
                    occurredAt: "2026-08-08T19:11:24Z",
                    mediaURL: "https://pbs.twimg.com/media/current.jpg",
                    wcID: shiraLandWCID
                )],
                hasMore: false,
                publicationRevision: publicationRevision,
                publicationGeneration: 1,
                publicationCursor: 3_407,
                resetRequired: true
            ),
        ])
        let store = CominaviRealtimeStore(client: client, cacheStore: cache)

        try await store.refresh(eventNumber: 108, minimumInterval: 0)

        // A pre-v3 disk snapshot is never exposed while its full publication
        // reset is in flight, so the old six-circle seed cannot flash onscreen.
        let whileRevalidating = await store.enrichment(
            eventNumber: 108,
            publicCircleID: blueCivetWCID
        )
        XCTAssertNil(whileRevalidating)

        await store.waitForRevalidation(eventNumber: 108)
        let blueCivet = await store.enrichment(
            eventNumber: 108,
            publicCircleID: blueCivetWCID
        )
        let shiraLand = await store.enrichment(
            eventNumber: 108,
            publicCircleID: shiraLandWCID
        )
        let requestedCursors = await client.requestedCursors()
        let requestedPublicationRevisions = await client.requestedPublicationRevisions()

        XCTAssertNil(blueCivet)
        XCTAssertEqual(shiraLand?.posts.map(\.id), [postID])
        XCTAssertEqual(requestedCursors, [0])
        XCTAssertEqual(
            requestedPublicationRevisions,
            [CominaviRealtimeUpdatePage.absentPublicationRevision]
        )
    }

    func testPublicationResetPersistsBaselineAndResumesAfterPostFenceCursor()
        async throws
    {
        let revision = String(repeating: "b", count: 64)
        let cache = InMemoryRealtimeCacheStore()
        let resetClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [
                    try update(
                        cursor: 10,
                        stateKind: "attendance",
                        stateValue: "absent",
                        occurredAt: "2026-08-08T18:00:00Z"
                    ),
                    try update(
                        cursor: 10,
                        stateKind: "shinagaki",
                        stateValue: "published-baseline",
                        occurredAt: "2026-08-08T19:00:00Z",
                        mediaURL: "https://pbs.twimg.com/media/baseline.jpg"
                    ),
                    try update(
                        cursor: 11,
                        stateKind: "presence",
                        stateValue: "open",
                        occurredAt: "2026-08-08T19:01:00Z"
                    ),
                ],
                hasMore: false,
                publicationRevision: revision,
                publicationGeneration: 1,
                publicationCursor: 10,
                resetRequired: true
            ),
        ])
        let store = CominaviRealtimeStore(client: resetClient, cacheStore: cache)

        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        let baseline = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(baseline?.posts.map(\.id), ["published-baseline"])
        XCTAssertEqual(baseline?.attendanceClaims.map(\.status), [.withdrawn])

        let incrementalClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [try update(
                    cursor: 12,
                    stateKind: "shinagaki",
                    stateValue: "incremental",
                    occurredAt: "2026-08-08T19:05:00Z",
                    mediaURL: "https://pbs.twimg.com/media/incremental.jpg"
                )],
                hasMore: false,
                publicationRevision: revision,
                publicationGeneration: 1,
                publicationCursor: 10,
                resetRequired: false
            ),
        ])
        let nextStore = CominaviRealtimeStore(client: incrementalClient, cacheStore: cache)

        try await nextStore.refresh(eventNumber: 108, minimumInterval: 0)
        await nextStore.waitForRevalidation(eventNumber: 108)

        let current = await nextStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        let requestedCursors = await incrementalClient.requestedCursors()
        let requestedRevisions = await incrementalClient.requestedPublicationRevisions()
        XCTAssertEqual(current?.posts.map(\.id), ["incremental"])
        XCTAssertEqual(current?.attendanceClaims.map(\.status), [.withdrawn])
        XCTAssertEqual(requestedCursors, [11])
        XCTAssertEqual(requestedRevisions, [revision])
    }

    func testFreshAppendLogResetAtCursorZeroPersistsBaselineAndResumesIncrementally()
        async throws
    {
        let revision = String(repeating: "d", count: 64)
        let cache = InMemoryRealtimeCacheStore()
        let resetClient = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [try update(
                    cursor: 0,
                    stateKind: "shinagaki",
                    stateValue: "published-at-fence",
                    occurredAt: "2026-08-08T19:00:00Z",
                    mediaURL: "https://pbs.twimg.com/media/fresh-baseline.jpg"
                )],
                hasMore: false,
                publicationRevision: revision,
                publicationGeneration: 1,
                publicationCursor: 0,
                resetRequired: true
            ),
        ])
        let store = CominaviRealtimeStore(client: resetClient, cacheStore: cache)

        try await store.refresh(eventNumber: 108, minimumInterval: 0)
        let baseline = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(baseline?.posts.map(\.id), ["published-at-fence"])

        let incrementalClient = ControlledRealtimeFetchingStub()
        let nextStore = CominaviRealtimeStore(client: incrementalClient, cacheStore: cache)

        try await nextStore.refresh(eventNumber: 108, minimumInterval: 0)
        await incrementalClient.waitUntilRequested()

        let restoredBaseline = await nextStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        let requestedCursor = await incrementalClient.requestedCursor()
        let requestedRevision = await incrementalClient.requestedPublicationRevision()
        XCTAssertEqual(restoredBaseline?.posts.map(\.id), ["published-at-fence"])
        XCTAssertEqual(requestedCursor, 0)
        XCTAssertEqual(requestedRevision, revision)

        await incrementalClient.resolve(CominaviRealtimeUpdatePage(
            updates: [try update(
                cursor: 1,
                stateKind: "shinagaki",
                stateValue: "incremental",
                occurredAt: "2026-08-08T19:05:00Z",
                mediaURL: "https://pbs.twimg.com/media/fresh-incremental.jpg"
            )],
            hasMore: false,
            publicationRevision: revision,
            publicationGeneration: 1,
            publicationCursor: 0,
            resetRequired: false
        ))
        await nextStore.waitForRevalidation(eventNumber: 108)

        let current = await nextStore.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001
        )
        XCTAssertEqual(current?.posts.map(\.id), ["incremental"])
    }

    func testInvalidOverlayDoesNotReplaceCurrentSnapshot() async throws {
        let valid = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )
        let invalid = CominaviCircleTagOverlay(
            schemaVersion: valid.schemaVersion,
            revision: valid.revision,
            catalogPayloadSHA256: valid.catalogPayloadSHA256,
            taxonomyRevision: valid.taxonomyRevision,
            matchingPolicyRevision: valid.matchingPolicyRevision,
            evaluatedCircleCount: valid.evaluatedCircleCount,
            taggedCircleCount: valid.taggedCircleCount,
            terms: [
                CominaviCircleTagTerm(id: "content.bl", label: "BL", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.bl"]),
            ]
        )
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: valid,
                tagOverlayStatus: .current
            ),
            CominaviRealtimeUpdatePage(
                updates: [],
                hasMore: false,
                tagOverlay: invalid,
                tagOverlayStatus: .current
            ),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: valid.catalogPayloadSHA256,
            minimumInterval: 0
        )

        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: valid.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let enrichment = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: valid.catalogPayloadSHA256
        )
        XCTAssertEqual(enrichment?.tagLabels, ["R-18"])
        let revision = await store.tagOverlayRevision(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: valid.catalogPayloadSHA256
        )
        XCTAssertEqual(revision, valid.revision)
    }

    func testPreviouslyPublishedSemanticRevisionMayBecomeActiveAgain() async throws {
        let first = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )
        let second = makeOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.bl", label: "BL", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.bl"]),
            ]
        )
        let client = RealtimeFetchingStub(pages: [
            CominaviRealtimeUpdatePage(
                updates: [], hasMore: false, tagOverlay: first, tagOverlayStatus: .current
            ),
            CominaviRealtimeUpdatePage(
                updates: [], hasMore: false, tagOverlay: second, tagOverlayStatus: .current
            ),
            CominaviRealtimeUpdatePage(
                updates: [], hasMore: false, tagOverlay: first, tagOverlayStatus: .current
            ),
        ])
        let store = CominaviRealtimeStore(
            client: client,
            cacheStore: InMemoryRealtimeCacheStore()
        )

        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: first.catalogPayloadSHA256,
            minimumInterval: 0
        )
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: first.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)
        try await store.refresh(
            eventNumber: 108,
            expectedTagCatalogPayloadSHA256: first.catalogPayloadSHA256,
            minimumInterval: 0
        )
        await store.waitForRevalidation(eventNumber: 108)

        let enrichment = await store.enrichment(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            expectedTagCatalogPayloadSHA256: first.catalogPayloadSHA256
        )
        let requestedRevisions = await client.requestedTagRevisions()
        XCTAssertEqual(enrichment?.tagLabels, ["R-18"])
        XCTAssertEqual(requestedRevisions, [
            CominaviCircleTagOverlay.absentRevision,
            first.revision,
            second.revision,
        ])
    }

    private func makeOverlay(
        catalogPayloadSHA256: String = String(repeating: "a", count: 64),
        terms: [CominaviCircleTagTerm],
        circles: [CominaviCircleTagAssignment]
    ) -> CominaviCircleTagOverlay {
        let unsigned = CominaviCircleTagOverlay(
            schemaVersion: 1,
            revision: String(repeating: "0", count: 64),
            catalogPayloadSHA256: catalogPayloadSHA256,
            taxonomyRevision: "cominavi-circle-tags-v1",
            matchingPolicyRevision: "precision-v1",
            evaluatedCircleCount: 22_854,
            taggedCircleCount: circles.count,
            terms: terms,
            circles: circles
        )
        return CominaviCircleTagOverlay(
            schemaVersion: unsigned.schemaVersion,
            revision: unsigned.semanticRevision,
            catalogPayloadSHA256: unsigned.catalogPayloadSHA256,
            taxonomyRevision: unsigned.taxonomyRevision,
            matchingPolicyRevision: unsigned.matchingPolicyRevision,
            evaluatedCircleCount: unsigned.evaluatedCircleCount,
            taggedCircleCount: unsigned.taggedCircleCount,
            terms: unsigned.terms,
            circles: unsigned.circles
        )
    }

    private func update(
        cursor: Int,
        stateKind: String,
        stateValue: String,
        occurredAt: String,
        mediaURL: String? = nil,
        wcID: Int = 23_000_001
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
              "eventKey": "twitterapi:\(cursor):\(updateKind):v1:\(stateValue)",
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
                "eventNumber":108,"wcID":\(wcID),"circleID":100,
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
    private var publicationRevisions: [String] = []
    private var tagRevisions: [String?] = []

    init(pages: [CominaviRealtimeUpdatePage]) {
        self.pages = pages
    }

    func realtimeUpdates(
        eventNumber: Int,
        afterCursor: Int,
        publicationRevision: String,
        tagRevision: String?
    ) async throws -> CominaviRealtimeUpdatePage {
        publicationRevisions.append(publicationRevision)
        return try nextPage(
            eventNumber: eventNumber,
            afterCursor: afterCursor,
            tagRevision: tagRevision
        )
    }

    private func nextPage(
        eventNumber: Int,
        afterCursor: Int,
        tagRevision: String?
    ) throws -> CominaviRealtimeUpdatePage {
        XCTAssertEqual(eventNumber, 108)
        cursors.append(afterCursor)
        tagRevisions.append(tagRevision)
        guard !pages.isEmpty else { throw CominaviServiceError.invalidResponse }
        return pages.removeFirst()
    }

    func requestCount() -> Int {
        cursors.count
    }

    func requestedCursors() -> [Int] {
        cursors
    }

    func requestedTagRevisions() -> [String?] {
        tagRevisions
    }

    func requestedPublicationRevisions() -> [String] {
        publicationRevisions
    }
}

private actor ControlledRealtimeFetchingStub: CominaviRealtimeFetching {
    private var cursor: Int?
    private var publicationRevision: String?
    private var tagRevision: String?
    private var responseContinuation:
        CheckedContinuation<CominaviRealtimeUpdatePage, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func realtimeUpdates(
        eventNumber: Int,
        afterCursor: Int,
        publicationRevision: String,
        tagRevision: String?
    ) async throws -> CominaviRealtimeUpdatePage {
        XCTAssertEqual(eventNumber, 108)
        cursor = afterCursor
        self.publicationRevision = publicationRevision
        self.tagRevision = tagRevision
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

    func requestedPublicationRevision() -> String? {
        publicationRevision
    }

    func requestedTagRevision() -> String? {
        tagRevision
    }

    func resolve(_ page: CominaviRealtimeUpdatePage) {
        responseContinuation?.resume(returning: page)
        responseContinuation = nil
    }
}

private actor PausedSecondPageRealtimeFetchingStub: CominaviRealtimeFetching {
    private let firstPage: CominaviRealtimeUpdatePage
    private var requestCount = 0
    private var tagRevisions: [String?] = []
    private var responseContinuation:
        CheckedContinuation<CominaviRealtimeUpdatePage, Never>?
    private var secondPageWaiters: [CheckedContinuation<Void, Never>] = []

    init(firstPage: CominaviRealtimeUpdatePage) {
        self.firstPage = firstPage
    }

    func realtimeUpdates(
        eventNumber: Int,
        afterCursor: Int,
        publicationRevision: String,
        tagRevision: String?
    ) async throws -> CominaviRealtimeUpdatePage {
        XCTAssertEqual(eventNumber, 108)
        requestCount += 1
        tagRevisions.append(tagRevision)
        if requestCount == 1 {
            XCTAssertEqual(afterCursor, 0)
            return firstPage
        }

        XCTAssertEqual(afterCursor, firstPage.updates.last?.cursor ?? -1)
        secondPageWaiters.forEach { $0.resume() }
        secondPageWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilSecondPageRequested() async {
        guard requestCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondPageWaiters.append(continuation)
        }
    }

    func resolveSecondPage(_ page: CominaviRealtimeUpdatePage) {
        responseContinuation?.resume(returning: page)
        responseContinuation = nil
    }

    func requestedTagRevisions() -> [String?] {
        tagRevisions
    }
}

private struct LegacyRealtimeCacheSnapshot: Encodable {
    let version: Int
    let eventNumber: Int
    let lastCursor: Int
    let heads: [CominaviRealtimeUpdate]
}

private actor InMemoryRealtimeCacheStore: CominaviRealtimeCachePersisting {
    private var dataByEvent: [Int: Data] = [:]
    private var saves = 0
    private var rewriteRequired = false

    func load(eventNumber: Int) -> Data? {
        dataByEvent[eventNumber]
    }

    func loadResult(eventNumber: Int) -> CominaviRealtimeCacheLoad? {
        guard let data = dataByEvent[eventNumber] else { return nil }
        return CominaviRealtimeCacheLoad(
            data: data,
            requiresRewrite: rewriteRequired
        )
    }

    func save(_ data: Data, eventNumber: Int) {
        dataByEvent[eventNumber] = data
        saves += 1
        rewriteRequired = false
    }

    func saveCount() -> Int {
        saves
    }

    func resetSaveCount() {
        saves = 0
    }

    func requireRewriteOnNextLoad() {
        rewriteRequired = true
    }
}
