import Foundation

actor CominaviRealtimeStore {
    static let shared = CominaviRealtimeStore()

    private let client: any CominaviRealtimeFetching
    private var cursorByEvent: [Int: Int] = [:]
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
        var cursor = cursorByEvent[eventNumber] ?? 0
        for _ in 0..<100 {
            let page = try await client.realtimeUpdates(
                eventNumber: eventNumber,
                after: cursor,
                limit: 500
            )
            guard page.nextCursor >= cursor else {
                throw CominaviServiceError.invalidResponse
            }
            for update in page.updates {
                for circle in update.circles where circle.eventNumber == eventNumber {
                    var circleHeads = headsByEvent[eventNumber]?[circle.wcID] ?? [:]
                    if let current = circleHeads[update.stateKind],
                       !Self.isNewer(update, than: current)
                    {
                        continue
                    }
                    circleHeads[update.stateKind] = update
                    headsByEvent[eventNumber, default: [:]][circle.wcID] = circleHeads
                }
            }
            cursor = page.nextCursor
            cursorByEvent[eventNumber] = cursor
            if !page.hasMore {
                lastRefreshByEvent[eventNumber] = Date()
                return
            }
            guard !page.updates.isEmpty else {
                throw CominaviServiceError.invalidResponse
            }
        }
        throw CominaviServiceError.invalidResponse
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
