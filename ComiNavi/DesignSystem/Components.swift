import SwiftUI

/// A small status capsule such as "Past event" or "Demo". It never wraps and
/// never truncates; keep its text to one or two words.
///
/// `StatusBadge("Demo", tone: .accent)`
struct StatusBadge: View {
    enum Tone {
        /// Grey fill, secondary text.
        case neutral
        /// Lime fill, dark text.
        case accent
        /// Orange text on a pale orange fill.
        case warning
    }

    private let title: Text
    private let tone: Tone

    init(_ title: LocalizedStringKey, tone: Tone = .neutral) {
        self.title = Text(title)
        self.tone = tone
    }

    init(_ title: Text, tone: Tone = .neutral) {
        self.title = title
        self.tone = tone
    }

    var body: some View {
        title
            .font(.badge)
            .foregroundStyle(foreground)
            .singleLineToken()
            // 6 pt: off the scale on purpose; the capsule stays compact.
            .padding(.horizontal, 6)
            .padding(.vertical, Spacing.xxSmall)
            .background(background, in: .capsule)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: .secondary
        case .accent: .onAccentFill
        case .warning: .orange
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color(uiColor: .tertiarySystemFill)
        case .accent: .accentFill
        case .warning: .orange.opacity(0.14)
        }
    }
}

/// A section title for scrolling screens that are not a `List`. Inside a
/// `List`, use the native `Section` header instead.
///
/// `SectionHeader("Quick access", subtitle: "For the event day")`
struct SectionHeader<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                title
                    .font(.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .wrapsFully()
            // The title keeps its width, and the accessory gives way first.
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// An empty or unavailable state with an optional action.
///
/// ```swift
/// EmptyStateView("No favorites yet", icon: "star",
///                message: "Tap the star on a circle to save it.") {
///     Button("Explore circles") { … }.buttonStyle(.primaryAction)
/// }
/// ```
struct EmptyStateView<Actions: View>: View {
    private let title: LocalizedStringKey
    private let icon: String
    private let message: Text?
    private let actions: Actions

    init(
        _ title: LocalizedStringKey,
        icon: String,
        message: LocalizedStringKey? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.icon = icon
        self.message = message.map { Text($0) }
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Spacing.medium) {
                LucideIcon(icon, size: IconSize.hero)
                    .foregroundStyle(.secondary)
                Text(title)
            }
        } description: {
            if let message {
                message
            }
        } actions: {
            actions
                .frame(maxWidth: ReadableWidth.floatingCard)
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, icon: String, message: LocalizedStringKey? = nil) {
        self.init(title, icon: icon, message: message) { EmptyView() }
    }
}

/// A one-line notice inside a screen, such as "Event notices for C104 are not
/// available." It is not a button. Use a row for anything the person can tap.
///
/// `InlineBanner("No item list or tags for this circle yet.", icon: "info.circle")`
struct InlineBanner: View {
    enum Tone {
        case info
        case warning
    }

    private let message: Text
    private let icon: String
    private let tone: Tone

    init(_ message: LocalizedStringKey, icon: String = "info.circle", tone: Tone = .info) {
        self.message = Text(message)
        self.icon = icon
        self.tone = tone
    }

    init(_ message: Text, icon: String = "info.circle", tone: Tone = .info) {
        self.message = message
        self.icon = icon
        self.tone = tone
    }

    var body: some View {
        // `Label` centers the icon on the first line of a wrapped message.
        Label {
            message
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
                .wrapsFully()
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            LucideIcon(icon, size: IconSize.inline)
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
        }
        .font(.rowSubtitle)
        .surface(.card)
        .accessibilityElement(children: .combine)
    }
}
