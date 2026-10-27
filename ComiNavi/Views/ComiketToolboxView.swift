import SwiftUI
import UIKit

/// The Toolbox hub: venue quick actions first, then the selected event's notices,
/// then links to the checklist, reminders, and official links.
struct ComiketToolboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var checklistStore: ComiketChecklistStore
    @State private var reminderStore: ComiketReminderStore
    @State private var searchText = ""
    @State private var copiedVenue = false
    @State private var isNoticeExpanded = true
    private let event: CatalogEvent?

    @MainActor
    init(
        event: CatalogEvent? = nil,
        checklistStore: ComiketChecklistStore = ComiketChecklistStore(),
        reminderStore: ComiketReminderStore = ComiketReminderStore()
    ) {
        self.event = event
        _checklistStore = State(initialValue: checklistStore)
        _reminderStore = State(initialValue: reminderStore)
    }

    /// Re-evaluated on every render, so event-specific content disappears once
    /// the edition's validity window ends even if the screen stays open.
    private var edition: ComiketToolboxEdition? {
        ComiketToolboxEdition.current(forEventNumber: event?.number)
    }

    private var showsReminders: Bool {
        edition?.eventNumber == ComiketEventReminderCatalog.eventNumber
    }

    private var searchResults: [ComiketToolboxSection] {
        ComiketToolboxCatalog.sections(for: edition, matching: searchText)
    }

    /// The navigation-bar drawer spans the full screen width, so on iPad it would
    /// not line up with the readable column. Regular width puts the field in the
    /// toolbar instead.
    private var searchPlacement: SearchFieldPlacement {
        horizontalSizeClass == .regular ? .toolbar : .navigationBarDrawer(displayMode: .always)
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                ToolboxQuickAccess(copiedVenue: $copiedVenue)

                if let edition {
                    ToolboxEditionNotice(edition: edition, isExpanded: $isNoticeExpanded)
                }

                Section {
                    NavigationLink {
                        ToolboxChecklistScreen(store: checklistStore)
                    } label: {
                        ToolboxHubRow(title: "Day-of checklist", icon: "list-checks") {
                            Text(
                                verbatim:
                                    "\(checklistStore.completedCount)/\(ComiketChecklistCatalog.items.count)"
                            )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .singleLineToken()
                        }
                    }
                    .accessibilityIdentifier("toolbox-open-checklist")

                    if let edition, showsReminders {
                        NavigationLink {
                            ToolboxReminderScreen(store: reminderStore, edition: edition)
                        } label: {
                            ToolboxHubRow(title: "Event reminders", icon: "calendar-clock")
                        }
                        .accessibilityIdentifier("toolbox-open-reminders")
                    }

                    NavigationLink {
                        ToolboxResourcesScreen(
                            sections: ComiketToolboxCatalog.sections(for: edition)
                        )
                    } label: {
                        ToolboxHubRow(title: "Official links", icon: "globe")
                    }
                    .accessibilityIdentifier("toolbox-open-official-links")
                } footer: {
                    // Without an edition, a footnote explains the missing notices and
                    // reminders instead of a separate card that competes with the actions.
                    if edition == nil {
                        ToolboxNoEditionNote(event: event)
                    }
                }
            } else {
                ForEach(searchResults) { section in
                    ToolboxResourceSectionView(section: section)
                }
            }
        }
        .overlay {
            if !searchText.isEmpty, searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .readableFormWidth()
        .hardTopScrollEdge()
        .navigationTitle("Toolbox")
        #if DEBUG
        .modifier(ToolboxLaunchRouteModifier(
            checklistStore: checklistStore,
            sections: ComiketToolboxCatalog.sections(for: edition)
        ))
        #endif
        .searchable(
            text: $searchText,
            placement: searchPlacement,
            prompt: "Search official links"
        )
        .task {
            await reminderStore.refresh()
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task { await reminderStore.refresh() }
        }
        .onChange(of: reminderStore.errorMessage) { _, message in
            guard let message else { return }
            AppToast.showError(
                String(localized: "Could not update reminders"),
                subtitle: message
            )
            reminderStore.dismissError()
        }
    }
}

private struct ToolboxChecklistScreen: View {
    let store: ComiketChecklistStore

