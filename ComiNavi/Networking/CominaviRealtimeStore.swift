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

actor CominaviRealtimeStore {
    static let shared = CominaviRealtimeStore()

    private let client: any CominaviRealtimeFetching
    private var lastRefreshByEvent: [Int: Date] = [:]
    private var headsByEvent: [Int: [Int: [String: CominaviRealtimeUpdate]]] = [:]

    init(client: any CominaviRealtimeFetching = CominaviServiceClient.shared) {
        self.client = client
    }

    func refresh(eventNumber: Int, minimumInterval: TimeInterval = 60) async throws {
        if let lastRefresh = lastRefreshByEvent[eventNumber],
           Date().timeIntervalSince(lastRefresh) < minimumInterval
        {
            return
        }
        let updates = try await client.realtimeUpdates(eventNumber: eventNumber)
        var eventHeads: [Int: [String: CominaviRealtimeUpdate]] = [:]
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
        lastRefreshByEvent[eventNumber] = Date()
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
