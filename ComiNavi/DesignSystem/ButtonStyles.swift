import SwiftUI

/// The app's labeled action buttons.
///
/// - `primary`: the lime fill behind dark text. One per screen or card.
/// - `secondary`: a grouped surface with a hairline stroke and primary text.
/// - `tertiary`: accent text with no fill, for "Show on map"-style links.
///
/// The button fills the width that its container offers. Put two or more of
/// them in an `AdaptiveButtonRow` so the row switches to a column before a
/// title wraps.
struct ActionButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case tertiary
    }

    enum Size {
        /// 44 pt minimum height, `Font.control` titles.
        case regular
        /// 50 pt minimum height, `Font.largeControl` titles.
        case large
    }

    var role: Role
    var size: Size = .regular

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .largeControl : .control)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .tertiary ? 0 : Spacing.large)
            .padding(.vertical, Spacing.small)
            .frame(
                maxWidth: role == .tertiary ? nil : .infinity,
                minHeight: size == .large ? 50 : HitArea.minimum
            )
            .background { background }
            .contentShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: .onAccentFill
        case .secondary: .primary
        case .tertiary: .accentColor
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        switch role {
        case .primary:
            shape.fill(Color.accentFill)
        case .secondary:
            shape
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        case .tertiary:
            Color.clear
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    /// Lime fill, dark text. Example: `.buttonStyle(.primaryAction)`.
    static var primaryAction: ActionButtonStyle { ActionButtonStyle(role: .primary) }
    /// Grouped surface, primary text. Example: `.buttonStyle(.secondaryAction)`.
    static var secondaryAction: ActionButtonStyle { ActionButtonStyle(role: .secondary) }
    /// Accent text, no fill. Example: `.buttonStyle(.tertiaryAction)`.
    static var tertiaryAction: ActionButtonStyle { ActionButtonStyle(role: .tertiary) }
}

/// A capsule chip for filters, tags, and links. Selected chips use the lime
/// fill behind dark text. The drawn capsule is at least 32 pt tall, and the
/// hit area is at least 44 pt tall.
struct ChipButtonStyle: ButtonStyle {
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.control)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.onAccentFill : Color.primary)
            .padding(.horizontal, Spacing.medium)
            // 6 pt: a control-font line plus 12 pt makes the 32 pt capsule.
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background {
                Capsule()
                    .fill(isSelected ? Color.accentFill : Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        Capsule().strokeBorder(Color.hairline.opacity(isSelected ? 0 : 1), lineWidth: 0.5)
                    }
            }
            // Six points above and below take the 32 pt capsule to a 44 pt target.
            .padding(.vertical, (HitArea.minimum - 32) / 2)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    /// Example: `.buttonStyle(.chip)` or `.buttonStyle(.chip(selected: isOn))`.
    static var chip: ChipButtonStyle { ChipButtonStyle() }
    static func chip(selected: Bool) -> ChipButtonStyle { ChipButtonStyle(isSelected: selected) }
}

extension Color {
    /// The 0.5 pt stroke around grouped surfaces, chips, and secondary buttons.
    /// It keeps a white card visible on a white sheet in light mode.
    static var hairline: Color { Color(uiColor: .separator).opacity(0.24) }
}