    var body: some View {
        List {
            ToolboxChecklistSection(store: store)
        }
        .readableFormWidth()
        .navigationTitle("Day-of checklist")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolboxReminderScreen: View {
    let store: ComiketReminderStore
    let edition: ComiketToolboxEdition

    var body: some View {
        List {
            ToolboxReminderSection(store: store, edition: edition)
        }
        .readableFormWidth()
        .navigationTitle("Event reminders")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolboxResourcesScreen: View {
    let sections: [ComiketToolboxSection]

    var body: some View {
        List {
            ForEach(sections) { section in
                ToolboxResourceSectionView(section: section)
            }
        }
        .readableFormWidth()
        .navigationTitle("Official links")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolboxReminderSection: View {
    let store: ComiketReminderStore
    let edition: ComiketToolboxEdition
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Grows with Dynamic Type so the times stay aligned without clipping.
    @ScaledMetric(relativeTo: .headline) private var timeColumnWidth = 50.0

    private var needsSettingsButton: Bool {
        switch store.state {
        case .denied:
            true
        case .authorized(let timeSensitiveEnabled):
            !timeSensitiveEnabled
        case .checking, .notDetermined:
            false
        }
    }

    var body: some View {
        Section {
            IconRow(icon: "calendar-clock", iconStyle: .orange, textStyle: .headline) {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("\(edition.shortName) event reminders")
                        .font(.rowTitle)
                        .wrapsFully()

                    Text("Get a Time Sensitive alert 15 minutes before each selected time, on both event days.")
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
            }
            .accessibilityElement(children: .combine)

            if store.isSchedulable {
                ForEach(ComiketReminderKind.allCases) { kind in
                    Toggle(
                        isOn: Binding(
                            get: { store.isEnabled(kind) },
                            set: { enabled in
                                store.setEnabledOptimistically(enabled, for: kind)
                            }
                        )
                    ) {
                        reminderLabel(for: kind)
                    }
                    // A milestone whose fire dates have all passed cannot schedule anything.
                    .disabled(!store.hasFutureFireDate(for: kind))
                    .accessibilityIdentifier("toolbox-reminder-\(kind.rawValue)")
                }

                reminderStatus

                if needsSettingsButton {
                    Button("Open notification settings") {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString)
                        else { return }
                        UIApplication.shared.open(url)
                    }
                    .accessibilityIdentifier("toolbox-reminder-open-settings")
                }
            } else {
                Text("Reminders for \(edition.shortName) have ended.")
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                    .accessibilityIdentifier("toolbox-reminders-ended")
            }
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                if store.isSchedulable {
                    Text(
                        "Reminders are set on this device only. Delivery follows your iOS notification settings."
                    )
                }
                Link(
                    "Official \(edition.shortName) admission schedule",
                    destination: edition.reminderScheduleURL
                )
            }
        }
    }

    /// The time and the milestone side by side, or stacked at accessibility
    /// sizes so the title keeps a usable width next to the toggle.
    @ViewBuilder
    private func reminderLabel(for kind: ComiketReminderKind) -> some View {
        let time = Text(verbatim: kind.timeLabel)
            .font(.rowTitle.monospacedDigit())
            .singleLineToken()
        let title = Text(kind.title)
            .font(.body)
            .wrapsFully()

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                time
                title
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                time
                    .frame(minWidth: timeColumnWidth, alignment: .leading)
                title
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder
    private var reminderStatus: some View {
        switch store.state {
        case .checking, .notDetermined:
            EmptyView()
        case .denied:
            ToolboxReminderWarning(message: Text("Notifications are off for ComiNavi."))
        case .authorized(let timeSensitiveEnabled):
            if !timeSensitiveEnabled {
                ToolboxReminderWarning(
                    message: Text("Time Sensitive delivery is off in Settings; alerts may be delayed.")
                )
            }
        }
    }
}

/// An orange warning line under the reminder toggles, with a Lucide icon like
/// the rest of the Toolbox.
private struct ToolboxReminderWarning: View {
    let message: Text

    var body: some View {
        IconRow(
            icon: "exclamationmark.triangle.fill",
            iconSize: IconSize.caption,
            iconStyle: .orange,
            textStyle: .footnote
        ) {
            message
                .font(.meta)
                .foregroundStyle(.orange)
                .wrapsFully()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ToolboxResourceSectionView: View {
    let section: ComiketToolboxSection

    var body: some View {
        Section {
            ForEach(section.resources) { resource in
                Link(destination: resource.url) {
                    ToolboxResourceRow(resource: resource)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toolbox-resource-\(resource.id)")
            }
        } header: {
            LucideLabel(resource: section.category.title, icon: section.category.icon)
        }
    }
}

/// The selected edition's dated notices, collapsible so the hub links stay close.
private struct ToolboxEditionNotice: View {
    let edition: ComiketToolboxEdition
    @Binding var isExpanded: Bool

    /// 6 pt: off the spacing scale on purpose; a bullet sized to the x-height.
    private static let bulletSize: CGFloat = 6
    /// Half the x-height of `rowSubtitle` text, so the bullet centers on the
    /// lowercase letters of the first line instead of sitting on the baseline.
    @ScaledMetric(relativeTo: .subheadline) private var bulletLift = 3.5

    /// A date such as "Jul 30, 2026" that never splits across two lines.
    private var verifiedDate: String {
        NonBreaking.spaces(edition.verifiedAt.formatted(.dateTime.year().month().day()))
    }

    var body: some View {
        // Read the scaled metric once; alignment guide closures are Sendable.
        let lift = bulletLift
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(edition.notices) { notice in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                            Circle()
                                .fill(.orange)
                                .frame(width: Self.bulletSize, height: Self.bulletSize)
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[VerticalAlignment.center] + lift
                                }
                                .accessibilityHidden(true)
                            Text(notice.text)
                                .font(.rowSubtitle)
                                .foregroundStyle(.secondary)
                                .wrapsFully()
                        }
                    }

                    Text(
                        "Checked against official posts on \(verifiedDate). Check live notices again before you travel."
                    )
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                }
                .accessibilityElement(children: .combine)
            } label: {
                IconRow(icon: "circle-alert", iconStyle: .orange, textStyle: .headline) {
                    Text("\(edition.shortName) notices")
                        .font(.rowTitle)
                        .wrapsFully()
                }
            }
            .accessibilityIdentifier("toolbox-edition-notice")
        }
    }
}

/// Footer of the hub links, shown instead of notices and reminders when no
/// edition matches the selected event or the matching edition has ended.
private struct ToolboxNoEditionNote: View {
    let event: CatalogEvent?

    var body: some View {
        Group {
            if let event {
                Text("Event notices and reminders for \(event.shortName) are not available.")
            } else {
                Text("Event notices and reminders are not available.")
            }
        }
        .font(.meta)
        .foregroundStyle(.secondary)
        .wrapsFully()
        .accessibilityIdentifier("toolbox-no-edition")
    }
}

/// A hub row: a leading icon, a title that wraps, and an optional trailing
/// accessory such as a count. The accessory sits next to the title while the
/// title fits on one line beside it. When it does not (long translations,
/// accessibility sizes), the accessory moves under the title as a `Font.meta`
/// line, so the title gets the full width and never breaks inside a word.
private struct ToolboxHubRow<Accessory: View>: View {
    let title: LocalizedStringResource
    let icon: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        IconRow(icon: icon, textStyle: .body) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    Text(title)
                        .wrapsFully()
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    accessory
                }

                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(title)
                        .wrapsFully()
                    accessory
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension ToolboxHubRow where Accessory == EmptyView {
    init(title: LocalizedStringResource, icon: String) {
        self.init(title: title, icon: icon) { EmptyView() }
    }
}

private struct ToolboxQuickAccess: View {
    @Binding var copiedVenue: Bool
    @Environment(\.appHapticFeedback) private var hapticFeedback

    var body: some View {
        Section("Quick access") {
            Link(destination: ComiketToolboxCatalog.venueMapsURL) {
                ToolboxActionRow(
                    title: "Transit to Tokyo Big Sight",
                    detail: "Public-transit directions in Maps.",
                    icon: "navigation",
                    accessory: .externalLink
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolbox-transit-to-venue")

            Button {
                let venue = String(localized: "Tokyo Big Sight")
                let address = String(localized: "3-11-1 Ariake, Koto City, Tokyo 135-0063")
                UIPasteboard.general.string =
                    "\(venue)\n\(address)\n\(ComiketToolboxCatalog.venueMapsURL.absoluteString)"
                copiedVenue = true
                hapticFeedback?.play(.copyConfirmation)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copiedVenue = false
                }
            } label: {
                ToolboxActionRow(
                    title: copiedVenue ? "Venue copied" : "Copy venue and map link",
                    detail: "Copies the address and a Maps link.",
                    icon: copiedVenue ? "check" : "copy",
                    accessory: .none
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolbox-copy-venue")
        }
    }
}

private struct ToolboxActionRow: View {
    /// What the trailing glyph promises: leaving the app, or nothing for in-place actions.
    enum Accessory {
        case none
        case externalLink
    }

    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let icon: String
    let accessory: Accessory

    var body: some View {
        IconRow(icon: icon, textStyle: .headline) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                ToolboxRowTitle(title: Text(title), opensExternally: accessory == .externalLink)
                Text(detail)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A row title with an optional external-link glyph. The glyph is drawn at
/// the end of the text and wraps with the last word (`TrailingGlyphText`), so
/// it never splits the title or leaves a word alone on the next line.
private struct ToolboxRowTitle: View {
    let title: Text
    let opensExternally: Bool

    var body: some View {
        Group {
            if opensExternally {
                TrailingGlyphText(title, glyph: "external-link")
            } else {
                title
            }
        }
        .font(.rowTitle)
        .foregroundStyle(.primary)
        .wrapsFully()
    }
}

private struct ToolboxChecklistSection: View {
    let store: ComiketChecklistStore

    private var items: [ComiketChecklistItem] {
        ComiketChecklistCatalog.items
    }

    var body: some View {
        Section {
            ForEach(items) { item in
                let isCompleted = store.isCompleted(item)
                Button {
                    store.setCompleted(!isCompleted, for: item)
                } label: {
                    // The check circle leads, like Reminders, and is the only icon, so
                    // titles and details keep the full row width before they wrap.
                    IconRow(
                        icon: isCompleted ? "checkmark.circle.fill" : "circle",
                        iconStyle: isCompleted ? Color.accentColor : Color.secondary,
                        textStyle: .body
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text(item.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .wrapsFully()
                            Text(item.detail)
                                .font(.rowSubtitle)
                                .foregroundStyle(.secondary)
                                .wrapsFully()
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The label already combines the title and detail; the toggle trait
                // and value tell VoiceOver that activating the row checks it off.
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(Text(isCompleted ? "Checked" : "Not checked"))
                .accessibilityIdentifier("toolbox-checklist-\(item.id)")
            }

            if store.completedCount > 0 {
                Button("Reset checklist", role: .destructive) {
                    store.reset()
                }
                .accessibilityIdentifier("toolbox-reset-checklist")
            }
        } header: {
            Text("\(store.completedCount) of \(items.count) done")
                .monospacedDigit()
        } footer: {
            Text(
                "Your checklist is a reminder, not a replacement for official instructions."
            )
        }
    }
}

private struct ToolboxResourceRow: View {
    let resource: ComiketToolboxResource

    var body: some View {
        IconRow(icon: resource.icon, textStyle: .headline) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                ToolboxRowTitle(title: Text(resource.title), opensExternally: true)

                Text(resource.summary)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .wrapsFully()

                Text(resource.authority.label)
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                    .padding(.top, Spacing.xxSmall)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens in browser")
    }
}

#Preview {
    // The Toolbox is pushed inside the Profile stack, so it owns no stack itself.
    NavigationStack {
        ComiketToolboxView()
    }
}

private extension View {
    /// The always-visible search drawer is a glass capsule on iOS 26. With
    /// the soft edge effect, row titles scrolled under it stayed sharp
    /// enough to collide with the prompt at accessibility sizes. The hard
    /// edge puts an opaque band behind the bar and the drawer.
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

#if DEBUG
/// UI-test launch routes for screenshots. Profile pushes the Toolbox for
/// `-cominavi-ui-testing-open-checklist` and
/// `-cominavi-ui-testing-open-official-links`; this modifier then pushes the
/// child screen once per process, so a pop does not push it again.
private struct ToolboxLaunchRouteModifier: ViewModifier {
    enum Child: Hashable {
        case checklist
        case officialLinks
    }

    @MainActor private static var hasHandledLaunchRoute = false

    let checklistStore: ComiketChecklistStore
    let sections: [ComiketToolboxSection]
    @State private var child: Child?

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $child) { child in
                switch child {
                case .checklist:
                    ToolboxChecklistScreen(store: checklistStore)
                case .officialLinks:
                    ToolboxResourcesScreen(sections: sections)
                }
            }
            .task {
                guard !Self.hasHandledLaunchRoute else { return }
                Self.hasHandledLaunchRoute = true
                let arguments = ProcessInfo.processInfo.arguments
                let route: Child? = if arguments.contains("-cominavi-ui-testing-open-checklist") {
                    .checklist
                } else if arguments.contains("-cominavi-ui-testing-open-official-links") {
                    .officialLinks
                } else {
                    nil
                }
                guard let route else { return }
                // A push inside the push transition of the Toolbox itself is
                // dropped, so wait for that transition to end.
                try? await Task.sleep(for: .milliseconds(600))
                child = route
            }
    }
}
#endif
