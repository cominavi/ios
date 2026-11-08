import SwiftUI
import UIKit

/// A row with a leading icon centered on the first line of the text beside it.
///
/// A system `Label` centers the icon on the whole text block, and at
/// accessibility sizes it lets the text wrap under the icon. `IconRow` keeps
/// the icon next to the first line and the text column at one x position in
/// every row, so a list of rows lines up at every text size.
///
/// Pass the text style of the first line, so the icon centers on that line:
///
/// ```swift
/// IconRow(icon: "calendar-clock", textStyle: .headline) {
///     Text("C108 event reminders").font(.rowTitle)
/// }
/// ```
struct IconRow<Content: View>: View {
    let icon: String
    var iconSize: Double = IconSize.row
    var iconStyle: Color = .accentColor
    @ViewBuilder let content: Content
    /// The line height of the first text line, scaled with Dynamic Type.
    @ScaledMetric private var firstLineHeight: CGFloat

    init(
        icon: String,
        iconSize: Double = IconSize.row,
        iconStyle: Color = .accentColor,
        textStyle: UIFont.TextStyle,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconSize = iconSize
        self.iconStyle = iconStyle
        self.content = content()
        let baseline = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).lineHeight
        _firstLineHeight = ScaledMetric(wrappedValue: baseline, relativeTo: Self.fontTextStyle(textStyle))
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.iconToText) {
            LucideIcon(icon, size: iconSize)
                .foregroundStyle(iconStyle)
                .frame(minHeight: firstLineHeight)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func fontTextStyle(_ style: UIFont.TextStyle) -> Font.TextStyle {
        switch style {
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption1: .caption
        default: .body
        }
    }
}
