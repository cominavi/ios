import SwiftUI

// Type roles. Each maps to a Dynamic Type text style, so text scales with the
// user's setting. Do not use `.system(size:)` outside the documented exceptions
// in docs/design-system.md (map chrome drawn at a fixed scale, venue badges).

extension Font {
    /// A section title inside a scrolling screen.
    static var sectionTitle: Font { .title3.weight(.semibold) }
    /// The title of a card, a row, or a large action.
    static var rowTitle: Font { .headline }
    /// The secondary line of a row or a card.
    static var rowSubtitle: Font { .subheadline }
    /// Metadata such as dates, counts, and hall names.
    static var meta: Font { .footnote }
    /// Badge and chip-count text.
    static var badge: Font { .caption2.weight(.semibold) }
    /// Button titles in regular-size buttons and chips.
    static var control: Font { .subheadline.weight(.semibold) }
    /// Button titles in large primary buttons.
    static var largeControl: Font { .headline }
    /// Space codes such as `東A01a`. Digits keep one width, so codes align.
    static var spaceCode: Font { .headline.monospacedDigit() }
    /// The hero title of a full-screen focused state (`FocusedActionSurface`),
    /// such as "Downloading catalog". A documented exception to the type
    /// roles: the rounded large title is the identity of these one-message
    /// screens. It still scales with Dynamic Type.
    static var focusedSurfaceTitle: Font {
        .system(.largeTitle, design: .rounded, weight: .bold)
    }
}

extension View {
    /// Lets multiline text grow to its full height instead of truncating when
    /// a parent proposes a limited height. Use on every body paragraph,
    /// caption, and subtitle that may wrap.
    func wrapsFully() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    /// Keeps a short label on one line at its ideal width. Use only for
    /// tokens that must never wrap and that are short by design: badges,
    /// counts, space codes. Never use it on sentences or translated titles.
    func singleLineToken() -> some View {
        lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Text helpers that stop a line break inside a unit that must stay whole,
/// such as a space code (`東A01a`), a hall name (`West 1–2`), or a date
/// (`Aug 11`). The text can still wrap before or after the unit.
enum NonBreaking {
    /// U+00A0 NO-BREAK SPACE.
    static let space: Character = "\u{00A0}"
    /// U+2060 WORD JOINER. It has no width and forbids a break at its position.
    static let wordJoiner: Character = "\u{2060}"

    /// Replaces ordinary spaces with no-break spaces. Use for Latin-script
    /// units such as "Aug 11" or "West 1–2".
    static func spaces(_ text: String) -> String {
        String(text.map { $0 == " " ? space : $0 })
    }

    /// Joins every character with a word joiner and replaces spaces with
    /// no-break spaces. Use for CJK space codes such as "西あ01a", where the
    /// line breaker otherwise may break between any two characters. Use the
    /// result for display only: copy and search the original string.
    static func unit(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count * 2)
        for character in text {
            if !result.isEmpty {
                result.append(wordJoiner)
            }
            result.append(character == " " ? space : character)
        }
        return result
    }
}

extension Text {
    /// A text view that never breaks inside `unit`. See `NonBreaking.unit(_:)`.
    init(nonBreaking unit: String) {
        self.init(verbatim: NonBreaking.unit(unit))
    }
}
