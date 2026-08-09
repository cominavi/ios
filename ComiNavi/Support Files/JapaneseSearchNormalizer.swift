import Foundation

enum JapaneseSearchNormalizer {
    static func normalize(_ value: String) -> String {
        let folded = value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ja_JP")
            )
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    static func normalizedTerms(in value: String) -> [String] {
        normalize(value)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func searchableText(_ values: [String]) -> String {
        normalize(values.joined(separator: "\n"))
    }

    static func containsAll(_ normalizedTerms: [String], in values: [String]) -> Bool {
        let text = searchableText(values)
        return normalizedTerms.allSatisfy(text.contains)
    }
}
