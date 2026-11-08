import SwiftUI

// Design tokens. See docs/design-system.md for the rules behind each value.
// Use these names instead of literal numbers so that screens share one rhythm.

/// The spacing scale, in points. Every padding and stack spacing uses one of
/// these steps. Values off the scale need a comment that explains why.
enum Spacing {
    /// 2 pt. Between a title and its subtitle inside one text block.
    static let xxSmall: CGFloat = 2
    /// 4 pt. Between an icon and a short caption, or inside a badge.
    static let xSmall: CGFloat = 4
    /// 8 pt. Between related controls, chips, and lines of a row.
    static let small: CGFloat = 8
    /// 12 pt. Between an icon and its row text, and between stacked buttons.
    static let medium: CGFloat = 12
    /// 16 pt. Card padding and the gap between cards.
    static let large: CGFloat = 16
    /// 20 pt. The horizontal screen gutter on iPhone.
    static let xLarge: CGFloat = 20
    /// 24 pt. The gap between sections.
    static let xxLarge: CGFloat = 24
    /// 32 pt. Above a hero block or an empty state.
    static let xxxLarge: CGFloat = 32

    /// Horizontal inset of scroll content from the screen edge.
    static let screenGutter: CGFloat = xLarge
    /// Inner padding of a card surface.
    static let cardPadding: CGFloat = large
    /// Gap between a leading icon and the text it labels in a row.
    static let iconToText: CGFloat = medium
    /// Gap between two sections of a scrolling screen.
    static let sectionGap: CGFloat = xxLarge
}

/// The corner radius scale. All shapes use `.continuous` corners.
enum Radius {
    /// 6 pt. Badges and tiny thumbnails.
    static let xSmall: CGFloat = 6
    /// 8 pt. Thumbnails and nested tiles inside a control.
    static let small: CGFloat = 8
    /// 12 pt. Buttons, inset rows, and text fields.
    static let control: CGFloat = 12
    /// 16 pt. Cards and grouped surfaces.
    static let card: CGFloat = 16
    /// 24 pt. Floating panels and sheets drawn by the app.
    static let panel: CGFloat = 24

    /// The radius of a shape nested `inset` points inside a shape with radius
    /// `outer`, so the two corners share one center.
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, xSmall)
    }
}

/// Lucide icon design sizes. `LucideIcon` scales each with Dynamic Type.
enum IconSize {
    /// 12 pt. A trailing glyph inside a chip, for example the remove "x".
    static let chipAccessory: Double = 12
    /// 14 pt. Next to caption or footnote text.
    static let caption: Double = 14
    /// 17 pt. Next to body or subheadline text, and inside buttons.
    static let inline: Double = 17
    /// 20 pt. The leading icon of a row or a card.
    static let row: Double = 20
    /// 22 pt. The leading icon of a large action card, and toolbar glyphs.
    static let action: Double = 22
    /// 34 pt. The glyph of an empty state.
    static let hero: Double = 34
}

/// Maximum widths that keep text at a readable measure on iPad.
enum ReadableWidth {
    /// 720 pt. Scrolling content columns.
    static let content: CGFloat = 720
    /// 560 pt. Forms, sheets, and single-purpose dialogs.
    static let form: CGFloat = 560
    /// 360 pt. Floating cards over the map and onboarding dialogs.
    static let floatingCard: CGFloat = 360
}

/// The minimum interactive size from the Human Interface Guidelines.
enum HitArea {
    static let minimum: CGFloat = 44
}

extension View {
    /// Grows the tappable area to at least 44 by 44 pt without changing the
    /// drawn size. Use on icon-only buttons and small chips.
    func minimumHitArea() -> some View {
        frame(minWidth: HitArea.minimum, minHeight: HitArea.minimum)
            .contentShape(.rect)
    }

    /// Centers the view in a column no wider than `maxWidth`.
    func readableWidth(_ maxWidth: CGFloat = ReadableWidth.content) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}
