import SwiftUI
import UIKit

/// A title that ends with a small Lucide glyph drawn inside the text, such as
/// the external-link arrow after "Transit to Tokyo Big Sight ↗".
///
/// The glyph is part of the text run and is joined to the last word with a
/// no-break space, so it wraps together with that word. A glyph in its own
/// `HStack` column instead sits next to the first line, splits the title, and
/// can leave the last word alone on the next line.
///
/// VoiceOver reads only the title. Say what the glyph means in the row hint,
/// for example "Opens in browser".
///
/// ```swift
/// TrailingGlyphText(Text(resource.title), glyph: "external-link")
///     .font(.rowTitle)
/// ```
struct TrailingGlyphText: View {
    private let title: Text
    private let glyph: String
    private let size: Double
    private let glyphStyle: HierarchicalShapeStyle

    /// Dynamic Type multiplier, the same one that `LucideIcon` uses.
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - title: The text. Set its font on this view, not on `title`.
    ///   - glyph: A Lucide or mapped SF Symbol name, as for `LucideIcon`.
    ///   - size: The glyph design size. `IconSize.caption` suits row titles.
    ///   - glyphStyle: The glyph color. Tertiary by default, so the glyph is
    ///     a quiet hint next to the title.
    init(
        _ title: Text,
        glyph: String,
        size: Double = IconSize.caption,
        glyphStyle: HierarchicalShapeStyle = .tertiary
    ) {
        self.title = title
        self.glyph = glyph
        self.size = size
        self.glyphStyle = glyphStyle
        LucideIcon.assertAssetExists(LucideIcon.assetName(for: glyph))
    }

    var body: some View {
        let dimension = LucideIcon.scaledDimension(size, scale: scale)
        Group {
            if let image = Self.glyphImage(glyph, dimension: dimension, displayScale: displayScale) {
                // U+00A0 forbids a break before the glyph, so it never starts
                // a line by itself. The glyph image sits on the baseline; the
                // Lucide 24 pt grid has a 2 pt inset, so it lines up with the
                // cap height of the text.
                Text(Self.joined(title, Text(Image(uiImage: image)).foregroundStyle(glyphStyle)))
            } else {
                title
            }
        }
        // The glyph is decoration; VoiceOver reads the title alone.
        .accessibilityLabel(title)
    }

    /// `title`, a no-break space, and `glyph` as one text run. `Text + Text` is
    /// deprecated in iOS 26, and a string literal such as `"\(title) \(glyph)"`
    /// would add a format key to the string catalog. An interpolation built in
    /// code is neither: its key ("%@ %@") has no catalog entry, so it shows as is.
    private static func joined(_ title: Text, _ glyph: Text) -> LocalizedStringKey {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 1, interpolationCount: 2)
        interpolation.appendInterpolation(title)
        interpolation.appendLiteral("\u{00A0}")
        interpolation.appendInterpolation(glyph)
        return LocalizedStringKey(stringInterpolation: interpolation)
    }

    /// Renders the vector asset at `dimension` points. A non-symbol `Image`
    /// inside `Text` draws at its asset size (24 pt), so it has to be sized
    /// before it goes into the text run.
    @MainActor
    private static func glyphImage(_ glyph: String, dimension: Double, displayScale: CGFloat) -> UIImage? {
        let key = "\(glyph)@\(dimension)x\(displayScale)"
        if let cached = cache[key] {
            return cached
        }
        guard let source = UIImage(named: LucideIcon.assetName(for: glyph)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let size = CGSize(width: dimension, height: dimension)
        let rendered = UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            .withRenderingMode(.alwaysTemplate)
        cache[key] = rendered
        return rendered
    }

    @MainActor private static var cache: [String: UIImage] = [:]
}
