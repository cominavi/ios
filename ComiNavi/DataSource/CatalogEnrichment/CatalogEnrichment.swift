import Foundation

struct CatalogEnrichmentConfiguration: Equatable, Sendable {
    let resourceURL: URL
    let isRequired: Bool
}

enum CatalogConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
    case unmatched

    var title: LocalizedStringResource {
        switch self {
        case .high: "High confidence"
        case .medium: "Possible match"
        case .low: "Low confidence"
        case .unmatched: "Unmatched"
        }
    }

    fileprivate var rank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        case .unmatched: 0
        }
    }
}

struct CatalogShinagakiMedia: Hashable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
        case animatedGIF = "animated_gif"
        case unknown
    }

    let kind: Kind
    let url: URL
    let previewURL: URL?

    var displayURL: URL {
        previewURL ?? url
    }
}

struct CatalogTagProvenance: Hashable, Sendable {
    let sourceID: String?
    let recordID: String?
    let url: String?
}

struct CatalogEnrichmentTag: Identifiable, Hashable, Sendable {
    let termID: String?
    let canonicalLabel: String
    let kind: String?
    let provenance: [CatalogTagProvenance]
    let matchedAlias: String?
    let evidenceLine: String?
    let mediaPath: String?
    let score: Int

    var id: String {
        termID ?? "label:\(canonicalLabel.catalogTagKey)"
    }
}

struct CatalogShinagakiPost: Identifiable, Hashable, Sendable {
    let id: String
    let postURL: URL
    let text: String
    let createdAt: Date?
    let authorHandle: String
    let authorName: String?
    let authorBio: String?
    let authorProfileImageURL: URL?
    let media: [CatalogShinagakiMedia]
    let tags: [CatalogEnrichmentTag]
    let postConfidence: CatalogConfidence
    let placementConfidence: CatalogConfidence
    let matchScore: Int
    let matchReasons: [String]

    var authorProfileURL: URL? {
        URL(string: "https://x.com/\(authorHandle)")
    }

    var isHighConfidence: Bool {
        postConfidence == .high && placementConfidence == .high
    }
}

struct CatalogCircleEnrichment: Equatable, Sendable {
    let posts: [CatalogShinagakiPost]
    let tags: [CatalogEnrichmentTag]

    init(posts: [CatalogShinagakiPost]) {
        self.posts = posts
        tags = Self.mergedTags(posts.flatMap(\.tags))
    }

    var tagLabels: [String] {
        tags.map(\.canonicalLabel)
    }

    var primaryPost: CatalogShinagakiPost? {
        posts.first
    }

    var latestPostDate: Date? {
        posts.compactMap(\.createdAt).max()
    }

    var hasHighConfidencePost: Bool {
        posts.contains(where: \.isHighConfidence)
    }

    var searchableText: String {
        let postText = posts.flatMap { post in
            [
                post.authorHandle,
                post.authorName,
                post.authorBio,
                post.text,
            ]
            .compactMap { $0 }
        }
        let tagText = tags.flatMap { tag in
            [
                tag.canonicalLabel,
                tag.matchedAlias,
                tag.evidenceLine,
            ]
            .compactMap { $0 }
        }
        return (postText + tagText).joined(separator: "\n")
    }

    private static func mergedTags(
        _ tags: [CatalogEnrichmentTag]
    ) -> [CatalogEnrichmentTag] {
        struct Cluster {
            var members: [CatalogEnrichmentTag]
            var termIDs: Set<String>
            var labels: Set<String>

            init(_ tag: CatalogEnrichmentTag) {
                members = [tag]
                termIDs = tag.termID.map { [$0.catalogTagKey] } ?? []
                labels = [tag.canonicalLabel.catalogTagKey]
            }

            mutating func merge(_ other: Cluster) {
                members.append(contentsOf: other.members)
                termIDs.formUnion(other.termIDs)
                labels.formUnion(other.labels)
            }
        }

        var clusters: [Cluster] = []
        for tag in tags {
            let candidate = Cluster(tag)
            let matchingIndices = clusters.indices.filter { index in
                !clusters[index].termIDs.isDisjoint(with: candidate.termIDs)
                    || !clusters[index].labels.isDisjoint(with: candidate.labels)
            }

            var merged = candidate
            for index in matchingIndices.reversed() {
                merged.merge(clusters.remove(at: index))
            }
            clusters.append(merged)
        }

        return clusters.compactMap { cluster in
            cluster.members.sorted(by: isPreferredTag).first
        }
        .sorted(by: isTagOrderedBefore)
    }

