import SwiftUI

enum CatalogDateFormatting {
    static func abbreviated(
        for date: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Date.FormatStyle {
        addingYearWhenNeeded(
            to: .dateTime.weekday(.abbreviated).month(.abbreviated).day(),
            date: date,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    static func full(
        for date: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Date.FormatStyle {
        addingYearWhenNeeded(
            to: .dateTime.weekday(.wide).month(.wide).day(),
            date: date,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    static func eventRange(
        from startDate: Date,
        through endDate: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard startDate != endDate else {
            return startDate.formatted(
                abbreviated(
                    for: startDate,
                    relativeTo: referenceDate,
                    calendar: calendar
                ).locale(locale)
            )
        }

        var format = Date.IntervalFormatStyle(
            locale: locale,
            calendar: calendar
        )
        .weekday(.abbreviated)
        .month(.abbreviated)
        .day()

        if !calendar.isDate(startDate, equalTo: referenceDate, toGranularity: .year)
            || !calendar.isDate(endDate, equalTo: referenceDate, toGranularity: .year)
        {
            format = format.year()
        }

        return (startDate..<endDate).formatted(format)
    }

    private static func addingYearWhenNeeded(
        to format: Date.FormatStyle,
        date: Date,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date.FormatStyle {
        guard !calendar.isDate(date, equalTo: referenceDate, toGranularity: .year) else {
            return format
        }
        return format.year()
    }
}

/// A short status shown beside the event name, so nobody mistakes an old or
/// demo catalog for the upcoming Comiket.
enum CatalogEventStatus: Hashable, Identifiable {
    case past
    case demo

    var id: Self { self }

    var title: String {
        switch self {
        case .past: String(localized: "Past event")
        case .demo: String(localized: "Demo")
        }
    }
}

/// What every day control says about the active catalog: which Comiket and
/// day are open, the date, and whether the data is past or demo data.
struct CatalogEventDaySummary {
    let event: CatalogEvent?
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let isDemo: Bool
    var referenceDate: Date = .now
    var calendar: Calendar = .current

    /// "C104 · Day 1", or "Day 1" before the event is known.
    var title: String {
        guard let event else { return String(localized: "Day \(selectedDay)") }
        return String(localized: "\(event.shortName) · Day \(selectedDay)")
    }

    var selectedDate: Date? {
        guard let day = days.first(where: { $0.dayIndex == selectedDay }) else { return nil }
        return calendar.date(from: day.date)
    }

    /// Past comes before Demo, so the compact fallback (the last status)
    /// keeps the demo warning, which also implies old data.
    var statuses: [CatalogEventStatus] {
        var statuses: [CatalogEventStatus] = []
        if isPastEvent { statuses.append(.past) }
        if isDemo { statuses.append(.demo) }
        return statuses
    }

    var accessibilityLabel: String {
        var parts = [
            event?.displayName ?? String(localized: "Comiket"),
            String(localized: "Day \(selectedDay)"),
        ]
        if let selectedDate {
            parts.append(
                selectedDate.formatted(
                    CatalogDateFormatting.full(for: selectedDate, relativeTo: referenceDate)
                )
            )
        }
        parts += statuses.map(\.title)
        return parts.joined(separator: ", ")
    }

    private var isPastEvent: Bool {
        guard let lastDate = days.compactMap({ calendar.date(from: $0.date) }).max() else {
            return false
        }
        return lastDate < calendar.startOfDay(for: referenceDate)
    }
}

/// The event and day title with its status capsules. Narrow containers drop
/// the capsules before they truncate the title.
private struct CatalogEventDayTitle: View {
    let summary: CatalogEventDaySummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(summary.statuses)
            row(Array(summary.statuses.suffix(1)))
            row([])
        }
    }

    private func row(_ statuses: [CatalogEventStatus]) -> some View {
        HStack(spacing: 6) {
            Text(summary.title)
                .lineLimit(1)

            ForEach(statuses) { status in
                CatalogEventStatusBadge(status: status)
            }
        }
    }
}

private struct CatalogEventStatusBadge: View {
    let status: CatalogEventStatus

    var body: some View {
        StatusBadge(Text(status.title))
    }
}

struct CatalogEventDayBanner: View {
    enum Style: Equatable {
        /// A two-line card with the date, for wide layouts.
        case card
        /// A one-line capsule that matches the Explore toolbar control.
        case compact
        /// A tighter capsule with no chevron that shares one row with the
        /// map selectors. It shows at most `statusLimit` status capsules;
        /// the full statuses stay in the accessibility label.
        case inline(statusLimit: Int)
    }

    let event: CatalogEvent?
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let isDemo: Bool
    var style: Style = .card
    let action: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var minimumHeight = 54.0

    private var adaptiveMinimumHeight: CGFloat {
        verticalSizeClass == .compact || style != .card ? 44 : minimumHeight
    }

    private var summary: CatalogEventDaySummary {
        CatalogEventDaySummary(
            event: event,
            days: days,
            selectedDay: selectedDay,
            isDemo: isDemo
        )
    }

    var body: some View {
        Button(action: action) {
            switch style {
            case .card: cardLabel
            case .compact: compactLabel
            case .inline(let statusLimit): inlineLabel(statusLimit: statusLimit)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Change event day or Comiket")
        .accessibilityIdentifier("global-event-day-banner")
    }

    private var cardLabel: some View {
        HStack(spacing: 11) {
            LucideIcon("calendar.badge.clock")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 1) {
                CatalogEventDayTitle(summary: summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let selectedDate = summary.selectedDate {
                    Text(
                        selectedDate,
                        format: CatalogDateFormatting.abbreviated(for: selectedDate)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            LucideIcon("chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: 340, minHeight: adaptiveMinimumHeight, alignment: .leading)
        .contentShape(.rect)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }

    private var compactLabel: some View {
        HStack(spacing: 8) {
            LucideIcon("calendar.badge.clock")
                .foregroundStyle(Color.accentColor)

            CatalogEventDayTitle(summary: summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            LucideIcon("chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: adaptiveMinimumHeight)
        .contentShape(.capsule)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }
}

extension CatalogEventDayBanner {
    /// The same banner in another style, for layouts that pick a style
    /// after the caller built the banner.
    func style(_ style: Style) -> CatalogEventDayBanner {
        var copy = self
        copy.style = style
        return copy
    }

    fileprivate func inlineLabel(statusLimit: Int) -> some View {
        HStack(spacing: 6) {
            LucideIcon("calendar.badge.clock")
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 6) {
                Text(summary.title)
                    .lineLimit(1)

                ForEach(summary.statuses.suffix(statusLimit)) { status in
                    CatalogEventStatusBadge(status: status)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .contentShape(.capsule)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct CatalogEventDayToolbarButton: View {
    let event: CatalogEvent?
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let isDemo: Bool
    let action: () -> Void

    private var summary: CatalogEventDaySummary {
        CatalogEventDaySummary(
            event: event,
            days: days,
            selectedDay: selectedDay,
            isDemo: isDemo
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideIcon("calendar.badge.clock")

                CatalogEventDayTitle(summary: summary)
                    .minimumScaleFactor(0.85)
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Change event day or Comiket")
        .accessibilityIdentifier("global-event-day-toolbar-button")
    }
}

struct CatalogEventDaySheet: View {
    let catalogLibrary: CatalogLibrary
    @Binding var selectedDay: Int

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var eventRowHeight = 72.0
    @ScaledMetric(relativeTo: .body) private var dayRowHeight = 64.0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    daySection
                    eventNavigationSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Day & Comiket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("catalog-settings-done")
                }
            }
        }
        .accessibilityIdentifier("catalog-event-day-sheet")
        .onChange(of: availableDayIDs, initial: true) {
            guard let firstDay = availableDays.first,
                  !availableDayIDs.contains(selectedDay)
            else { return }

            selectedDay = firstDay.dayIndex
        }
    }

    private var eventNavigationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comiket")
                .font(.headline)

            NavigationLink {
                CatalogEventSelectionView(catalogLibrary: catalogLibrary)
            } label: {
                HStack(spacing: 14) {
                    LucideIcon("calendar.badge.clock")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        // The open catalog, not the one that is loading: the
                        // days above still belong to it until the switch ends.
                        Text(catalogLibrary.selectedEvent?.shortName ?? String(localized: "Comiket"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Choose another Comiket")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    LucideIcon("chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: eventRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
            }
            .accessibilityHint("Choose another Comiket")
            .accessibilityIdentifier("catalog-event-selection-link")

            CatalogSwitchProgress(catalogLibrary: catalogLibrary)
        }
    }

    @ViewBuilder
    private var daySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event day")
                .font(.headline)

            if availableDays.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(openingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: dayRowHeight, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            } else {
                ForEach(availableDays) { day in
                    CatalogSettingRow(
                        title: String(localized: "Day \(day.dayIndex)"),
                        detail: formattedDate(day),
                        systemImage: "calendar",
                        isSelected: day.dayIndex == selectedDay,
                        minimumHeight: dayRowHeight
                    ) {
                        // A day is a single choice, so picking one is the
                        // whole task: close the sheet instead of asking for Done.
                        selectedDay = day.dayIndex
                        dismiss()
                    }
                    .accessibilityIdentifier("global-day-\(day.dayIndex)")
                }
            }
        }
    }

    private var availableDays: [UFDSchema.Day] {
        guard let dataSource = catalogLibrary.dataSource,
              dataSource.readiness == .ready,
              let comiket = dataSource.comiket
        else { return [] }
        return comiket.days
    }

    private var availableDayIDs: [Int] {
        availableDays.map(\.dayIndex)
    }

    private var openingLabel: String {
        if let event = catalogLibrary.switchTarget ?? catalogLibrary.selectedEvent {
            return String(localized: "Opening \(event.shortName)…")
        }
        return String(localized: "Opening catalog…")
    }

    private func formattedDate(_ day: UFDSchema.Day) -> String? {
        guard let date = Calendar.current.date(from: day.date) else { return nil }
        return date.formatted(CatalogDateFormatting.full(for: date))
    }
}

/// Progress for a switch to another Comiket, with a way to keep the open
/// one. A full catalog download can be hundreds of megabytes.
private struct CatalogSwitchProgress: View {
    let catalogLibrary: CatalogLibrary

    var body: some View {
        if let event = catalogLibrary.switchTarget {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if fractionCompleted == nil {
                        ProgressView()
                    }

                    Text(statusText(for: event))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Spacer(minLength: 8)

                    Button("Cancel", role: .cancel) {
                        catalogLibrary.cancelPendingLoad()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(
                        Text("Stops the switch and keeps \(catalogLibrary.selectedEvent?.shortName ?? "") open.")
                    )
                    .accessibilityIdentifier("catalog-switch-cancel")
                }

                if let fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .tint(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 14)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("catalog-switch-progress")
        }
    }

    private var fractionCompleted: Double? {
        guard case .downloading(_, let progress) = catalogLibrary.phase else { return nil }
        return progress.fractionCompleted
    }

    private func statusText(for event: CatalogEvent) -> String {
        guard let fractionCompleted else {
            return String(localized: "Switching to \(event.shortName)…")
        }
        let percent = fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Switching to \(event.shortName)… \(percent)")
    }
}

private struct CatalogEventSelectionView: View {
    let catalogLibrary: CatalogLibrary

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                CatalogSwitchProgress(catalogLibrary: catalogLibrary)

                ForEach(catalogLibrary.events) { event in
                    let dateDescription = dateDescription(for: event)
                    CatalogSettingRow(
                        title: event.shortName,
                        detail: dateDescription ?? event.displayName,
                        systemImage: "calendar.badge.clock",
                        isSelected: event == catalogLibrary.selectedEvent,
                        isLoading: event == catalogLibrary.switchTarget,
                        minimumHeight: rowHeight
                    ) {
                        // Picking the open Comiket again during a switch
                        // means "stay here".
                        if event == catalogLibrary.selectedEvent {
                            catalogLibrary.cancelPendingLoad()
                        } else {
                            catalogLibrary.select(event)
                        }
                    }
                    .accessibilityLabel(
                        [event.displayName, dateDescription]
                            .compactMap { $0 }
                            .joined(separator: ", ")
                    )
                    .accessibilityIdentifier("catalog-event-\(event.id)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Comiket")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("catalog-event-selection-page")
    }

    private func dateDescription(for event: CatalogEvent) -> String? {
        guard let dates = event.scheduledDateRange?.dates(in: calendar) else { return nil }
        return CatalogDateFormatting.eventRange(
            from: dates.start,
            through: dates.end,
            calendar: calendar,
            locale: locale
        )
    }
}

private struct CatalogSettingRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    let isSelected: Bool
    var isLoading = false
    let minimumHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LucideIcon(systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                } else if isSelected {
                    LucideIcon("checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.45) : Color(uiColor: .separator).opacity(0.25),
                    lineWidth: isSelected ? 1 : 0.5
                )
        }
        // The trait alone announces "Selected"; a value would repeat it.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
