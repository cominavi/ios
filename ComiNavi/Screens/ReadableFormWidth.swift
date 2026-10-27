import SwiftUI

/// Keeps a `Form` or `List` in a readable column on iPad.
///
/// A grouped `Form` draws its own cards, so `.readableWidth()` (a frame) does
/// not work on it: the scroll view still spans the screen and the rows grow
/// with it. This modifier instead widens the horizontal content margins of
/// the scroll content until the cards are `maxWidth` wide. In a compact
/// container it keeps the system margins.
///
/// `Form { … }.readableFormWidth()`
private struct ReadableFormWidthModifier: ViewModifier {
    let maxWidth: CGFloat

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
    }

    private var horizontalMargin: CGFloat? {
        guard horizontalSizeClass == .regular, containerWidth > 0 else { return nil }
        return max(Spacing.large, (containerWidth - maxWidth) / 2)
    }
}

extension View {
    /// Centers the rows of a `Form` or `List` in a column no wider than
    /// `maxWidth` on regular-width screens.
    func readableFormWidth(_ maxWidth: CGFloat = ReadableWidth.content) -> some View {
        modifier(ReadableFormWidthModifier(maxWidth: maxWidth))
    }

    /// Uses an inline navigation title in a regular-width container, so a
    /// large title does not start outside the readable column.
    func readableColumnTitleDisplayMode() -> some View {
        modifier(ReadableColumnTitleDisplayModeModifier())
    }
}

private struct ReadableColumnTitleDisplayModeModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(
            horizontalSizeClass == .regular ? .inline : .automatic
        )
    }
}
