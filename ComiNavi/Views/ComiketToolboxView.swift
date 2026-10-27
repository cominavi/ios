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
                } else {
                    ToolboxNoEditionNotice(event: event)
                }

                Section {
                    NavigationLink {
                        ToolboxChecklistScreen(store: checklistStore)
                    } label: {
                        LabeledContent {
                            Text(
                                verbatim:
                                    "\(checklistStore.completedCount)/\(ComiketChecklistCatalog.items.count)"
                            )
                            .monospacedDigit()
                        } label: {
                            LucideLabel(resource: "Day-of checklist", icon: "list-checks")
                        }
                    }
                    .accessibilityIdentifier("toolbox-open-checklist")

                    if let edition, showsReminders {
                        NavigationLink {
                            ToolboxReminderScreen(store: reminderStore, edition: edition)
                        } label: {
                            LucideLabel(resource: "Event reminders", icon: "calendar-clock")
                        }
                        .accessibilityIdentifier("toolbox-open-reminders")
                    }

                    NavigationLink {
                        ToolboxResourcesScreen(
                            sections: ComiketToolboxCatalog.sections(for: edition)
                        )
                    } label: {
                        LucideLabel(resource: "Official links", icon: "globe")
                    }
                    .accessibilityIdentifier("toolbox-open-official-links")
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
        .modifier(ToolboxReadableWidth())
        .navigationTitle("Toolbox")
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

/// Keeps grouped lists at `ReadableWidth.content` in regular width instead of
/// stretching rows across the whole iPad screen. A `List` needs content margins
/// rather than `.readableWidth()`, so its scroll area still spans the screen.
private struct ToolboxReadableWidth: ViewModifier {
    private static let maxContentWidth: CGFloat = ReadableWidth.content
    private static let minimumMargin: CGFloat = Spacing.screenGutter

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var containerWidth: CGFloat = 0

    private var horizontalMargin: CGFloat? {
        guard horizontalSizeClass == .regular else { return nil }
        return max(Self.minimumMargin, (containerWidth - Self.maxContentWidth) / 2)
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
    }
}

private struct ToolboxChecklistScreen: View {
    let store: ComiketChecklistStore

    var body: some View {
        List {
            ToolboxChecklistSection(store: store)
        }
        .modifier(ToolboxReadableWidth())
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
        .modifier(ToolboxReadableWidth())
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
        .modifier(ToolboxReadableWidth())
        .navigationTitle("Official links")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolboxReminderSection: View {
    let store: ComiketReminderStore
    let edition: ComiketToolboxEdition
    /// Grows with Dynamic Type so the times stay aligned without clipping.
    @ScaledMetric(relativeTo: .body) private var timeColumnWidth = 50.0

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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    LucideIcon("calendar-clock", size: 20)
                        .foregroundStyle(.orange)
                    Text("\(edition.shortName) event reminders")
                        .font(.headline)
                }

                Text("Get a Time Sensitive alert 15 minutes before each selected time, on both event days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
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
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: kind.timeLabel)
                                .font(.body.monospacedDigit().weight(.semibold))
                                .frame(minWidth: timeColumnWidth, alignment: .leading)

                            Text(kind.title)
                                .font(.body)
                        }
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
                    .accessibilityIdentifier("toolbox-reminders-ended")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
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

    @ViewBuilder
    private var reminderStatus: some View {
        switch store.state {
        case .checking, .notDetermined:
            EmptyView()
        case .denied:
            Label("Notifications are off for ComiNavi.", systemImage: "bell.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case .authorized(let timeSensitiveEnabled):
            if !timeSensitiveEnabled {
                Label(
                    "Time Sensitive delivery is off in Settings; alerts may be delayed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
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

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(edition.notices) { notice in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(notice.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(
                        "Checked against official posts on \(edition.verifiedAt, format: .dateTime.year().month().day()). Check live notices again before you travel."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } label: {
                HStack(spacing: 10) {
                    LucideIcon("circle-alert", size: 20)
                        .foregroundStyle(.orange)
                    Text("\(edition.shortName) notices")
                        .font(.headline)
                }
            }
            .accessibilityIdentifier("toolbox-edition-notice")
        }
    }
}

/// Shown instead of notices and reminders when no edition matches the selected
/// event or the matching edition has ended.
private struct ToolboxNoEditionNotice: View {
    let event: CatalogEvent?

    var body: some View {
        Section {
            Label {
                if let event {
                    Text("Event notices and reminders for \(event.shortName) are not available.")
                } else {
                    Text("Event notices and reminders are not available.")
                }
            } icon: {
                LucideIcon("info", size: 18)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("toolbox-no-edition")
        }
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
                    detail: "Open current public-transit directions in Maps.",
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
                    detail: "Copies the address and an Apple Maps link.",
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
        HStack(spacing: 13) {
            LucideIcon(icon, size: 20)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if accessory == .externalLink {
                LucideIcon("external-link", size: 14)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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
                    HStack(alignment: .top, spacing: 12) {
                        LucideIcon(item.icon, size: 18)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.body)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        LucideIcon(
                            isCompleted ? "checkmark.circle.fill" : "circle",
                            size: 22
                        )
                        .foregroundStyle(isCompleted ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
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
        HStack(alignment: .top, spacing: 13) {
            LucideIcon(resource.icon, size: 19)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(resource.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text(resource.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(resource.authority.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            LucideIcon("external-link", size: 14)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, 3)
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
