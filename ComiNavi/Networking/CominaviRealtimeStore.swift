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

protocol CominaviRealtimeCachePersisting: Sendable {
    func load(eventNumber: Int) async throws -> Data?
    func save(_ data: Data, eventNumber: Int) async throws
}

struct FileCominaviRealtimeCacheStore: CominaviRealtimeCachePersisting {
    let directory: URL

    func load(eventNumber: Int) async throws -> Data? {
        let url = fileURL(eventNumber: eventNumber)
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }.value
    }

    func save(_ data: Data, eventNumber: Int) async throws {
        let directory = directory
        let url = fileURL(eventNumber: eventNumber)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }.value
    }

    private func fileURL(eventNumber: Int) -> URL {
        directory.appendingPathComponent("event-\(eventNumber)-heads.json")
    }
}

actor CominaviRealtimeStore {
    static let shared = CominaviRealtimeStore()

    private struct CacheSnapshot: Codable, Sendable {
        let version: Int
        let eventNumber: Int
        let lastCursor: Int
        let heads: [CominaviRealtimeUpdate]
    }

    private let client: any CominaviRealtimeFetching
    private let cacheStore: any CominaviRealtimeCachePersisting
    private var cacheLoadAttemptedEvents: Set<Int> = []
    private var cacheAvailableEvents: Set<Int> = []
    private var lastRefreshByEvent: [Int: Date] = [:]
    private var lastCursorByEvent: [Int: Int] = [:]
    private var headsByEvent: [Int: [Int: [String: CominaviRealtimeUpdate]]] = [:]
    private var revalidationTasks: [Int: Task<Void, Never>] = [:]

    init(
        client: any CominaviRealtimeFetching = CominaviServiceClient.shared,
        cacheStore: any CominaviRealtimeCachePersisting = FileCominaviRealtimeCacheStore(
            directory: DirectoryManager.shared.environmentCachesDirectory
                .appendingPathComponent("RealtimeUpdates", isDirectory: true)
        )
    ) {
        self.client = client
        self.cacheStore = cacheStore
    }

    func refresh(eventNumber: Int, minimumInterval: TimeInterval = 60) async throws {
        guard (1...10_000).contains(eventNumber) else {
            throw CominaviServiceError.invalidResponse
        }
        await loadCacheIfNeeded(eventNumber: eventNumber)
        if let lastRefresh = lastRefreshByEvent[eventNumber],
           Date().timeIntervalSince(lastRefresh) < minimumInterval
        {
            return
        }
        guard revalidationTasks[eventNumber] == nil else { return }
        if cacheAvailableEvents.contains(eventNumber) {
            startRevalidation(eventNumber: eventNumber)
            return
        }
        try await revalidate(eventNumber: eventNumber)
    }

    func waitForRevalidation(eventNumber: Int) async {
        await revalidationTasks[eventNumber]?.value
    }

    private func startRevalidation(eventNumber: Int) {
        revalidationTasks[eventNumber] = Task { [weak self] in
            guard let self else { return }
            try? await self.revalidate(eventNumber: eventNumber)
            await self.finishRevalidation(eventNumber: eventNumber)
        }
    }

    private func finishRevalidation(eventNumber: Int) {
        revalidationTasks[eventNumber] = nil
    }

    private func revalidate(eventNumber: Int) async throws {
        var cursor = lastCursorByEvent[eventNumber] ?? 0
        while true {
            let page = try await client.realtimeUpdates(
                eventNumber: eventNumber,
                afterCursor: cursor
            )
            merge(page.updates, eventNumber: eventNumber)
            if let pageCursor = page.updates.last?.cursor {
                cursor = pageCursor
                lastCursorByEvent[eventNumber] = pageCursor
            }
            try await persistCache(eventNumber: eventNumber)
            guard page.hasMore else { break }
        }
        lastRefreshByEvent[eventNumber] = Date()
    }

    private func loadCacheIfNeeded(eventNumber: Int) async {
        guard cacheLoadAttemptedEvents.insert(eventNumber).inserted else { return }
        guard let data = try? await cacheStore.load(eventNumber: eventNumber),
              let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data),
              Self.isValid(snapshot, eventNumber: eventNumber)
        else { return }
        merge(snapshot.heads, eventNumber: eventNumber)
        lastCursorByEvent[eventNumber] = snapshot.lastCursor
        cacheAvailableEvents.insert(eventNumber)
    }

    private func merge(_ updates: [CominaviRealtimeUpdate], eventNumber: Int) {
        var eventHeads = headsByEvent[eventNumber] ?? [:]
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
        headsByEvent[eventNumber] = eventHeads
    }

    private func persistCache(eventNumber: Int) async throws {
        var headsByEventKey: [String: CominaviRealtimeUpdate] = [:]
        for circleHeads in (headsByEvent[eventNumber] ?? [:]).values {
            for update in circleHeads.values {
                headsByEventKey[update.eventKey] = update
            }
        }
        let snapshot = CacheSnapshot(
            version: 1,
            eventNumber: eventNumber,
            lastCursor: lastCursorByEvent[eventNumber] ?? 0,
            heads: headsByEventKey.values.sorted { $0.cursor < $1.cursor }
        )
        try await cacheStore.save(
            JSONEncoder().encode(snapshot),
            eventNumber: eventNumber
        )
        cacheAvailableEvents.insert(eventNumber)
    }

    private static func isValid(_ snapshot: CacheSnapshot, eventNumber: Int) -> Bool {
        snapshot.version == 1
            && snapshot.eventNumber == eventNumber
            && snapshot.lastCursor >= 0
            && Set(snapshot.heads.map(\.eventKey)).count == snapshot.heads.count
            && snapshot.heads.allSatisfy { update in
                update.cursor > 0
                    && update.cursor <= snapshot.lastCursor
                    && !update.eventKey.isEmpty
                    && update.sourceRevision > 0
                    && update.circles.contains {
                        $0.eventNumber == eventNumber && $0.wcID > 0
                    }
            }
    }

    func enrichment(eventNumber: Int, publicCircleID: Int) -> CatalogCircleEnrichment? {
        guard let heads = headsByEvent[eventNumber]?[publicCircleID] else { return nil }
        return Self.enrichment(from: Array(heads.values))
    }

    func enrichments(eventNumber: Int) -> [Int: CatalogCircleEnrichment] {
        (headsByEvent[eventNumber] ?? [:]).compactMapValues { heads in
            Self.enrichment(from: Array(heads.values))
        }
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
        from updates: [CominaviRealtimeUpdate]
    ) -> CatalogCircleEnrichment? {
        let posts = updates.compactMap(catalogPost).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        let attendance = updates.compactMap(attendanceClaim).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        guard !posts.isEmpty || !attendance.isEmpty else { return nil }
        return CatalogCircleEnrichment(posts: posts, attendanceClaims: attendance)
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
            }
        )
    }
}
