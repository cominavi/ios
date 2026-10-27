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

    /// The short month and day ("Aug 11", "8月11日") that every event day
    /// control shows after the day number.
    static let monthDay: Date.FormatStyle = .dateTime.month(.abbreviated).day()

    /// `formatted` with its month-and-day part made unbreakable, so a wrapped
    /// date never splits "August 12" across two lines. The weekday and the
    /// year can still move to the next line.
    static func protectingMonthDay(
        in formatted: String,
        of date: Date,
        month: Date.FormatStyle.Symbol.Month
    ) -> String {
        let monthDay = date.formatted(.dateTime.month(month).day())
        guard formatted.contains(monthDay) else { return formatted }
        return formatted.replacingOccurrences(of: monthDay, with: NonBreaking.unit(monthDay))
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

    /// Demo data is a warning; a past event is only a fact.
    var tone: StatusBadge.Tone {
        switch self {
        case .past: .neutral
        case .demo: .warning
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

    /// "C104 · Day 1 · Aug 11", or "Day 1 · Aug 11" before the event is known.
    var title: String { title(includingDate: true) }

    /// The event context as units joined by " · ". Each unit is unbreakable,
    /// and the separators keep ordinary spaces, so a line can break only
    /// between units.
    func title(includingDate: Bool) -> String {
        var units: [String] = []
        if let event { units.append(event.shortName) }
        units.append(String(localized: "Day \(selectedDay)"))
        if includingDate, let selectedDate {
            units.append(selectedDate.formatted(CatalogDateFormatting.monthDay))
        }
        return units.map(NonBreaking.unit).joined(separator: " · ")
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

/// One line of event context: the title and at most `statusLimit` status
/// capsules. The title truncates before a capsule does, because the capsule
/// is the warning that the data is old or fake.
private struct CatalogEventDayTitleRow: View {
    let summary: CatalogEventDaySummary
    let includesDate: Bool
    let statusLimit: Int

    var body: some View {
        HStack(spacing: Spacing.small) {
            Text(verbatim: summary.title(includingDate: includesDate))
                .font(.control)
                .foregroundStyle(.primary)
                .lineLimit(1)

            ForEach(summary.statuses.suffix(statusLimit)) { status in
                StatusBadge(Text(status.title), tone: status.tone)
            }
        }
    }
}

/// The title line of the two-line card, which shows the date on its second
/// line. It drops the Past capsule first, and only at the end the Demo
/// capsule.
private struct CatalogEventDayFittingTitle: View {
    let summary: CatalogEventDaySummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(statusLimit: 2)
            row(statusLimit: 1)
            row(statusLimit: 0)
        }
    }

    private func row(statusLimit: Int) -> CatalogEventDayTitleRow {
        CatalogEventDayTitleRow(summary: summary, includesDate: false, statusLimit: statusLimit)
    }
}

/// The one-line day capsule that fits the width it gets. The map pill and
/// the Explore toolbar both use it, so both show one content set and drop
/// parts by one rule: the date first, then the Past capsule, then the
/// calendar icon, and only at the end the Demo capsule. The full content
/// stays in the accessibility label.
private struct CatalogEventDayFittingCapsule: View {
    let summary: CatalogEventDaySummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsule(showsIcon: true, includesDate: true, statusLimit: 2)
            capsule(showsIcon: true, includesDate: false, statusLimit: 2)
            capsule(showsIcon: true, includesDate: false, statusLimit: 1)
            capsule(showsIcon: false, includesDate: false, statusLimit: 1)
            capsule(showsIcon: false, includesDate: false, statusLimit: 0)
        }
    }

    private func capsule(
        showsIcon: Bool,
        includesDate: Bool,
        statusLimit: Int
    ) -> some View {
        CatalogEventDayCapsule(showsIcon: showsIcon) {
            CatalogEventDayTitleRow(
                summary: summary,
                includesDate: includesDate,
                statusLimit: statusLimit
            )
        }
    }
}

