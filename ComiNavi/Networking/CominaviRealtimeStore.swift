import Foundation

struct SharedPlanExternalCircleState: Equatable, Identifiable, Sendable {
    let kind: String
    let value: String
    let occurredAt: Date
    let sourceName: String
    let sourceHandle: String
    let sourceURL: URL?

    var id: String { "\(kind):\(value):\(occurredAt.timeIntervalSince1970)" }

    var title: String {
        switch (kind, value) {
        case ("inventory", "available"): String(localized: "Available")
        case ("inventory", "low_stock"): String(localized: "Low stock")
        case ("inventory", "sold_out"): String(localized: "Sold out")
        case ("presence", "present"): String(localized: "Circle present")
        case ("presence", "temporarily_away"): String(localized: "Temporarily away")
        case ("presence", "closed"): String(localized: "Circle closed")
        case ("attendance", "absent"): String(localized: "Withdrawn")
        case ("attendance", "attending"): String(localized: "Attending")
        default: String(localized: "External update")
        }
    }
}

struct CominaviRealtimeCacheLoad: Sendable {
    let data: Data
    let requiresRewrite: Bool
}

protocol CominaviRealtimeCachePersisting: Sendable {
    func load(eventNumber: Int) async throws -> Data?
    func loadResult(eventNumber: Int) async throws -> CominaviRealtimeCacheLoad?
    func save(_ data: Data, eventNumber: Int) async throws
}

extension CominaviRealtimeCachePersisting {
    func loadResult(eventNumber: Int) async throws -> CominaviRealtimeCacheLoad? {
        guard let data = try await load(eventNumber: eventNumber) else { return nil }
        return CominaviRealtimeCacheLoad(data: data, requiresRewrite: false)
    }
}

struct FileCominaviRealtimeCacheStore: CominaviRealtimeCachePersisting {
    let directory: URL
    let legacyDirectory: URL?

    init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    func load(eventNumber: Int) async throws -> Data? {
        try await loadResult(eventNumber: eventNumber)?.data
    }

