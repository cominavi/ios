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
    let alignment: ReadableColumnAlignment

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, margins?.leading, for: .scrollContent)
            .contentMargins(.trailing, margins?.trailing, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
    }

    private var margins: (leading: CGFloat, trailing: CGFloat)? {
        guard horizontalSizeClass == .regular, containerWidth > 0 else { return nil }
        switch alignment {
        case .center:
            let margin = max(Spacing.large, (containerWidth - maxWidth) / 2)
            return (margin, margin)
        case .titleLeading:
            let leading = ReadableColumnAlignment.largeTitleInset
            return (leading, max(leading, containerWidth - leading - maxWidth))
        }
    }
}

/// Where a readable column sits in a regular-width container.
enum ReadableColumnAlignment {
    /// Centered. Use on pushed screens and sheets, which have an inline title.
    case center
    /// On the leading edge of the system large title. Use on a tab root,
    /// which shows a large title below the iPad tab bar.
    case titleLeading

    /// 20 pt: the leading inset of the system large title in a regular-width
    /// navigation bar (measured on iPadOS 26.5 and 27.0). It equals
    /// `Spacing.screenGutter`.
    static let largeTitleInset: CGFloat = Spacing.screenGutter
}

extension View {
    /// Keeps the rows of a `Form` or `List` in a column no wider than
    /// `maxWidth` on regular-width screens. A tab root passes
    /// `.titleLeading`, so the cards start under its large title.
    func readableFormWidth(
        _ maxWidth: CGFloat = ReadableWidth.content,
        alignment: ReadableColumnAlignment = .center
    ) -> some View {
        modifier(ReadableFormWidthModifier(maxWidth: maxWidth, alignment: alignment))
    }

    /// Keeps a non-scrolling column no wider than `maxWidth` and puts it on
    /// the leading edge of the large title in a regular-width container. In a
    /// compact container the column fills the width. Apply it inside the
    /// horizontal `Spacing.screenGutter` padding.
    func readableTitleLeadingWidth(_ maxWidth: CGFloat = ReadableWidth.content) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shows the large title on a tab root in every size class.
    ///
    /// An inline title is not drawn on an iPad tab root: the tab bar takes
    /// the middle of the navigation bar, so the screen loses its title. The
    /// large title sits below the tab bar on iPadOS 26 and 27. Pair it with
    /// `.readableFormWidth(alignment: .titleLeading)` or
    /// `.readableTitleLeadingWidth()`, so the column starts on the leading
    /// edge of the title.
    func readableColumnTitleDisplayMode() -> some View {
        navigationBarTitleDisplayMode(.large)
    }
}
