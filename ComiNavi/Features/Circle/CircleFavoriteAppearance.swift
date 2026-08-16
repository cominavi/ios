import SwiftUI
import UIKit

extension BookmarkColor {
    var swiftUIColor: Color {
        switch self {
        case .memoOnly: .gray
        case .orange: Color(red: 1, green: 0.58, blue: 0.29)
        case .magenta: Color(red: 1, green: 0, blue: 1)
        case .yellow: Color(red: 1, green: 0.97, blue: 0)
        case .green: Color(red: 0, green: 0.71, blue: 0.29)
        case .cyan: Color(red: 0, green: 0.71, blue: 1)
        case .purple: Color(red: 0.61, green: 0.32, blue: 0.61)
        case .blue: .blue
        case .lime: .green
        case .red: .red
        }
    }

    var uiColor: UIColor {
        UIColor(swiftUIColor)
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .memoOnly: "Note only"
        case .orange: "Orange"
        case .magenta: "Magenta"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        case .purple: "Purple"
        case .blue: "Blue"
        case .lime: "Lime"
        case .red: "Red"
        }
    }

    fileprivate var favoriteLabelForegroundStyle: Color {
        switch self {
        case .orange, .yellow, .cyan, .lime:
            .black.opacity(0.82)
        case .memoOnly, .magenta, .green, .purple, .blue, .red:
            .white
        }
    }
}

enum FavoriteColorLabelMetrics {
    static let baseHeight: CGFloat = 20

    static func height(compatibleWith traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: baseHeight,
            compatibleWith: traits
        )
    }
}

struct FavoriteColorLabelBadge: View {
    let color: BookmarkColor
    let label: String?

    @ScaledMetric(relativeTo: .caption2)
    private var height = FavoriteColorLabelMetrics.baseHeight
    @ScaledMetric(relativeTo: .caption2)
    private var horizontalPadding: CGFloat = 7

    init(color: BookmarkColor, label: String?) {
        self.color = color
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }

    var body: some View {
        if let label {
            Text(verbatim: label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color.favoriteLabelForegroundStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: 140, minHeight: height, maxHeight: height)
                .background(color.swiftUIColor, in: .capsule)
                .overlay {
                    Capsule()
                        .stroke(.black.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityLabel(Text(verbatim: label))
        } else {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: height, height: height)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityLabel(Text(color.displayName))
        }
    }
}

/// The color mark is aligned to the blank box authored into Circle.ms circle cuts.
/// Pixel scans place its fill area at x/y 7..<55 in the official 211 x 300 cut format;
/// those ratios scale with every rendition.
enum CircleFavoriteMarkGeometry {
    private static let referenceSize = CGSize(width: 211, height: 300)
    private static let referenceRect = CGRect(x: 7, y: 7, width: 48, height: 48)

    static func rect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: size.width * referenceRect.minX / referenceSize.width,
            y: size.height * referenceRect.minY / referenceSize.height,
            width: size.width * referenceRect.width / referenceSize.width,
            height: size.height * referenceRect.height / referenceSize.height
        )
    }
}

struct CircleFavoriteMark: View {
    let color: BookmarkColor?

    var body: some View {
        GeometryReader { proxy in
            if let color, color.isFavorite {
                let rect = CircleFavoriteMarkGeometry.rect(in: proxy.size)
                Rectangle()
                    .fill(color.swiftUIColor)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }
}