    func loadResult(eventNumber: Int) async throws -> CominaviRealtimeCacheLoad? {
        let url = fileURL(eventNumber: eventNumber)
        let legacyURL = legacyDirectory?.appendingPathComponent(
            "event-\(eventNumber)-heads.json"
        )
        return try await Task.detached(priority: .utility) {
            () throws -> CominaviRealtimeCacheLoad? in
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                return CominaviRealtimeCacheLoad(
                    data: try Data(contentsOf: url),
                    requiresRewrite: false
                )
            }
            guard let legacyURL,
                  fileManager.fileExists(atPath: legacyURL.path)
            else { return nil }

            let data = try Data(contentsOf: legacyURL)
            // The legacy snapshot remains usable even if migration cannot be
            // completed yet (for example, while storage is temporarily full).
            let requiresRewrite: Bool
            do {
                try Self.write(data, to: url, in: directory, fileManager: fileManager)
                requiresRewrite = false
            } catch {
                requiresRewrite = true
            }
            return CominaviRealtimeCacheLoad(
                data: data,
                requiresRewrite: requiresRewrite
            )
        }.value
    }

    func save(_ data: Data, eventNumber: Int) async throws {
        let directory = directory
        let url = fileURL(eventNumber: eventNumber)
        try await Task.detached(priority: .utility) {
            try Self.write(data, to: url, in: directory)
        }.value
    }

    private func fileURL(eventNumber: Int) -> URL {
        directory.appendingPathComponent("event-\(eventNumber)-heads.json")
    }

    private static func write(
        _ data: Data,
        to url: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

actor CominaviRealtimeStore {
    enum RefreshBehavior: Equatable, Sendable {
        case waitForInitialValue
        case staleWhileRevalidate
    }

    private enum RefreshAuthority: Equatable {
        case legacy
        case tagCatalog(String)
    }

    static let shared = CominaviRealtimeStore()

    private struct CacheSnapshot: Codable, Sendable {
        let version: Int
        let eventNumber: Int
        let lastCursor: Int
        let heads: [CominaviRealtimeUpdate]
        let publicationRevision: String?
        let publicationGeneration: Int?
        let publicationCursor: Int?
        let tagOverlay: CominaviCircleTagOverlay?
    }

    /// Waits between attempts at one page after a transient failure. The
    /// page is given up after the last delay; pages already committed stay.
    static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(9)]
    /// Minimum time between disk writes while a catch-up still has pages to
    /// fetch. The last page is always written.
    static let defaultPersistInterval: Duration = .seconds(3)

    /// The state one catch-up builds page by page and commits after each page.
    private struct EventState: Equatable {
        var cursor: Int
        var heads: [Int: [String: CominaviRealtimeUpdate]]
        var publicationRevision: String
        var publicationGeneration: Int
        var publicationCursor: Int
        var tagOverlay: CominaviCircleTagOverlay?
    }

    private let client: any CominaviRealtimeFetching
    private let cacheStore: any CominaviRealtimeCachePersisting
    private let retryDelays: [Duration]
    private let persistInterval: Duration
    private var cacheLoadAttemptedEvents: Set<Int> = []
    private var cacheAvailableEvents: Set<Int> = []
    private var cacheRequiresRewriteEvents: Set<Int> = []
    private var lastRefreshByEvent: [Int: Date] = [:]
    private var lastRefreshAuthorityByEvent: [Int: RefreshAuthority] = [:]
    private var lastCursorByEvent: [Int: Int] = [:]
    private var publicationRevisionByEvent: [Int: String] = [:]
    private var publicationGenerationByEvent: [Int: Int] = [:]
    private var publicationCursorByEvent: [Int: Int] = [:]
    private var headsByEvent: [Int: [Int: [String: CominaviRealtimeUpdate]]] = [:]
    private var tagOverlayByEvent: [Int: CominaviCircleTagOverlay] = [:]
    private var tagsByEvent: [Int: [Int: [CatalogEnrichmentTag]]] = [:]
    private var revalidationTasks: [Int: Task<Void, Never>] = [:]
    private var revalidationAuthorityByEvent: [Int: RefreshAuthority] = [:]

    init(
        client: any CominaviRealtimeFetching = CominaviServiceClient.shared,
        cacheStore: any CominaviRealtimeCachePersisting = FileCominaviRealtimeCacheStore(
            directory: DirectoryManager.shared.environmentApplicationSupportDirectory
                .appendingPathComponent("RealtimeUpdates", isDirectory: true),
            legacyDirectory: DirectoryManager.shared.environmentCachesDirectory
                .appendingPathComponent("RealtimeUpdates", isDirectory: true)
        ),
        retryDelays: [Duration] = CominaviRealtimeStore.defaultRetryDelays,
        persistInterval: Duration = CominaviRealtimeStore.defaultPersistInterval
    ) {
        self.client = client
        self.cacheStore = cacheStore
        self.retryDelays = retryDelays
        self.persistInterval = persistInterval
    }

    func refresh(
        eventNumber: Int,
        expectedTagCatalogPayloadSHA256: String? = nil,
        minimumInterval: TimeInterval = 60,
        behavior: RefreshBehavior = .waitForInitialValue
    ) async throws {
        guard (1...10_000).contains(eventNumber),
              expectedTagCatalogPayloadSHA256.map(Self.isDigest) ?? true
        else {
            throw CominaviServiceError.invalidResponse
        }
        await loadCacheIfNeeded(eventNumber: eventNumber)
        try await clearIncompatibleTagOverlayIfNeeded(
            eventNumber: eventNumber,
            expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
        )
        let authority = Self.refreshAuthority(
            expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
        )
        if let lastRefresh = lastRefreshByEvent[eventNumber],
           lastRefreshAuthorityByEvent[eventNumber] == authority,
           Date().timeIntervalSince(lastRefresh) < minimumInterval
        {
            return
        }
        if let revalidationTask = revalidationTasks[eventNumber] {
            guard revalidationAuthorityByEvent[eventNumber] != authority else { return }
            guard behavior == .waitForInitialValue else { return }
            await revalidationTask.value
            try await refresh(
                eventNumber: eventNumber,
                expectedTagCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256,
                minimumInterval: minimumInterval,
                behavior: behavior
            )
            return
        }
        if cacheAvailableEvents.contains(eventNumber) {
            startRevalidation(
                eventNumber: eventNumber,
                expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
            )
            return
        }
        if behavior == .waitForInitialValue {
            try await revalidate(
                eventNumber: eventNumber,
                expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
            )
        } else {
            startRevalidation(
                eventNumber: eventNumber,
                expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
            )
        }
    }

    func waitForRevalidation(eventNumber: Int) async {
        await revalidationTasks[eventNumber]?.value
    }

    private func startRevalidation(
        eventNumber: Int,
        expectedCatalogPayloadSHA256: String?
    ) {
        revalidationAuthorityByEvent[eventNumber] = Self.refreshAuthority(
            expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256
        )
        revalidationTasks[eventNumber] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.revalidate(
                    eventNumber: eventNumber,
                    expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256
                )
            } catch is CancellationError {
            } catch {
                // Pages committed before the failure stay; the next refresh
                // resumes after the last committed cursor.
                NSLog("Realtime catch-up for C\(eventNumber) stopped: \(error)")
            }
            await self.finishRevalidation(eventNumber: eventNumber)
        }
    }

    private func finishRevalidation(eventNumber: Int) {
        revalidationTasks[eventNumber] = nil
        revalidationAuthorityByEvent[eventNumber] = nil
    }

    private func revalidate(
        eventNumber: Int,
        expectedCatalogPayloadSHA256: String?
    ) async throws {
        // Each page is a consistent prefix of the update log (and a reset page
        // is a whole publication), so the state after any page is safe to
        // publish. Committing per page lets a weak network keep its progress.
        var committed = currentState(eventNumber: eventNumber)
        var candidate = committed
        var requestedTagRevision = Self.requestedTagRevision(
            for: candidate.tagOverlay,
            expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256
        )
        var lastPersist: ContinuousClock.Instant?
        while true {
            let page = try await fetchPageRetryingTransientFailures(
                eventNumber: eventNumber,
                afterCursor: candidate.cursor,
                publicationRevision: candidate.publicationRevision,
                tagRevision: requestedTagRevision
            )
            guard page.updates == page.updates.sorted(by: Self.isUpdateOrdered),
                  Set(page.updates.map(\.eventKey)).count == page.updates.count,
                  Self.isPublicationRevision(page.publicationRevision),
                  page.publicationGeneration >= 0,
                  page.publicationCursor >= 0,
                  (page.publicationRevision
                    == CominaviRealtimeUpdatePage.absentPublicationRevision)
                    == (page.publicationGeneration == 0),
                  page.updates.allSatisfy({ update in
                      update.cursor > 0
                          || (page.resetRequired
                              && page.publicationCursor == 0
                              && update.cursor == 0)
                  }),
                  !page.hasMore || !page.updates.isEmpty
            else {
                throw CominaviServiceError.invalidResponse
            }
            if page.resetRequired {
                guard !page.hasMore,
                      page.publicationRevision != candidate.publicationRevision,
                      page.publicationGeneration > candidate.publicationGeneration,
                      page.updates.allSatisfy({ $0.cursor >= page.publicationCursor })
                else {
                    throw CominaviServiceError.invalidResponse
                }
                candidate.heads = Self.merging(
                    page.updates,
                    into: [:],
                    eventNumber: eventNumber
                )
                candidate.publicationRevision = page.publicationRevision
                candidate.publicationGeneration = page.publicationGeneration
                candidate.publicationCursor = page.publicationCursor
                candidate.cursor = page.updates.last?.cursor ?? page.publicationCursor
            } else {
                guard page.publicationRevision == candidate.publicationRevision,
                      page.publicationGeneration == candidate.publicationGeneration,
                      page.publicationCursor == candidate.publicationCursor,
                      page.updates.allSatisfy({ $0.cursor > candidate.cursor })
                else {
                    throw CominaviServiceError.invalidResponse
                }
                candidate.heads = Self.merging(
                    page.updates,
                    into: candidate.heads,
                    eventNumber: eventNumber
                )
                if let pageCursor = page.updates.last?.cursor {
                    candidate.cursor = pageCursor
                }
            }
            try Self.stageTagOverlay(
                page.tagOverlay,
                status: page.tagOverlayStatus,
                requestedRevision: requestedTagRevision,
                expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256,
                overlay: &candidate.tagOverlay
            )
            requestedTagRevision = Self.requestedTagRevision(
                for: candidate.tagOverlay,
                expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256
            )

            let now = ContinuousClock.now
            let persist = !page.hasMore
                || lastPersist.map { now - $0 >= persistInterval } ?? true
            try await commit(
                candidate,
                over: committed,
                eventNumber: eventNumber,
                persist: persist
            )
            if persist { lastPersist = now }
            committed = candidate
            guard page.hasMore else { break }
        }

        lastRefreshByEvent[eventNumber] = Date()
        lastRefreshAuthorityByEvent[eventNumber] = Self.refreshAuthority(
            expectedCatalogPayloadSHA256: expectedCatalogPayloadSHA256
        )
    }

    private func currentState(eventNumber: Int) -> EventState {
        EventState(
            cursor: lastCursorByEvent[eventNumber] ?? 0,
            heads: headsByEvent[eventNumber] ?? [:],
            publicationRevision: publicationRevisionByEvent[eventNumber]
                ?? CominaviRealtimeUpdatePage.absentPublicationRevision,
            publicationGeneration: publicationGenerationByEvent[eventNumber] ?? 0,
            publicationCursor: publicationCursorByEvent[eventNumber] ?? 0,
            tagOverlay: tagOverlayByEvent[eventNumber]
        )
    }

    /// Publishes one page's state in memory and, when `persist` is set, on
    /// disk. A skipped write marks the cache for rewrite so a later commit (in
    /// this catch-up or the next one) writes it even if nothing new arrives.
    private func commit(
        _ candidate: EventState,
        over committed: EventState,
        eventNumber: Int,
        persist: Bool
    ) async throws {
        guard currentState(eventNumber: eventNumber) == committed else {
            // Another refresh changed this event while the page was in flight.
            throw CominaviServiceError.invalidResponse
        }
        let stateChanged = candidate != committed
        let needsWrite = stateChanged
            || !cacheAvailableEvents.contains(eventNumber)
            || cacheRequiresRewriteEvents.contains(eventNumber)
        if needsWrite {
            if persist {
                let snapshot = Self.cacheSnapshot(
                    eventNumber: eventNumber,
                    lastCursor: candidate.cursor,
                    heads: candidate.heads,
                    publicationRevision: candidate.publicationRevision,
                    publicationGeneration: candidate.publicationGeneration,
                    publicationCursor: candidate.publicationCursor,
                    tagOverlay: candidate.tagOverlay
                )
                try Self.validate(snapshot, eventNumber: eventNumber)
                try await cacheStore.save(
                    JSONEncoder().encode(snapshot),
                    eventNumber: eventNumber
                )
                guard currentState(eventNumber: eventNumber) == committed else {
                    // Another refresh won while this write was in flight. Keep
                    // its in-memory state and have the next commit rewrite disk.
                    cacheRequiresRewriteEvents.insert(eventNumber)
                    throw CominaviServiceError.invalidResponse
                }
                cacheRequiresRewriteEvents.remove(eventNumber)
            } else {
                cacheRequiresRewriteEvents.insert(eventNumber)
            }
        }

        headsByEvent[eventNumber] = candidate.heads
        lastCursorByEvent[eventNumber] = candidate.cursor
        publicationRevisionByEvent[eventNumber] = candidate.publicationRevision
        publicationGenerationByEvent[eventNumber] = candidate.publicationGeneration
        publicationCursorByEvent[eventNumber] = candidate.publicationCursor
        if candidate.tagOverlay != committed.tagOverlay
            || tagsByEvent[eventNumber] == nil
        {
            tagOverlayByEvent[eventNumber] = candidate.tagOverlay
            tagsByEvent[eventNumber] = candidate.tagOverlay.map(Self.tagsByWCID) ?? [:]
        }
        cacheAvailableEvents.insert(eventNumber)
    }

    private func fetchPageRetryingTransientFailures(
        eventNumber: Int,
        afterCursor: Int,
        publicationRevision: String,
        tagRevision: String?
    ) async throws -> CominaviRealtimeUpdatePage {
        var attempt = 0
        while true {
            do {
                return try await client.realtimeUpdates(
                    eventNumber: eventNumber,
                    afterCursor: afterCursor,
                    publicationRevision: publicationRevision,
                    tagRevision: tagRevision
                )
            } catch {
                guard attempt < retryDelays.count,
                      Self.isTransient(error),
                      !Task.isCancelled
                else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Network failures and server overload are worth another attempt.
    /// Invalid responses, authorization failures and client errors are not.
    static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired,
                 .userCancelledAuthentication, .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true
            }
        }
        if case CominaviServiceError.server(_, _, let status) = error {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    private static func requestedTagRevision(
        for overlay: CominaviCircleTagOverlay?,
        expectedCatalogPayloadSHA256: String?
    ) -> String? {
        expectedCatalogPayloadSHA256.map { expectedDigest in
            overlay?.catalogPayloadSHA256 == expectedDigest
                ? overlay?.revision ?? CominaviCircleTagOverlay.absentRevision
                : CominaviCircleTagOverlay.absentRevision
        }
    }

    private func loadCacheIfNeeded(eventNumber: Int) async {
        guard cacheLoadAttemptedEvents.insert(eventNumber).inserted else { return }
        guard let loaded = try? await cacheStore.loadResult(eventNumber: eventNumber),
              let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: loaded.data),
              (try? Self.validate(snapshot, eventNumber: eventNumber)) != nil
        else { return }
        if loaded.requiresRewrite {
            cacheRequiresRewriteEvents.insert(eventNumber)
        }
        if snapshot.version == 3,
           let publicationRevision = snapshot.publicationRevision,
           let publicationGeneration = snapshot.publicationGeneration,
           let publicationCursor = snapshot.publicationCursor
        {
            headsByEvent[eventNumber] = Self.merging(
                snapshot.heads,
                into: [:],
                eventNumber: eventNumber
            )
            lastCursorByEvent[eventNumber] = snapshot.lastCursor
            publicationRevisionByEvent[eventNumber] = publicationRevision
            publicationGenerationByEvent[eventNumber] = publicationGeneration
            publicationCursorByEvent[eventNumber] = publicationCursor
        } else {
            // Version 1/2 caches predate publication replacement semantics. Do
            // not briefly surface their stale circle targets while the v3
            // endpoint is revalidating; restart from the explicit `none` head.
            headsByEvent[eventNumber] = [:]
            lastCursorByEvent[eventNumber] = 0
            publicationRevisionByEvent[eventNumber] =
                CominaviRealtimeUpdatePage.absentPublicationRevision
            publicationGenerationByEvent[eventNumber] = 0
            publicationCursorByEvent[eventNumber] = 0
            cacheRequiresRewriteEvents.insert(eventNumber)
        }
        if let overlay = snapshot.tagOverlay {
            installTagOverlay(overlay, eventNumber: eventNumber)
        }
        cacheAvailableEvents.insert(eventNumber)
    }

    private func clearIncompatibleTagOverlayIfNeeded(
        eventNumber: Int,
        expectedCatalogPayloadSHA256: String?
    ) async throws {
        guard let expectedCatalogPayloadSHA256,
              let overlay = tagOverlayByEvent[eventNumber],
              overlay.catalogPayloadSHA256 != expectedCatalogPayloadSHA256
        else { return }

        tagOverlayByEvent[eventNumber] = nil
        tagsByEvent[eventNumber] = [:]
        lastRefreshByEvent[eventNumber] = nil
        lastRefreshAuthorityByEvent[eventNumber] = nil

        guard cacheAvailableEvents.contains(eventNumber) else { return }
        let snapshot = Self.cacheSnapshot(
            eventNumber: eventNumber,
            lastCursor: lastCursorByEvent[eventNumber] ?? 0,
            heads: headsByEvent[eventNumber] ?? [:],
            publicationRevision: publicationRevisionByEvent[eventNumber]
                ?? CominaviRealtimeUpdatePage.absentPublicationRevision,
            publicationGeneration: publicationGenerationByEvent[eventNumber] ?? 0,
            publicationCursor: publicationCursorByEvent[eventNumber] ?? 0,
            tagOverlay: nil
        )
        try Self.validate(snapshot, eventNumber: eventNumber)
        try await cacheStore.save(
            JSONEncoder().encode(snapshot),
            eventNumber: eventNumber
        )
        cacheRequiresRewriteEvents.remove(eventNumber)
    }

    private static func merging(
        _ updates: [CominaviRealtimeUpdate],
        into existing: [Int: [String: CominaviRealtimeUpdate]],
        eventNumber: Int
    ) -> [Int: [String: CominaviRealtimeUpdate]] {
        var eventHeads = existing
        for update in updates {
            for circle in update.circles where circle.eventNumber == eventNumber {
                var circleHeads = eventHeads[circle.wcID] ?? [:]
                if let current = circleHeads[update.stateKind],
                   !Self.isNewer(update, than: current)
                {
                    continue
                }
                circleHeads[update.stateKind] = update
                eventHeads[circle.wcID] = circleHeads
            }
        }
        return eventHeads
    }

    private static func cacheSnapshot(
        eventNumber: Int,
        lastCursor: Int,
        heads: [Int: [String: CominaviRealtimeUpdate]],
        publicationRevision: String,
        publicationGeneration: Int,
        publicationCursor: Int,
        tagOverlay: CominaviCircleTagOverlay?
    ) -> CacheSnapshot {
        var headsByEventKey: [String: CominaviRealtimeUpdate] = [:]
        for circleHeads in heads.values {
            for update in circleHeads.values {
                headsByEventKey[update.eventKey] = update
            }
        }
        return CacheSnapshot(
            version: 3,
            eventNumber: eventNumber,
            lastCursor: lastCursor,
            heads: headsByEventKey.values.sorted(by: Self.isUpdateOrdered),
            publicationRevision: publicationRevision,
            publicationGeneration: publicationGeneration,
            publicationCursor: publicationCursor,
            tagOverlay: tagOverlay
        )
    }

    private static func validate(_ snapshot: CacheSnapshot, eventNumber: Int) throws {
        let hasValidPublicationAuthority = snapshot.version != 3 || (
            snapshot.publicationRevision.map(Self.isPublicationRevision) == true
                && (snapshot.publicationGeneration ?? -1) >= 0
                && (snapshot.publicationCursor ?? -1) >= 0
                && (snapshot.publicationCursor ?? 0) <= snapshot.lastCursor
                && ((snapshot.publicationRevision
                    == CominaviRealtimeUpdatePage.absentPublicationRevision)
                    == (snapshot.publicationGeneration == 0))
        )
        guard [1, 2, 3].contains(snapshot.version),
              snapshot.eventNumber == eventNumber,
              snapshot.lastCursor >= 0,
              hasValidPublicationAuthority,
              Set(snapshot.heads.map(\.eventKey)).count == snapshot.heads.count,
              snapshot.heads.allSatisfy({ update in
                  (update.cursor > 0
                      || (snapshot.version == 3
                          && snapshot.publicationRevision
                            != CominaviRealtimeUpdatePage.absentPublicationRevision
                          && snapshot.publicationCursor == 0
                          && update.cursor == 0))
                      && update.cursor <= snapshot.lastCursor
                      && !update.eventKey.isEmpty
                      && update.sourceRevision > 0
                      && update.circles.contains {
                          $0.eventNumber == eventNumber && $0.wcID > 0
                      }
              }),
              snapshot.version != 1 || snapshot.tagOverlay == nil,
              snapshot.version == 3 || (
                snapshot.publicationRevision == nil
                    && snapshot.publicationGeneration == nil
                    && snapshot.publicationCursor == nil
              )
        else {
            throw CominaviServiceError.invalidResponse
        }
        try snapshot.tagOverlay?.validate()
    }

    func enrichment(
        eventNumber: Int,
        publicCircleID: Int,
        expectedTagCatalogPayloadSHA256: String? = nil
    ) -> CatalogCircleEnrichment? {
        let heads = headsByEvent[eventNumber]?[publicCircleID].map {
            Array($0.values)
        } ?? []
        let tags = compatibleTags(
            eventNumber: eventNumber,
            publicCircleID: publicCircleID,
            expectedCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
        )
        return Self.enrichment(from: heads, tags: tags)
    }

    func enrichments(
        eventNumber: Int,
        expectedTagCatalogPayloadSHA256: String? = nil
    ) -> [Int: CatalogCircleEnrichment] {
        var circleIDs: Set<Int> = []
        if let realtimeCircleIDs = headsByEvent[eventNumber]?.keys {
            circleIDs.formUnion(realtimeCircleIDs)
        }
        if let expectedTagCatalogPayloadSHA256,
           tagOverlayByEvent[eventNumber]?.catalogPayloadSHA256
            == expectedTagCatalogPayloadSHA256,
           let taggedCircleIDs = tagsByEvent[eventNumber]?.keys
        {
            circleIDs.formUnion(taggedCircleIDs)
        }
        return Dictionary(uniqueKeysWithValues: circleIDs.compactMap { publicCircleID in
            enrichment(
                eventNumber: eventNumber,
                publicCircleID: publicCircleID,
                expectedTagCatalogPayloadSHA256: expectedTagCatalogPayloadSHA256
            )
                .map { (publicCircleID, $0) }
        })
    }

    func tagOverlayRevision(
        eventNumber: Int,
        expectedTagCatalogPayloadSHA256: String
    ) -> String? {
        guard tagOverlayByEvent[eventNumber]?.catalogPayloadSHA256
                == expectedTagCatalogPayloadSHA256
        else { return nil }
        return tagOverlayByEvent[eventNumber]?.revision
    }

    private func compatibleTags(
        eventNumber: Int,
        publicCircleID: Int,
        expectedCatalogPayloadSHA256: String?
    ) -> [CatalogEnrichmentTag] {
        guard let expectedCatalogPayloadSHA256,
              tagOverlayByEvent[eventNumber]?.catalogPayloadSHA256
                == expectedCatalogPayloadSHA256
        else { return [] }
        return tagsByEvent[eventNumber]?[publicCircleID] ?? []
    }

    func sharedPlanExternalStates(
        eventNumber: Int,
        publicCircleID: Int,
        minimumRefreshInterval: TimeInterval = 60
    ) async throws -> [SharedPlanExternalCircleState] {
        try await refresh(
            eventNumber: eventNumber,
            minimumInterval: minimumRefreshInterval
        )
        let supportedKinds = Set(["inventory", "presence", "attendance"])
        return (headsByEvent[eventNumber]?[publicCircleID] ?? [:]).values
            .filter { supportedKinds.contains($0.stateKind) }
            .map { update in
                SharedPlanExternalCircleState(
                    kind: update.stateKind,
                    value: update.stateValue,
                    occurredAt: update.occurredAt,
                    sourceName: update.post.author.name ?? update.post.author.handle,
                    sourceHandle: update.post.author.handle,
                    sourceURL: update.post.url
                )
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.kind < $1.kind
            }
    }

    private static func isNewer(
        _ incoming: CominaviRealtimeUpdate,
        than current: CominaviRealtimeUpdate
    ) -> Bool {
        if incoming.occurredAt != current.occurredAt {
            return incoming.occurredAt > current.occurredAt
        }
        if incoming.sourceRevision != current.sourceRevision {
            return incoming.sourceRevision > current.sourceRevision
        }
        return incoming.eventKey > current.eventKey
    }

    private static func enrichment(
        from updates: [CominaviRealtimeUpdate],
        tags: [CatalogEnrichmentTag] = []
    ) -> CatalogCircleEnrichment? {
        let posts = updates.compactMap(catalogPost).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        let attendance = updates.compactMap(attendanceClaim).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        guard !posts.isEmpty || !attendance.isEmpty || !tags.isEmpty else { return nil }
        return CatalogCircleEnrichment(
            posts: posts,
            attendanceClaims: attendance,
            tags: tags
        )
    }

    private static func stageTagOverlay(
        _ overlay: CominaviCircleTagOverlay?,
        status: CominaviRealtimeUpdatePage.TagOverlayStatus?,
        requestedRevision: String?,
        expectedCatalogPayloadSHA256: String?,
        overlay current: inout CominaviCircleTagOverlay?
    ) throws {
        guard let requestedRevision, let expectedCatalogPayloadSHA256 else {
            guard overlay == nil, status == nil else {
                throw CominaviServiceError.invalidResponse
            }
            return
        }
        guard let status else { throw CominaviServiceError.invalidResponse }

        switch status {
        case .absent, .invalidated:
            guard overlay == nil else { throw CominaviServiceError.invalidResponse }
            current = nil
            return
        case .unavailable:
            guard overlay == nil,
                  current?.catalogPayloadSHA256 == expectedCatalogPayloadSHA256
                    || current == nil
            else { throw CominaviServiceError.invalidResponse }
            return
        case .current:
            break
        }

        guard let overlay else {
            guard requestedRevision != CominaviCircleTagOverlay.absentRevision,
                  current?.revision == requestedRevision,
                  current?.catalogPayloadSHA256 == expectedCatalogPayloadSHA256
            else { throw CominaviServiceError.invalidResponse }
            return
        }
        try overlay.validate()
        guard overlay.catalogPayloadSHA256 == expectedCatalogPayloadSHA256 else {
            throw CominaviServiceError.invalidResponse
        }

        let currentRevision = current?.revision ?? CominaviCircleTagOverlay.absentRevision
        guard currentRevision == requestedRevision else {
            throw CominaviServiceError.invalidResponse
        }
        if overlay.revision == currentRevision {
            guard current == overlay else {
                throw CominaviServiceError.invalidResponse
            }
            return
        }
        current = overlay
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isPublicationRevision(_ value: String) -> Bool {
        value == CominaviRealtimeUpdatePage.absentPublicationRevision || isDigest(value)
    }

    private static func isUpdateOrdered(
        _ lhs: CominaviRealtimeUpdate,
        _ rhs: CominaviRealtimeUpdate
    ) -> Bool {
        lhs.cursor != rhs.cursor ? lhs.cursor < rhs.cursor : lhs.eventKey < rhs.eventKey
    }

    private static func refreshAuthority(
        expectedCatalogPayloadSHA256: String?
    ) -> RefreshAuthority {
        expectedCatalogPayloadSHA256.map(RefreshAuthority.tagCatalog) ?? .legacy
    }

    private func installTagOverlay(
        _ overlay: CominaviCircleTagOverlay,
        eventNumber: Int
    ) {
        tagOverlayByEvent[eventNumber] = overlay
        tagsByEvent[eventNumber] = Self.tagsByWCID(overlay)
    }

    private static func tagsByWCID(
        _ overlay: CominaviCircleTagOverlay
    ) -> [Int: [CatalogEnrichmentTag]] {
        let termsByID = Dictionary(uniqueKeysWithValues: overlay.terms.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: overlay.circles.map { circle in
            let tags = circle.tagIDs.compactMap { tagID in
                termsByID[tagID].map { term in
                    CatalogEnrichmentTag(
                        termID: term.id,
                        canonicalLabel: term.label,
                        kind: term.kind.rawValue,
                        provenance: [],
                        matchedAlias: nil,
                        evidenceLine: nil,
                        mediaPath: nil,
                        score: 1_000
                    )
                }
            }
            return (circle.wcID, tags)
        })
    }

    private static func catalogPost(
        _ update: CominaviRealtimeUpdate
    ) -> CatalogShinagakiPost? {
        guard update.stateKind == "shinagaki" || update.stateKind == "cover" else {
            return nil
        }
        let fallback = URL(
            string: "https://x.com/\(update.post.author.handle)/status/\(update.post.id)"
        )
        guard let postURL = update.post.url ?? fallback else { return nil }
        let media = update.post.media.map { item in
            CatalogShinagakiMedia(
                kind: CatalogShinagakiMedia.Kind(rawValue: item.type) ?? .unknown,
                url: item.url,
                previewURL: item.previewURL
            )
        }
        guard !media.isEmpty else { return nil }
        return CatalogShinagakiPost(
            id: update.post.id,
            postURL: postURL,
            text: update.post.text,
            createdAt: update.occurredAt,
            authorHandle: update.post.author.handle,
            authorName: update.post.author.name,
            authorBio: nil,
            authorProfileImageURL: update.post.author.profileImageURL,
            media: media,
            tags: [],
            postConfidence: update.confidence,
            placementConfidence: .high,
            matchScore: 100,
            matchReasons: ["realtime_wcid"],
            matchingPolicyID: "cominavi-service-realtime-v1",
            postReasons: [update.updateKind]
        )
    }

    private static func attendanceClaim(
        _ update: CominaviRealtimeUpdate
    ) -> CatalogAttendanceClaim? {
        guard update.stateKind == "attendance" else { return nil }
        let status: CatalogAttendanceStatus = switch update.stateValue {
        case "absent": .withdrawn
        case "attending": .attending
        default: .unknown
        }
        guard status != .unknown else { return nil }
        let fallback = URL(
            string: "https://x.com/\(update.post.author.handle)/status/\(update.post.id)"
        )
        guard let postURL = update.post.url ?? fallback else { return nil }
        return CatalogAttendanceClaim(
            id: update.eventKey,
            status: status,
            confidence: update.confidence,
            reasons: [update.updateKind],
            policyID: "cominavi-service-realtime-v1",
            postURL: postURL,
            text: update.post.text,
            createdAt: update.occurredAt,
            authorHandle: update.post.author.handle,
            authorName: update.post.author.name,
            matchingPolicyID: "cominavi-service-realtime-v1",
            matchScore: 100,
            matchReasons: ["realtime_wcid"],
            provenance: [],
            matchedCircleProvenance: []
        )
    }
}

extension CatalogCircleEnrichment {
    func merging(_ other: CatalogCircleEnrichment?) -> CatalogCircleEnrichment {
        guard let other else { return self }
        var postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        other.posts.forEach { postsByID[$0.id] = $0 }
        var attendanceByID = Dictionary(
            uniqueKeysWithValues: attendanceClaims.map { ($0.id, $0) }
        )
        other.attendanceClaims.forEach { attendanceByID[$0.id] = $0 }
        return CatalogCircleEnrichment(
            posts: postsByID.values.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            },
            attendanceClaims: attendanceByID.values.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            },
            tags: tags + other.tags
        )
    }
}
