import SwiftUI

/// The bilingual hall badge (東 EAST) in SwiftUI. It shares its shape ratios
/// and rim colors with the SpriteKit badge in `UnifiedBigSightScene`, through
/// `UnifiedMapMarkerMetrics` and `UnifiedMapAppearance`.
struct BigSightVenueBadge: View {
    private static let minimumSideForEnglish: CGFloat = 32

    let icon: BigSightMapIcon

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            if let badge = icon.venueBadge {
                let appearance = UnifiedMapAppearance(colorScheme)
                let outerRadius = UnifiedMapMarkerMetrics.venueBadgeCornerRadius(side: side)
                ZStack {
                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                        .fill(Color(uiColor: appearance.venueBadgeRim))
                        .overlay {
                            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                                .strokeBorder(
                                    Color(uiColor: appearance.venueBadgeRimStroke),
                                    lineWidth: max(0.5, side * 0.018)
                                )
                        }

                    RoundedRectangle(
                        cornerRadius: UnifiedMapMarkerMetrics.venueBadgePlateRadius(side: side),
                        style: .continuous
                    )
                    .fill(color(for: badge))
                    .padding(UnifiedMapMarkerMetrics.venueBadgePlateInset(side: side))

                    // The glyphs are drawn in a Canvas, not as Text views:
                    // inside a button label, hidden Text views still showed
                    // up as "東" and "西" static texts in English UI. The
                    // row or button beside the badge names the hall.
                    Canvas { context, size in
                        drawGlyphs(badge, side: side, in: &context, size: size)
                    }
                }
                .accessibilityHidden(true)
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // The row or button beside the badge already names the hall, so the
        // glyphs (東, EAST) are decoration for VoiceOver. Collapse the glyph
        // texts into one element first: inside a plain-style button label,
        // `accessibilityHidden` alone left them exposed as static texts.
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    /// The kanji line and, from 32 pt, the English line under it, centered
    /// as a block. The English line shrinks to 80 % before it overflows;
    /// map badges are fixed-size chrome, where the design system allows it.
    private func drawGlyphs(
        _ badge: BigSightMapIcon.VenueBadge,
        side: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let inset = side * 0.12
        let available = CGSize(width: max(1, size.width - inset * 2), height: size.height)
        let japanese = context.resolve(
            Text(verbatim: badge.japanese)
                .font(.system(size: side * 0.43, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        )
        let japaneseSize = japanese.measure(in: CGSize(width: CGFloat.infinity, height: size.height))

        var english: GraphicsContext.ResolvedText?
        var englishSize = CGSize.zero
        var englishScale: CGFloat = 1
        if side >= Self.minimumSideForEnglish {
            let resolved = context.resolve(
                Text(verbatim: badge.english)
                    .font(.system(size: side * 0.14, weight: .black, design: .rounded))
                    .tracking(side * 0.006)
                    .foregroundColor(.white)
            )
            englishSize = resolved.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
            if englishSize.width > available.width {
                englishScale = max(0.8, available.width / englishSize.width)
            }
            english = resolved
        }

        let spacing = english == nil ? 0 : -side * 0.035
        let blockHeight = japaneseSize.height + spacing + englishSize.height * englishScale
        var top = (size.height - blockHeight) / 2
        context.draw(japanese, at: CGPoint(x: size.width / 2, y: top), anchor: .top)
        top += japaneseSize.height + spacing

        if let english {
            var englishContext = context
            englishContext.translateBy(x: size.width / 2, y: top)
            englishContext.scaleBy(x: englishScale, y: englishScale)
            englishContext.draw(english, at: .zero, anchor: .top)
        }
    }

    private func color(for badge: BigSightMapIcon.VenueBadge) -> Color {
        Color(
            red: badge.color.red,
            green: badge.color.green,
            blue: badge.color.blue
        )
    }
}