    private static func isPreferredTag(
        _ lhs: CatalogEnrichmentTag,
        _ rhs: CatalogEnrichmentTag
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if (lhs.termID != nil) != (rhs.termID != nil) {
            return lhs.termID != nil
        }
        return isTagOrderedBefore(lhs, rhs)
    }

    private static func isTagOrderedBefore(
        _ lhs: CatalogEnrichmentTag,
        _ rhs: CatalogEnrichmentTag
    ) -> Bool {
        let lhsLabel = lhs.canonicalLabel.catalogTagKey
        let rhsLabel = rhs.canonicalLabel.catalogTagKey
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }

        let lhsTermID = lhs.termID?.catalogTagKey ?? ""
        let rhsTermID = rhs.termID?.catalogTagKey ?? ""
        if lhsTermID != rhsTermID { return lhsTermID < rhsTermID }

        let lhsKind = lhs.kind?.catalogTagKey ?? ""
        let rhsKind = rhs.kind?.catalogTagKey ?? ""
        if lhsKind != rhsKind { return lhsKind < rhsKind }

        let lhsAlias = lhs.matchedAlias?.catalogTagKey ?? ""
        let rhsAlias = rhs.matchedAlias?.catalogTagKey ?? ""
        if lhsAlias != rhsAlias { return lhsAlias < rhsAlias }

        let lhsEvidence = lhs.evidenceLine?.catalogTagKey ?? ""
        let rhsEvidence = rhs.evidenceLine?.catalogTagKey ?? ""
        if lhsEvidence != rhsEvidence { return lhsEvidence < rhsEvidence }

        let lhsMediaPath = lhs.mediaPath?.catalogTagKey ?? ""
        let rhsMediaPath = rhs.mediaPath?.catalogTagKey ?? ""
        if lhsMediaPath != rhsMediaPath { return lhsMediaPath < rhsMediaPath }

        let lhsProvenance = provenanceKey(lhs.provenance)
        let rhsProvenance = provenanceKey(rhs.provenance)
        return lhsProvenance < rhsProvenance
    }

    private static func provenanceKey(
        _ provenance: [CatalogTagProvenance]
    ) -> String {
        provenance.map {
            [
                $0.sourceID?.catalogTagKey ?? "",
                $0.recordID?.catalogTagKey ?? "",
                $0.url?.catalogTagKey ?? "",
            ]
            .joined(separator: "\u{1f}")
        }
        .sorted()
        .joined(separator: "\u{1e}")
    }
}

struct CatalogCircleDetails {
    let extensionRecord: CirclemsDataSchema.ComiketCircleExtend?
    let enrichment: CatalogCircleEnrichment?
}

struct CatalogEnrichmentIndex: Sendable {
    private let postsByPublicCircleID: [Int: [CatalogShinagakiPost]]
    private let postsBySeedCircleID: [Int: [CatalogShinagakiPost]]

    let selectedPostCount: Int
    let mappedPostCount: Int
    let mappedPublicCircleCount: Int

    init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sourcePosts = try decoder.decode([CollectorPost].self, from: data)

        var postsByPublicCircleID: [Int: [CatalogShinagakiPost]] = [:]
        var postsBySeedCircleID: [Int: [CatalogShinagakiPost]] = [:]
        var mappedPosts: Set<String> = []

