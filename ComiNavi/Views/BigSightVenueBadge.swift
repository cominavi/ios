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

                    VStack(spacing: -side * 0.035) {
                        Text(badge.japanese)
                            .font(.system(size: side * 0.43, weight: .heavy, design: .rounded))

                        // Below 32 pt the English line renders under 4.5 pt
                        // and cannot be read, so small badges show only the
                        // kanji.
                        if side >= Self.minimumSideForEnglish {
                            Text(badge.english)
                                .font(.system(size: side * 0.14, weight: .black, design: .rounded))
                                .tracking(side * 0.006)
                                // Map badges are fixed-size chrome; the design
                                // system allows scaling here.
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(side * 0.12)
                    // The modifier on the GeometryReader alone did not hide
                    // the glyph texts inside a button label.
                    .accessibilityHidden(true)
                }
                .accessibilityHidden(true)
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // The row or button beside the badge already names the hall, so the
        // glyphs (東, EAST) are decoration for VoiceOver.
        .accessibilityHidden(true)
    }

    private func color(for badge: BigSightMapIcon.VenueBadge) -> Color {
        Color(
            red: badge.color.red,
            green: badge.color.green,
            blue: badge.color.blue
        )
    }
}
