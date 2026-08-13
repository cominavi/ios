import SwiftUI
import UIKit

struct ComiketToolboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var checklistStore: ComiketChecklistStore
    @State private var reminderStore: ComiketReminderStore
    @State private var searchText = ""
    @State private var copiedVenue = false

    @MainActor
    init(
        checklistStore: ComiketChecklistStore = ComiketChecklistStore(),
        reminderStore: ComiketReminderStore = ComiketReminderStore()
    ) {
        _checklistStore = State(initialValue: checklistStore)
        _reminderStore = State(initialValue: reminderStore)
    }

    private var visibleSections: [ComiketToolboxSection] {
        ComiketToolboxCatalog.sections(matching: searchText)
    }

    private var liveSection: ComiketToolboxSection? {
        visibleSections.first { $0.category == .live }
    }

    private var nonLiveSections: [ComiketToolboxSection] {
        visibleSections.filter { $0.category != .live }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    C108ToolboxNotice()
                    ToolboxReminderSection(store: reminderStore)
                    ToolboxQuickAccess(copiedVenue: $copiedVenue)
                    if let liveSection {
                        ToolboxResourceSectionView(section: liveSection)
                    }
                    ToolboxChecklistSection(store: checklistStore)
                    ForEach(nonLiveSections) { section in
                        ToolboxResourceSectionView(section: section)
                    }
                } else {
                    ForEach(visibleSections) { section in
                        ToolboxResourceSectionView(section: section)
                    }
                }
            }
            .overlay {
                if !searchText.isEmpty, visibleSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("Toolbox")
            .searchable(text: $searchText, prompt: "Search official resources")
        }
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

private struct ToolboxReminderSection: View {
    let store: ComiketReminderStore

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
                    Text("C108 event reminders")
                        .font(.headline)
                    Spacer()
                    Text("Local only")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: .capsule)
                }

                Text("Get a Time Sensitive alert 15 minutes before selected milestones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)

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
                            .frame(width: 50, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.body)
                            Text("Both days · 15 min before")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "Your choices are saved. Delivery still follows your iOS notification settings."
                )
                Link("Official C108 admission schedule", destination: ComiketEventReminderCatalog.officialScheduleURL)
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

private struct C108ToolboxNotice: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LucideIcon("circle-alert", size: 20)
                        .foregroundStyle(.orange)
                    Text("C108 right now")
                        .font(.headline)
                }

                ForEach(C108ToolboxNoticeCatalog.notices) { notice in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                        Text(notice.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Checked against official posts through August 13. Always recheck live notices before travel."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
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
                    icon: "navigation"
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
                    detail: "Share a destination without claiming an indoor route.",
                    icon: copiedVenue ? "check" : "copy"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolbox-copy-venue")
        }
    }
}

private struct ToolboxActionRow: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let icon: String

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

            LucideIcon("chevron-right", size: 15)
                .foregroundStyle(.tertiary)
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

    private var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(store.completedCount) / Double(items.count)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Day-of checklist")
                        .font(.headline)
                    Spacer()
                    Text(verbatim: "\(store.completedCount)/\(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress)
                    .tint(progress == 1 ? .green : Color.accentColor)
                    .accessibilityLabel("Checklist progress")
                    .accessibilityValue(
                        Text(verbatim: "\(store.completedCount)/\(items.count)")
                    )
            }
            .padding(.vertical, 3)

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
                .accessibilityLabel(item.title)
                .accessibilityValue(Text(isCompleted ? "Selected" : "Not selected"))
                .accessibilityAddTraits(isCompleted ? .isSelected : [])
                .accessibilityIdentifier("toolbox-checklist-\(item.id)")
            }

            if store.completedCount > 0 {
                Button("Reset checklist", role: .destructive) {
                    store.reset()
                }
                .accessibilityIdentifier("toolbox-reset-checklist")
            }
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
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            LucideIcon("external-link", size: 14)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the official website")
    }
}

#Preview {
    ComiketToolboxView()
}
