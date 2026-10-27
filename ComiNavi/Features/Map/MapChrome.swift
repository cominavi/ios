import SwiftUI

/// The outline of a floating control over the map.
enum MapChromeShape {
    /// Pills: the hall selector, the search field, the Go to Space button.
    case capsule
    /// 44 pt icon buttons: layers, search, location, compass.
    case circle
    /// Cards that hold rows: search results, the genre legend, dialogs.
    case panel
}

extension View {
    /// Draws the one surface that every floating map control shares:
    /// Liquid Glass on iOS 26, and a regular material with a hairline before
    /// it. Text on it uses `.primary`; accent is only for an active state.
    ///
    /// `LucideIcon("search").frame(width: 44, height: 44).mapChromeSurface(.circle)`
    @ViewBuilder
    func mapChromeSurface(_ shape: MapChromeShape) -> some View {
        switch shape {
        case .capsule:
            modifier(MapChromeSurfaceModifier(shape: Capsule()))
        case .circle:
            modifier(MapChromeSurfaceModifier(shape: Circle()))
        case .panel:
            modifier(
                MapChromeSurfaceModifier(
                    shape: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                )
            )
        }
    }
}

private struct MapChromeSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        }
    }
}

/// The glyph of a 44 pt round map control. Every round control over the map
/// uses this label, so the glyphs share one size and one inset.
struct MapChromeIconLabel: View {
    let icon: String
    var isActive = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        LucideIcon(icon, size: IconSize.inline)
            // The circle keeps a fixed 44 pt size over the map, so the glyph
            // stops growing at XXXL and keeps its inset at accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            // A disabled control dims its glyph and keeps its full surface,
            // so it still reads as a button in the tool row.
            .foregroundStyle(glyphStyle)
            .frame(width: HitArea.minimum, height: HitArea.minimum)
            .mapChromeSurface(.circle)
            .contentShape(.circle)
    }

    private var glyphStyle: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(.tertiary) }
        return isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
    }
}

/// The close control of every sheet that opens from the map: an "x" at the
/// trailing edge of the navigation bar with a 44 pt target.
struct MapSheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon("xmark", size: IconSize.inline)
                .minimumHitArea()
        }
        .accessibilityLabel(Text("Close"))
    }
}

extension ComiketSpaceAddress {
    /// The address for display in a text view, in which no unit can break
    /// across lines. The ` · ` separators stay breakable, so a long full
    /// address wraps between day, hall, and space code. Copy and search the
    /// plain `formatted(_:)` string, not this one.
    func displayText(_ style: DisplayStyle) -> String {
        formatted(style)
            .components(separatedBy: " · ")
            .map(NonBreaking.unit)
            .joined(separator: " · ")
    }
}