        for sourcePost in sourcePosts {
            guard let bestScore = sourcePost.matchedCircles.map(\.score).max() else {
                continue
            }

            let strongestMatches = sourcePost.matchedCircles.filter { $0.score == bestScore }
            guard !strongestMatches.isEmpty else { continue }
            mappedPosts.insert(sourcePost.tweetId)

            for match in strongestMatches {
                guard let post = sourcePost.catalogPost(match: match) else { continue }
                if let publicCircleID = match.wcId {
                    postsByPublicCircleID[publicCircleID, default: []].append(post)
                }
                postsBySeedCircleID[match.circleId, default: []].append(post)
            }
        }

        self.postsByPublicCircleID = postsByPublicCircleID.mapValues(Self.sortedAndUniqued)
        self.postsBySeedCircleID = postsBySeedCircleID.mapValues(Self.sortedAndUniqued)
        selectedPostCount = sourcePosts.count
        mappedPostCount = mappedPosts.count
        mappedPublicCircleCount = postsByPublicCircleID.count
    }

    func enrichment(
        circleID: Int,
        publicCircleID: Int?
    ) -> CatalogCircleEnrichment? {
        let posts = if let publicCircleID {
            postsByPublicCircleID[publicCircleID] ?? []
        } else {
            postsBySeedCircleID[circleID] ?? []
        }
        let uniquePosts = Self.sortedAndUniqued(posts)
        return uniquePosts.isEmpty ? nil : CatalogCircleEnrichment(posts: uniquePosts)
    }

    func enrichments(
        publicCircleIDsByCircleID: [Int: Int]
    ) -> [Int: CatalogCircleEnrichment] {
        let circleIDs = Set(publicCircleIDsByCircleID.keys)
            .union(postsBySeedCircleID.keys)

        return Dictionary(
            uniqueKeysWithValues: circleIDs.compactMap { circleID in
                enrichment(
                    circleID: circleID,
                    publicCircleID: publicCircleIDsByCircleID[circleID]
                )
                .map { (circleID, $0) }
            }
        )
    }

    private static func sortedAndUniqued(
        _ posts: [CatalogShinagakiPost]
    ) -> [CatalogShinagakiPost] {
        var postsByID: [String: CatalogShinagakiPost] = [:]
        for post in posts {
            if let current = postsByID[post.id] {
                postsByID[post.id] = isPreferred(post, over: current) ? post : current
            } else {
                postsByID[post.id] = post
            }
        }
        return postsByID.values.sorted(by: isPreferred)
    }

    private static func isPreferred(
        _ lhs: CatalogShinagakiPost,
        over rhs: CatalogShinagakiPost
    ) -> Bool {
        if lhs.postConfidence.rank != rhs.postConfidence.rank {
            return lhs.postConfidence.rank > rhs.postConfidence.rank
        }
        if lhs.placementConfidence.rank != rhs.placementConfidence.rank {
            return lhs.placementConfidence.rank > rhs.placementConfidence.rank
        }
        if lhs.matchScore != rhs.matchScore {
            return lhs.matchScore > rhs.matchScore
        }
        return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
}

actor CatalogEnrichmentStore {
    private let resourceURL: URL
    private var loadedIndex: CatalogEnrichmentIndex?

    init(resourceURL: URL) {
        self.resourceURL = resourceURL
    }

    func prepare() throws {
        _ = try index()
    }

    func details(
        circleID: Int,
        publicCircleID: Int?
    ) throws -> CatalogCircleEnrichment? {
        try index().enrichment(
            circleID: circleID,
            publicCircleID: publicCircleID
        )
    }

    func all(
        publicCircleIDsByCircleID: [Int: Int]
    ) throws -> [Int: CatalogCircleEnrichment] {
        try index().enrichments(
            publicCircleIDsByCircleID: publicCircleIDsByCircleID
        )
    }

    func statistics() throws -> (
        selectedPosts: Int,
        mappedPosts: Int,
        mappedCircles: Int
    ) {
        let index = try index()
        return (
            index.selectedPostCount,
            index.mappedPostCount,
            index.mappedPublicCircleCount
        )
    }

    private func index() throws -> CatalogEnrichmentIndex {
        if let loadedIndex {
            return loadedIndex
        }
        let data = try Data(contentsOf: resourceURL, options: .mappedIfSafe)
        let index = try CatalogEnrichmentIndex(data: data)
        loadedIndex = index
        return index
    }
}

