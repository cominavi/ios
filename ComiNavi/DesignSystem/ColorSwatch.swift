import SwiftUI

/// A filled circle that shows a favorite label color.
///
/// The 0.5 pt hairline keeps dark colors (black, navy) visible on the dark
/// grouped background, where a black stroke disappears. Use `IconSize.row`
/// next to row titles and `IconSize.caption` next to footnote text.
///
/// `ColorSwatch(color: color.swiftUIColor, size: IconSize.row)`
struct ColorSwatch: View {
    let color: Color
    var size: Double = IconSize.row

    var body: some View {
        Circle()
            .fill(color)
            .overlay {
                Circle().strokeBorder(Color.hairline, lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
