import SwiftUI

/// The surfaces that hold content. See "Surfaces" in docs/design-system.md.
enum SurfaceStyle {
    /// A grouped card on the grouped background: 16 pt radius, hairline stroke.
    case card
    /// A tile nested inside a card: tertiary fill, 12 pt radius, no stroke.
    case inset
    /// Map chrome that floats over the map: Liquid Glass on iOS 26, a
    /// regular material before it.
    case floating
}

private struct SurfaceModifier: ViewModifier {
    let style: SurfaceStyle
    let padding: CGFloat?

    func body(content: Content) -> some View {
        switch style {
        case .card:
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            content
                .padding(padding ?? Spacing.cardPadding)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        case .inset:
            content
                .padding(padding ?? Spacing.medium)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                )
        case .floating:
            let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            let padded = content.padding(padding ?? Spacing.medium)
            if #available(iOS 26.0, *) {
                padded.glassEffect(.regular, in: shape)
            } else {
                padded
                    .background(.regularMaterial, in: shape)
                    .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
            }
        }
    }
}

extension View {
    /// Pads the view and draws a surface behind it.
    /// Example: `VStack { … }.surface(.card)`.
    /// Pass `padding: 0` when the content draws its own insets, such as rows
    /// with dividers.
    func surface(_ style: SurfaceStyle = .card, padding: CGFloat? = nil) -> some View {
        modifier(SurfaceModifier(style: style, padding: padding))
    }
}