private struct CollectorPost: Decodable {
    let tweetId: String
    let tweetUrl: String?
    let text: String
    let createdAt: String?
    let authorHandle: String
    let authorName: String?
    let author: CollectorAuthor?
    let media: [CollectorMedia]
    let postConfidence: CatalogConfidence
    let placementConfidence: CatalogConfidence
    let matchedCircles: [CollectorCircleMatch]
    let enrichment: CollectorPostEnrichment?

    func catalogPost(
        match: CollectorCircleMatch
    ) -> CatalogShinagakiPost? {
        let fallbackURL = "https://x.com/\(authorHandle)/status/\(tweetId)"
        guard let postURL = Self.secureURL(tweetUrl ?? fallbackURL) else {
            return nil
        }

        return CatalogShinagakiPost(
            id: tweetId,
            postURL: postURL,
            text: text,
            createdAt: Self.date(from: createdAt),
            authorHandle: authorHandle,
            authorName: authorName ?? author?.name,
            authorBio: Self.nonBlank(author?.description),
            authorProfileImageURL: Self.secureURL(author?.profilePicture),
            media: media.compactMap(\.catalogMedia),
            tags: enrichment?.tags.compactMap(\.catalogTag) ?? [],
            postConfidence: postConfidence,
            placementConfidence: placementConfidence,
            matchScore: match.score,
            matchReasons: match.reasons
        )
    }

    private static func secureURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
            ?? (try? Date(value, strategy: .iso8601))
    }
}

private struct CollectorAuthor: Decodable {
    let name: String?
    let description: String?
    let profilePicture: String?
}

private struct CollectorMedia: Decodable {
    let kind: String
    let url: String
    let previewUrl: String?

    var catalogMedia: CatalogShinagakiMedia? {
        guard let url = secureURL(url) else { return nil }
        return CatalogShinagakiMedia(
            kind: CatalogShinagakiMedia.Kind(rawValue: kind) ?? .unknown,
            url: url,
            previewURL: secureURL(previewUrl)
        )
    }

    private func secureURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
}

private struct CollectorCircleMatch: Decodable {
    let circleId: Int
    let wcId: Int?
    let score: Int
    let reasons: [String]
}

private struct CollectorPostEnrichment: Decodable {
    let tags: [CollectorTagMatch]

    private enum CodingKeys: String, CodingKey {
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tags = (try? container.decodeIfPresent([CollectorTagMatch].self, forKey: .tags)) ?? []
    }
}

private struct CollectorTagMatch: Decodable {
    let termId: String?
    let canonicalLabel: String?
    let kind: String?
    let provenance: [CollectorTagProvenance]?
    let matchedAlias: String?
    let evidenceLine: String?
    let mediaPath: String?
    let score: Int?

    var catalogTag: CatalogEnrichmentTag? {
        guard let canonicalLabel = canonicalLabel?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
              !canonicalLabel.isEmpty
        else { return nil }

        return CatalogEnrichmentTag(
            termID: termId?.nilIfBlank,
            canonicalLabel: canonicalLabel,
            kind: kind?.nilIfBlank,
            provenance: (provenance ?? []).map(\.catalogProvenance),
            matchedAlias: matchedAlias?.nilIfBlank,
            evidenceLine: evidenceLine?.nilIfBlank,
            mediaPath: mediaPath?.nilIfBlank,
            score: score ?? 0
        )
    }
}

private struct CollectorTagProvenance: Decodable {
    let sourceId: String?
    let recordId: String?
    let url: String?

    var catalogProvenance: CatalogTagProvenance {
        CatalogTagProvenance(
            sourceID: sourceId?.nilIfBlank,
            recordID: recordId?.nilIfBlank,
            url: url?.nilIfBlank
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var catalogTagKey: String {
        precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
