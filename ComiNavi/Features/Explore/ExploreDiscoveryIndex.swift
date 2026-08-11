import Foundation

enum ExploreDiscoveryKind: String, Sendable {
    case tag

    var title: LocalizedStringResource {
        "Tag"
    }

    var systemImage: String {
        "tag.fill"
    }
}

struct ExploreDiscoveryTerm: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ExploreDiscoveryKind
    let count: Int
    let prominence: Int
}

enum ExploreDiscoveryMatchMode: String, CaseIterable, Identifiable, Sendable {
    case any
    case all

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .any: "Match any"
        case .all: "Match all"
        }
    }

    var shortTitle: LocalizedStringResource {
        switch self {
        case .any: "Any"
        case .all: "All"
        }
    }
}

struct ExploreDiscoveryDocument: Sendable {
    let circleID: Int
    let tags: [String]
}

struct ExploreDiscoveryIndex: Sendable {
    let terms: [ExploreDiscoveryTerm]
    let circleIDsByTermID: [String: Set<Int>]

    static let empty = ExploreDiscoveryIndex(terms: [], circleIDsByTermID: [:])
}

enum ExploreDiscoveryIndexBuilder {
    private struct Candidate {
        let id: String
        let title: String
        let kind: ExploreDiscoveryKind
        let circleIDs: Set<Int>
    }

    static func build(
        from documents: [ExploreDiscoveryDocument],
        tagLimit: Int = 12
    ) -> ExploreDiscoveryIndex {
        guard !documents.isEmpty else { return .empty }

        let candidates = tagCandidates(from: documents, limit: tagLimit)
        let terms = candidates.enumerated().map { index, candidate in
            ExploreDiscoveryTerm(
                id: candidate.id,
                title: candidate.title,
                kind: candidate.kind,
                count: candidate.circleIDs.count,
                prominence: index < 6 ? 2 : (index < 15 ? 1 : 0)
            )
        }
        return ExploreDiscoveryIndex(
            terms: terms,
            circleIDsByTermID: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.circleIDs) })
        )
    }

    private static func tagCandidates(
        from documents: [ExploreDiscoveryDocument],
        limit: Int
    ) -> [Candidate] {
        var titlesByKey: [String: String] = [:]
        var circleIDsByKey: [String: Set<Int>] = [:]
        for document in documents {
            for tag in document.tags {
                let title = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalized(title)
                guard !key.isEmpty else { continue }
                titlesByKey[key] = titlesByKey[key] ?? title
                circleIDsByKey[key, default: []].insert(document.circleID)
            }
        }
        return circleIDsByKey.compactMap { key, circleIDs in
            titlesByKey[key].map {
                Candidate(
                    id: "tag:\(key)",
                    title: $0,
                    kind: .tag,
                    circleIDs: circleIDs
                )
            }
        }
        .sorted(by: candidateOrder)
        .prefix(limit)
        .map { $0 }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.circleIDs.count != rhs.circleIDs.count {
            return lhs.circleIDs.count > rhs.circleIDs.count
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
