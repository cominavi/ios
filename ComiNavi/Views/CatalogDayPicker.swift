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

struct CatalogEventDayBanner: View {
    let event: CatalogEvent?
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var minimumHeight = 54.0

    private var selectedDate: Date? {
        guard let day = days.first(where: { $0.dayIndex == selectedDay }) else { return nil }
        return Calendar.current.date(from: day.date)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                LucideIcon("calendar.badge.clock")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let selectedDate {
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

                LucideIcon("chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: horizontalSizeClass == .regular ? 280 : .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Change event day or Comiket")
        .accessibilityIdentifier("global-event-day-banner")
    }

    private var primaryLabel: String {
        let eventName = event?.shortName ?? String(localized: "Comiket")
        return "\(eventName) · \(String(localized: "Day \(selectedDay)"))"
    }

    private var accessibilityLabel: String {
        let eventName = event?.displayName ?? String(localized: "Comiket")
        guard let selectedDate else {
            return "\(eventName), \(String(localized: "Day \(selectedDay)"))"
        }
        let date = selectedDate.formatted(CatalogDateFormatting.full(for: selectedDate))
        return "\(eventName), \(String(localized: "Day \(selectedDay)")), \(date)"
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
                    sheetSummary
                    daySection
                    eventNavigationSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Day & Comiket")
            .navigationBarTitleDisplayMode(.large)
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

    private var sheetSummary: some View {
        HStack(spacing: 14) {
            LucideIcon("calendar.badge.clock")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Day \(selectedDay)")
                    .font(.headline)
                Text(activeEvent?.displayName ?? String(localized: "Comiket"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
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
                    LucideIcon("externaldrive")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeEvent?.shortName ?? String(localized: "Comiket"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Choose another catalog")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    LucideIcon("chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
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
            .accessibilityHint("Choose another catalog")
            .accessibilityIdentifier("catalog-event-selection-link")
        }
    }

    @ViewBuilder
    private var daySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event day")
                .font(.headline)

            if isOpeningCatalog || availableDays.isEmpty {
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
                        selectedDay = day.dayIndex
                    }
                    .accessibilityIdentifier("global-day-\(day.dayIndex)")
                }
            }
        }
    }

    private var activeEvent: CatalogEvent? {
        if case .loading(let event) = catalogLibrary.phase {
            return event
        }
        return catalogLibrary.selectedEvent
    }

    private var isOpeningCatalog: Bool {
        if case .loading = catalogLibrary.phase { return true }
        guard let dataSource = catalogLibrary.dataSource else { return true }
        return dataSource.readiness != .ready
    }

    private var availableDays: [UFDSchema.Day] {
        guard !isOpeningCatalog,
              let dataSource = catalogLibrary.dataSource,
              let comiket = dataSource.comiket
        else { return [] }
        return comiket.days
    }

    private var availableDayIDs: [Int] {
        availableDays.map(\.dayIndex)
    }

    private var openingLabel: String {
        if let activeEvent {
            return String(localized: "Opening \(activeEvent.shortName)…")
        }
        return String(localized: "Opening catalog…")
    }

    private func formattedDate(_ day: UFDSchema.Day) -> String? {
        guard let date = Calendar.current.date(from: day.date) else { return nil }
        return date.formatted(CatalogDateFormatting.full(for: date))
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
                ForEach(catalogLibrary.events) { event in
                    let dateDescription = dateDescription(for: event)
                    CatalogSettingRow(
                        title: event.shortName,
                        detail: dateDescription ?? event.displayName,
                        systemImage: "externaldrive",
                        isSelected: event == activeEvent,
                        minimumHeight: rowHeight
                    ) {
                        catalogLibrary.select(event)
                    }
                    .disabled(isOpeningCatalog)
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
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("catalog-event-selection-page")
    }

    private var activeEvent: CatalogEvent? {
        if case .loading(let event) = catalogLibrary.phase {
            return event
        }
        return catalogLibrary.selectedEvent
    }

    private var isOpeningCatalog: Bool {
        if case .loading = catalogLibrary.phase { return true }
        return catalogLibrary.isSwitching
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
    let minimumHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LucideIcon(systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 30)
                    .accessibilityHidden(true)

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

                if isSelected {
                    LucideIcon("checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
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
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