/// Proposes at most `maxWidth` to its one subview. A principal toolbar item
/// proposes no width, so a `ViewThatFits` in it always picked its widest
/// candidate; this layout gives it the width that the bar really has.
private struct WidthCapLayout: Layout {
    /// Nil before the width is known: the proposal passes through.
    let maxWidth: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(cappedProposal(proposal))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func cappedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let maxWidth else { return proposal }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return ProposedViewSize(width: max(0, width), height: proposal.height)
    }
}

/// The one capsule that every one-line day control uses: calendar icon,
/// event context, and a chevron that says "this opens a picker".
private struct CatalogEventDayCapsule<Title: View>: View {
    var showsIcon = true
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: Spacing.medium) {
            if showsIcon {
                LucideIcon("calendar.badge.clock", size: IconSize.inline)
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: Spacing.small) {
                title
                    .layoutPriority(1)

                LucideIcon("chevron.down", size: IconSize.chipAccessory)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .frame(minHeight: HitArea.minimum)
        .contentShape(.capsule)
        .floatingCapsule()
    }
}

private extension View {
    /// Gives a sheet's scroll view the ideal height of its content.
    ///
    /// A `ScrollView` has an ideal height near zero, so a sheet sized with
    /// `.presentationSizing(.form.fitted(horizontal: false, vertical: true))`
    /// collapsed to its title bar on iPad. With the measured content height as
    /// the ideal height, the form sheet grows to show every row; the system
    /// caps it at the screen height, and the rows then scroll. A sheet with
    /// detents (iPhone) proposes a height, so the ideal height has no effect.
    func fittingSheetHeight(_ contentHeight: CGFloat?) -> some View {
        frame(idealHeight: contentHeight)
            .scrollBounceBehavior(.basedOnSize)
    }

    /// `.surface(.floating)` in a capsule shape, for one-line map chrome.
    @ViewBuilder
    func floatingCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay { Capsule().strokeBorder(Color.hairline, lineWidth: 0.5) }
        }
    }
}

