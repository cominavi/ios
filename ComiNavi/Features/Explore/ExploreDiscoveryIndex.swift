import Foundation
import NaturalLanguage

enum ExploreDiscoveryKind: String, Sendable {
    case genre
    case tag
    case keyword

    var title: LocalizedStringResource {
        switch self {
        case .genre: "Genre"
        case .tag: "Tag"
        case .keyword: "Keyword"
        }
    }

    var systemImage: String {
        switch self {
        case .genre: "theatermasks.fill"
        case .tag: "tag.fill"
        case .keyword: "text.magnifyingglass"
        }
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
    let genreID: Int?
    let genreName: String?
    let tags: [String]
    let text: String
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
        let rankingScore: Double
    }

    private struct KeywordAggregate {
        var title: String
        var circleIDs: Set<Int>
        var countsByGenreID: [Int: Int]
    }

    private static let stopWords: Set<String> = [
        "and", "book", "center", "circle", "comiket", "comic", "for", "from", "goods", "market",
        "more", "new", "other", "the", "this", "with",
        "あり", "いたします", "イラスト", "グッズ", "コミケ", "コミックマーケット", "こちら",
        "こと", "この", "サークル", "します", "セット", "その", "その他", "です", "など", "ない", "なし",
        "ます", "マンガ", "メイン", "もの", "よろしく", "中心", "予定", "作品", "制作", "参加", "合同",
        "同人誌", "頒布", "当日", "新刊", "本", "漫画", "今回",
    ]

    static func build(
        from documents: [ExploreDiscoveryDocument],
        genreLimit: Int = 6,
        tagLimit: Int = 9,
        keywordLimit: Int = 9
    ) -> ExploreDiscoveryIndex {
        guard !documents.isEmpty else { return .empty }

        let genres = genreCandidates(from: documents, limit: genreLimit)
        let officialLabels = Set(
            documents.compactMap(\.genreName) + documents.flatMap(\.tags)
        )
        let excludedWords = Set(officialLabels.flatMap { label in
            [normalized(label)] + normalizedTokens(in: label)
        })
        let tags = tagCandidates(from: documents, limit: tagLimit)
        let keywords = keywordCandidates(
            from: documents,
            excluding: excludedWords,
            limit: keywordLimit
        )

        let candidates = interleaved([genres, keywords, tags])
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

    private static func genreCandidates(
        from documents: [ExploreDiscoveryDocument],
        limit: Int
    ) -> [Candidate] {
        var namesByID: [Int: String] = [:]
        var circleIDsByGenreID: [Int: Set<Int>] = [:]
        for document in documents {
            guard let genreID = document.genreID,
                  let name = document.genreName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            namesByID[genreID] = name
            circleIDsByGenreID[genreID, default: []].insert(document.circleID)
        }
        return circleIDsByGenreID.compactMap { genreID, circleIDs in
            namesByID[genreID].map {
                Candidate(
                    id: "genre:\(genreID)",
                    title: $0,
                    kind: .genre,
                    circleIDs: circleIDs,
                    rankingScore: Double(circleIDs.count)
                )
            }
        }
        .sorted(by: candidateOrder)
        .prefix(limit)
        .map { $0 }
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
                    circleIDs: circleIDs,
                    rankingScore: Double(circleIDs.count)
                )
            }
        }
        .sorted(by: candidateOrder)
        .prefix(limit)
        .map { $0 }
    }

    private static func keywordCandidates(
        from documents: [ExploreDiscoveryDocument],
        excluding excludedWords: Set<String>,
        limit: Int
    ) -> [Candidate] {
        var aggregates: [String: KeywordAggregate] = [:]

        for document in documents {
            var wordsInDocument: [String: String] = [:]
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = document.text
            tokenizer.enumerateTokens(in: document.text.startIndex..<document.text.endIndex) { range, _ in
                let title = String(document.text[range])
                    .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                let key = normalized(title)
                if isUsefulKeyword(title: title, normalized: key), !excludedWords.contains(key) {
                    wordsInDocument[key] = wordsInDocument[key] ?? title
                }
                return true
            }

            for (key, title) in wordsInDocument {
                var aggregate = aggregates[key] ?? KeywordAggregate(
                    title: title,
                    circleIDs: [],
                    countsByGenreID: [:]
                )
                aggregate.circleIDs.insert(document.circleID)
                if let genreID = document.genreID {
                    aggregate.countsByGenreID[genreID, default: 0] += 1
                }
                aggregates[key] = aggregate
            }
        }

        let minimumCount = documents.count >= 1_000
            ? min(12, max(4, documents.count / 1_500))
            : 2
        return aggregates.compactMap { key, aggregate in
            guard aggregate.circleIDs.count >= minimumCount else { return nil }
            return Candidate(
                id: "keyword:\(key)",
                title: aggregate.title,
                kind: .keyword,
                circleIDs: aggregate.circleIDs,
                rankingScore: keywordScore(for: aggregate)
            )
        }
        .sorted(by: candidateOrder)
        .prefix(limit)
        .map { $0 }
    }

    private static func isUsefulKeyword(title: String, normalized key: String) -> Bool {
        let length = title.count
        guard (2...24).contains(length),
              !key.isEmpty,
              !stopWords.contains(key),
              title.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !title.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        else { return false }
        return !key.hasPrefix("http") && !key.contains("twitter")
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTokens(in value: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
            let token = normalized(String(value[range]))
            if !token.isEmpty {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.rankingScore != rhs.rankingScore {
            return lhs.rankingScore > rhs.rankingScore
        }
        if lhs.circleIDs.count != rhs.circleIDs.count {
            return lhs.circleIDs.count > rhs.circleIDs.count
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func keywordScore(for aggregate: KeywordAggregate) -> Double {
        let strongestGenreCount = aggregate.countsByGenreID.values.max() ?? 0
        guard strongestGenreCount > 0 else { return 0 }
        return Double(strongestGenreCount) / sqrt(Double(aggregate.circleIDs.count))
    }

    private static func interleaved(_ groups: [[Candidate]]) -> [Candidate] {
        let maximumCount = groups.map(\.count).max() ?? 0
        return (0..<maximumCount).flatMap { index in
            groups.compactMap { group in
                group.indices.contains(index) ? group[index] : nil
            }
        }
    }
}