struct CatalogEventDayBanner: View {
    enum Style: Equatable {
        /// A two-line floating card with the date, for wide layouts.
        case card
        /// The day capsule at the width its container offers. It drops the
        /// date and the status capsules one at a time before it truncates.
        case compact
        /// The day capsule at its ideal width, for a row that it shares with
        /// the map selectors. It shows at most `statusLimit` status capsules;
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
    // 54 pt: the 30 pt icon tile plus a 12 pt inset above and below it.
    @ScaledMetric(relativeTo: .subheadline) private var cardMinimumHeight = 54.0
    // 30 pt: the icon tile; it scales with the text beside it.
    @ScaledMetric(relativeTo: .subheadline) private var iconTileSize = 30.0

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
            case .card:
                cardLabel
            case .compact:
                CatalogEventDayFittingCapsule(summary: summary)
            case .inline(let statusLimit):
                CatalogEventDayCapsule {
                    CatalogEventDayTitleRow(
                        summary: summary,
                        includesDate: true,
                        statusLimit: statusLimit
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Change event day or Comiket")
        .accessibilityIdentifier("global-event-day-banner")
    }

    private var cardLabel: some View {
        HStack(spacing: Spacing.medium) {
            LucideIcon("calendar.badge.clock", size: IconSize.inline)
                .foregroundStyle(Color.accentColor)
                .frame(width: iconTileSize, height: iconTileSize)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: .rect(
                        cornerRadius: Radius.concentric(outer: Radius.panel, inset: Spacing.medium),
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                // The second line shows the date with its weekday, so the
                // title line leaves it out.
                CatalogEventDayFittingTitle(summary: summary)

                if let selectedDate = summary.selectedDate {
                    Text(
                        selectedDate,
                        format: CatalogDateFormatting.abbreviated(for: selectedDate)
                    )
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            LucideIcon("chevron.down", size: IconSize.chipAccessory)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        // The card fills the map control column, so its trailing edge lines
        // up with the search field and the selectors below it.
        .frame(
            maxWidth: .infinity,
            minHeight: verticalSizeClass == .compact ? HitArea.minimum : cardMinimumHeight,
            alignment: .leading
        )
        .contentShape(.rect(cornerRadius: Radius.panel, style: .continuous))
        .surface(.floating, padding: 0)
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
}

/// The day control in the Explore navigation bar. It uses the map capsule
/// and its fitting rule, so both tabs show one control with one content set.
///
/// A principal toolbar item gets no width limit, so the caller passes the
/// width of the Explore column, and the control fits its content to the part
/// of the bar that the trailing toolbar buttons leave free.
struct CatalogEventDayToolbarButton: View {
    let event: CatalogEvent?
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let isDemo: Bool
    /// The width of the Explore column, or nil before it is measured.
    var columnWidth: CGFloat? = nil
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
            CatalogEventDayToolbarLabel(summary: summary, columnWidth: columnWidth)
        }
        // Navigation bar chrome: like the system bar title, the capsule
        // stops growing at XXXL, so "C104 · Day 1" fits between the toolbar
        // buttons at accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .buttonStyle(.plain)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Change event day or Comiket")
        .accessibilityIdentifier("global-event-day-toolbar-button")
    }
}

/// The toolbar capsule inside the XXXL cap, so its scaled metric stops
/// growing with the capsule text.
private struct CatalogEventDayToolbarLabel: View {
    let summary: CatalogEventDaySummary
    let columnWidth: CGFloat?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // 112 pt: the trailing filter and view-option buttons in one glass group
    // (about 100 pt) plus the gap to the title item; the glyphs scale with
    // the text.
    @ScaledMetric(relativeTo: .body) private var trailingToolbarWidth = 112.0

    /// iPhone puts the capsule in one row with the trailing buttons. iPad
    /// gives the principal item its own centered row below the tab bar.
    private var maxWidth: CGFloat? {
        guard let columnWidth, columnWidth > 0 else { return nil }
        let margins = 2 * Spacing.large
        if horizontalSizeClass == .regular {
            return columnWidth - margins
        }
        return columnWidth - margins - trailingToolbarWidth
    }

    var body: some View {
        WidthCapLayout(maxWidth: maxWidth) {
            CatalogEventDayFittingCapsule(summary: summary)
        }
    }
}

struct CatalogEventDaySheet: View {
    let catalogLibrary: CatalogLibrary
    @Binding var selectedDay: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // 72 and 64 pt: two-line rows with a 12 pt inset; they scale with the text.
    @ScaledMetric(relativeTo: .body) private var eventRowHeight = 72.0
    @ScaledMetric(relativeTo: .body) private var dayRowHeight = 64.0
    /// The height of the rows, which the iPad form sheet fits itself to.
    @State private var contentHeight: CGFloat?

    var body: some View {
        NavigationStack {
            ScrollView {
                // A plain VStack: a few rows, and the iPad form sheet fits its
                // height to their measured size.
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    daySection
                    eventNavigationSection
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.vertical, Spacing.xLarge)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .fittingSheetHeight(contentHeight)
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
        VStack(alignment: .leading, spacing: Spacing.small) {
            SectionHeader("Comiket")

            NavigationLink {
                CatalogEventSelectionView(catalogLibrary: catalogLibrary)
            } label: {
                CatalogSettingRowLabel(
                    // The open catalog, not the one that is loading: the
                    // days above still belong to it until the switch ends.
                    title: catalogLibrary.selectedEvent?.shortName ?? String(localized: "Comiket"),
                    detail: String(localized: "Choose another Comiket"),
                    systemImage: "calendar.badge.clock",
                    iconColor: Color.accentColor,
                    minimumHeight: eventRowHeight
                ) {
                    LucideIcon("chevron.forward", size: IconSize.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .surface(.card, padding: 0)
            .accessibilityHint("Choose another Comiket")
            .accessibilityIdentifier("catalog-event-selection-link")

            CatalogSwitchProgress(catalogLibrary: catalogLibrary)
        }
    }

    @ViewBuilder
    private var daySection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            SectionHeader("Event day")

            if availableDays.isEmpty {
                HStack(spacing: Spacing.iconToText) {
                    ProgressView()
                    Text(openingLabel)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
                .padding(.horizontal, Spacing.cardPadding)
                .padding(.vertical, Spacing.medium)
                .frame(maxWidth: .infinity, minHeight: dayRowHeight, alignment: .leading)
                .surface(.card, padding: 0)
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

    /// "Sunday, August 11, 2024", or "Sun, Aug 11, 2024" at accessibility
    /// sizes. The month and day never split across lines.
    private func formattedDate(_ day: UFDSchema.Day) -> String? {
        guard let date = Calendar.current.date(from: day.date) else { return nil }
        if dynamicTypeSize.isAccessibilitySize {
            return CatalogDateFormatting.protectingMonthDay(
                in: date.formatted(CatalogDateFormatting.abbreviated(for: date)),
                of: date,
                month: .abbreviated
            )
        }
        return CatalogDateFormatting.protectingMonthDay(
            in: date.formatted(CatalogDateFormatting.full(for: date)),
            of: date,
            month: .wide
        )
    }
}

/// Progress for a switch to another Comiket, with a way to keep the open
/// one. A full catalog download can be hundreds of megabytes.
private struct CatalogSwitchProgress: View {
    let catalogLibrary: CatalogLibrary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let event = catalogLibrary.switchTarget {
            VStack(alignment: .leading, spacing: Spacing.small) {
                // At accessibility sizes the status gets the full width and
                // Cancel moves below it.
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xSmall))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.medium))

                layout {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                        if fractionCompleted == nil {
                            ProgressView()
                        }

                        Text(statusText(for: event))
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .wrapsFully()
                    }
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Cancel", role: .cancel) {
                        catalogLibrary.cancelPendingLoad()
                    }
                    .buttonStyle(.tertiaryAction)
                    .lineLimit(1)
                    .fixedSize()
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card)
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
    // 72 pt: a two-line row with a 12 pt inset; it scales with the text.
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0
    /// The height of the rows, so the iPad form sheet keeps fitting its
    /// content after this page is pushed.
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            // A VStack, not a LazyVStack: the sheet measures every row, and a
            // catalog list has only a few Comikets.
            VStack(alignment: .leading, spacing: Spacing.small) {
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
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.vertical, Spacing.xLarge)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .fittingSheetHeight(contentHeight)
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

/// The content of a sheet row: a leading icon, a title with a detail line
/// that wraps, and a trailing accessory. The icon and the accessory sit on
/// the first line, so they stay beside the title when the detail wraps.
private struct CatalogSettingRowLabel<Accessory: View>: View {
    let title: String
    let detail: String?
    let systemImage: String
    let iconColor: Color
    let minimumHeight: CGFloat
    @ViewBuilder let accessory: Accessory

    /// Half the cap height of the headline title. It centers the icons on
    /// the first line of text.
    @ScaledMetric(relativeTo: .headline) private var halfCapHeight = 6.0

    var body: some View {
        // Read the scaled metric once; alignment guide closures are Sendable.
        let lift = halfCapHeight
        HStack(alignment: .firstTextBaseline, spacing: Spacing.iconToText) {
            LucideIcon(systemImage, size: IconSize.row)
                .foregroundStyle(iconColor)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(title)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .wrapsFully()
                if let detail {
                    Text(detail)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .contentShape(.rect)
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
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            CatalogSettingRowLabel(
                title: title,
                detail: detail,
                systemImage: systemImage,
                iconColor: isSelected ? Color.accentColor : Color.secondary,
                minimumHeight: minimumHeight
            ) {
                if isLoading {
                    ProgressView()
                } else if isSelected {
                    LucideIcon("checkmark.circle.fill", size: IconSize.row)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: shape)
        }
        .buttonStyle(.plain)
        .surface(.card, padding: 0)
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
        // The trait alone announces "Selected"; a value would repeat it.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
