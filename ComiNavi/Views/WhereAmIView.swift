import CoreLocation
import SwiftUI
import UIKit

private enum ComiketLocationPickerPurpose: Equatable {
    case currentLocation
    case destination
    case circleSearch

    var flowTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Where Am I"
        case .destination: "Find a Table"
        case .circleSearch: "Find a Circle"
        }
    }

    var venueTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Where are you?"
        case .destination: "Which venue is the table in?"
        case .circleSearch: "Which venue is the circle in?"
        }
    }

    var venueMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Choose the venue you are standing in. Location is only used to suggest an answer."
        case .destination:
            "Choose the venue containing the table you want to visit."
        case .circleSearch:
            "Choose the venue containing the circle you want to find."
        }
    }

    var characterTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Which letter do you see?"
        case .destination: "Which letter is your destination?"
        case .circleSearch: "Which block letter is the circle in?"
        }
    }

    var characterMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Look for the large block letter nearest to you, then tap the same character below."
        case .destination:
            "Choose the block letter printed in the destination's Comiket address."
        case .circleSearch:
            "Choose the block letter from the circle's Comiket address."
        }
    }

    var numberTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "What number do you see?"
        case .destination: "What is the destination number?"
        case .circleSearch: "What space number is the circle in?"
        }
    }

    var numberMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Enter the one- or two-digit space number printed beside the block letter."
        case .destination:
            "Enter the one- or two-digit space number from the destination's Comiket address."
        case .circleSearch:
            "Enter the one- or two-digit space number from the circle's Comiket address."
        }
    }

    var actionTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Locate me"
        case .destination: "Show on map"
        case .circleSearch: "Show circle"
        }
    }

    var actionIcon: String {
        switch self {
        case .currentLocation: "location.viewfinder"
        case .destination: "mappin.and.ellipse"
        case .circleSearch: "magnifyingglass"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .currentLocation: "where-am-i"
        case .destination: "find-table"
        case .circleSearch: "find-circle"
        }
    }

    var actionIdentifier: String {
        switch self {
        case .currentLocation: "where-am-i-locate"
        case .destination: "find-table-show"
        case .circleSearch: "find-circle-show"
        }
    }

    var includesDayStep: Bool {
        self == .circleSearch
    }

    var venueStep: Int {
        includesDayStep ? 2 : 1
    }

    var characterStep: Int {
        includesDayStep ? 3 : 2
    }

    var numberStep: Int {
        includesDayStep ? 4 : 3
    }

    var stepCount: Int {
        includesDayStep ? 4 : 3
    }
}

struct WhereAmIView: View {
    let mapModel: MapScreenModel
    let locationService: WhereAmILocationService

    @MainActor
    init(
        mapModel: MapScreenModel,
        locationService: WhereAmILocationService = WhereAmILocationService()
    ) {
        self.mapModel = mapModel
        self.locationService = locationService
    }

    var body: some View {
        ComiketLocationPickerView(
            mapModel: mapModel,
            purpose: .currentLocation,
            locationService: locationService
        )
    }
}

struct DestinationPickerView: View {
    let mapModel: MapScreenModel

    var body: some View {
        ComiketLocationPickerView(
            mapModel: mapModel,
            purpose: .destination,
            locationService: WhereAmILocationService()
        )
    }
}

struct CircleSearchPickerView: View {
    let mapModel: MapScreenModel
    let days: [UFDSchema.Day]

    var body: some View {
        ComiketLocationPickerView(
            mapModel: mapModel,
            purpose: .circleSearch,
            days: days,
            locationService: WhereAmILocationService()
        )
    }
}

private struct ComiketLocationPickerView: View {
    private enum Step: Hashable {
        case character
        case number
    }

    @Environment(\.dismiss) private var dismiss

    let mapModel: MapScreenModel
    let purpose: ComiketLocationPickerPurpose
    let days: [UFDSchema.Day]
    @State private var locationService: WhereAmILocationService
    @State private var path: [Step] = []
    @State private var selectedSearchDay: Int?
    @State private var venues: [WhereAmIVenueOption] = []
    @State private var selectedVenue: WhereAmIVenueOption?
    @State private var selectedCharacter: String?
    @State private var number = ""
    @State private var isLoadingVenues = true
    @State private var venueError: String?
    @State private var selectionFeedback = 0
    @State private var completionFeedback = 0

    @MainActor
    init(
        mapModel: MapScreenModel,
        purpose: ComiketLocationPickerPurpose,
        days: [UFDSchema.Day] = [],
        locationService: WhereAmILocationService = WhereAmILocationService()
    ) {
        self.mapModel = mapModel
        self.purpose = purpose
        self.days = days
        _locationService = State(initialValue: locationService)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if purpose.includesDayStep, selectedSearchDay == nil {
                    DaySelectionScreen(
                        days: days,
                        selectedDay: mapModel.selectedDay,
                        accessibilityPrefix: purpose.accessibilityPrefix,
                        onSelect: selectSearchDay
                    )
                } else {
                    VenueSelectionScreen(
                        venues: venues,
                        purpose: purpose,
                        locationService: locationService,
                        isLoading: isLoadingVenues,
                        errorMessage: venueError,
                        onSelect: selectVenue
                    )
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .character:
                    if let selectedVenue {
                        CharacterSelectionScreen(
                            venue: selectedVenue,
                            purpose: purpose,
                            onSelect: selectCharacter
                        )
                    }
                case .number:
                    if let selectedVenue, let selectedCharacter {
                        NumberSelectionScreen(
                            venue: selectedVenue,
                            purpose: purpose,
                            character: selectedCharacter,
                            number: $number,
                            onKeyPress: { selectionFeedback += 1 },
                            onComplete: complete
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        LucideLabel("Close", icon: "xmark")
                    }
                    .controlSize(.large)
                    .accessibilityIdentifier("\(purpose.accessibilityPrefix)-close")
                }
            }
        }
        .tint(.accentColor)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .task {
            if purpose == .currentLocation {
                locationService.start()
            }
            if !purpose.includesDayStep {
                await loadVenues()
            }
        }
        .onDisappear {
            if purpose == .currentLocation {
                locationService.stop()
            }
        }
        .accessibilityIdentifier("\(purpose.accessibilityPrefix)-flow")
    }

    private func selectSearchDay(_ day: UFDSchema.Day) {
        selectedSearchDay = day.dayIndex
        mapModel.select(day: day.dayIndex)
        path.removeAll()
        Task {
            await loadVenues()
        }
    }

    private func loadVenues() async {
        isLoadingVenues = true
        venueError = nil
        do {
            venues = try await mapModel.whereAmIVenues()
        } catch is CancellationError {
            return
        } catch {
            venueError = error.localizedDescription
        }
        isLoadingVenues = false
    }

    private func selectVenue(_ venue: WhereAmIVenueOption) {
        selectedVenue = venue
        selectedCharacter = nil
        number = ""
        selectionFeedback += 1
        path.append(.character)
    }

    private func selectCharacter(_ character: String) {
        selectedCharacter = character
        number = ""
        selectionFeedback += 1
        path.append(.number)
    }

    private func complete() {
        guard let selectedVenue,
            let selectedCharacter,
            let numericValue = Int(number),
            let table = WhereAmIResolver.table(
                blockName: selectedCharacter,
                number: numericValue,
                in: selectedVenue.placement.scene
            )
        else {
            return
        }

        switch purpose {
        case .currentLocation:
            let user = WhereAmIResolver.locatedUser(
                at: table,
                in: selectedVenue,
                subspace: nil,
                headingDegrees: locationService.headingDegrees,
                locationReading: locationService.latestReading
            )
            mapModel.locateUser(user)
        case .destination:
            mapModel.show(
                WhereAmIResolver.destination(
                    at: table,
                    in: selectedVenue
                ))
        case .circleSearch:
            mapModel.setSearchPresented(false)
            mapModel.select(table: table, preferredSubspace: 0)
        }
        completionFeedback += 1
        dismiss()
    }
}

private struct DaySelectionScreen: View {
    let days: [UFDSchema.Day]
    let selectedDay: Int
    let accessibilityPrefix: String
    let onSelect: (UFDSchema.Day) -> Void

    private var orderedDays: [UFDSchema.Day] {
        days.sorted { $0.dayIndex < $1.dayIndex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WhereAmIHeader(
                    step: 1,
                    totalSteps: 4,
                    title: "Which day is the circle in?",
                    message: "Choose the event day printed on the circle's Comiket address."
                )

                VStack(spacing: 12) {
                    ForEach(orderedDays) { day in
                        Button {
                            onSelect(day)
                        } label: {
                            HStack(spacing: 14) {
                                LucideIcon("calendar")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(
                                        day.dayIndex == selectedDay
                                            ? Color.accentColor
                                            : Color.secondary
                                    )
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Day \(day.dayIndex)")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.primary)

                                    if let date = Calendar.current.date(from: day.date) {
                                        Text(
                                            date,
                                            format: CatalogDateFormatting.full(for: date)
                                        )
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 8)

                                LucideIcon("chevron.forward")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(.rect(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        day.dayIndex == selectedDay
                                            ? Color.accentColor.opacity(0.6)
                                            : Color(uiColor: .separator).opacity(0.38),
                                        lineWidth: day.dayIndex == selectedDay ? 1.5 : 0.5
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Day \(day.dayIndex)")
                        .accessibilityHint("Choose this event day")
                        .accessibilityIdentifier(
                            "\(accessibilityPrefix)-day-\(day.dayIndex)"
                        )
                    }
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Find a Circle")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct VenueSelectionScreen: View {
    let venues: [WhereAmIVenueOption]
    let purpose: ComiketLocationPickerPurpose
    let locationService: WhereAmILocationService
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (WhereAmIVenueOption) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WhereAmIHeader(
                    step: purpose.venueStep,
                    totalSteps: purpose.stepCount,
                    title: purpose.venueTitle,
                    message: purpose.venueMessage
                )

                if purpose == .currentLocation {
                    LocationStatusView(service: locationService)
                }

                if isLoading {
                    ProgressView("Loading venue maps…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage {
                    LucideContentUnavailableView(
                        "Venues unavailable",
                        icon: "building.2.crop.circle",
                        description: Text(errorMessage)
                    )
                } else {
                    venueButtons
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(purpose.flowTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var venueButtons: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = locationService.locationState(at: context.date)
            let suggested = purpose == .currentLocation ? suggestion(for: state) : nil

            VStack(spacing: 12) {
                ForEach(venues) { venue in
                    LargeVenueButton(
                        venue: venue,
                        accessibilityPrefix: purpose.accessibilityPrefix,
                        suggestion: suggested?.venue.id == venue.id ? suggested?.source : nil,
                        action: { onSelect(venue) }
                    )
                }
            }
        }
    }

    private func suggestion(
        for state: WhereAmILocationService.LocationState
    ) -> (venue: WhereAmIVenueOption, source: VenueSuggestionSource)? {
        let reading: WhereAmILocationReading
        let source: VenueSuggestionSource
        switch state {
        case .live(let value):
            reading = value
            source = .live
        case .cached(let value):
            reading = value
            source = .cached
        case .waiting, .unavailable:
            return nil
        }
        guard let venue = WhereAmIResolver.nearestVenue(to: reading, venues: venues) else {
            return nil
        }
        return (venue, source)
    }
}

private enum VenueSuggestionSource {
    case live
    case cached
}

private struct LargeVenueButton: View {
    let venue: WhereAmIVenueOption
    let accessibilityPrefix: String
    let suggestion: VenueSuggestionSource?
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var minimumHeight = 88.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                BigSightVenueBadge(icon: venue.placement.kind.icon)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(venue.displayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let suggestion {
                        LucideLabel(
                            resource:
                                suggestion == .live
                                ? LocalizedStringResource("Suggested by live location")
                                : LocalizedStringResource("Suggested by last location"),
                            icon: suggestion == .live ? "location.fill" : "location"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(suggestion == .live ? Color.blue : Color.secondary)
                    }
                }

                LucideIcon("chevron.forward")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(uiColor: .separator).opacity(0.38), lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(venue.displayName)
        .accessibilityHint(
            suggestion == nil
                ? "Select this venue"
                : "Location suggests this venue. Double tap to select it."
        )
        .accessibilityIdentifier("\(accessibilityPrefix)-venue-\(venue.id)")
    }
}

private struct LocationStatusView: View {
    let service: WhereAmILocationService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = service.locationState(at: context.date)
            HStack(spacing: 14) {
                statusIcon(state)
                    .font(.title2)
                    .frame(width: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle(state))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(statusMessage(state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("where-am-i-location-status")
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: WhereAmILocationService.LocationState) -> some View {
        switch state {
        case .live:
            LucideIcon("location.fill")
                .foregroundStyle(.blue)
        case .cached:
            LucideIcon("location")
                .foregroundStyle(.secondary)
        case .waiting:
            ProgressView()
        case .unavailable:
            LucideIcon("location.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func statusTitle(_ state: WhereAmILocationService.LocationState)
        -> LocalizedStringResource
    {
        switch state {
        case .live: "Using live location"
        case .cached: "Using last received location"
        case .waiting: "Finding your location"
        case .unavailable: "Location unavailable"
        }
    }

    private func statusMessage(_ state: WhereAmILocationService.LocationState) -> String {
        switch state {
        case .live(let reading), .cached(let reading):
            return String(
                localized:
                    "Accuracy about \(Int(reading.horizontalAccuracy.rounded())) meters. You always confirm the venue."
            )
        case .waiting:
            return String(localized: "You can choose a venue while this updates.")
        case .unavailable:
            return service.errorMessage ?? String(localized: "Choose your venue manually.")
        }
    }
}

private struct CharacterSelectionScreen: View {
    let venue: WhereAmIVenueOption
    let purpose: ComiketLocationPickerPurpose
    let onSelect: (String) -> Void

    @State private var searchQuery = ""
    @State private var isShowingSearch = false
    @FocusState private var isSearchFocused: Bool

    private var layout: WhereAmICharacterLayout {
        WhereAmICharacterLayout.make(
            availableCharacters: venue.placement.scene.blockLabels.map(\.name)
        )
    }

    private var matchingCharacters: [String] {
        WhereAmICharacterSearch.filter(layout.orderedCharacters, query: searchQuery)
    }

    private var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    WhereAmIHeader(
                        step: purpose.characterStep,
                        totalSteps: purpose.stepCount,
                        title: purpose.characterTitle,
                        message: purpose.characterMessage
                    )

                    Label {
                        Text(venue.displayName)
                    } icon: {
                        BigSightVenueBadge(icon: venue.placement.kind.icon)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                    }
                    .font(.headline)
                    .foregroundStyle(.secondary)

                    if isShowingSearch {
                        characterSearchField
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)

                if isFiltering {
                    searchResults
                } else {
                    characterPicker
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(venue.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if isShowingSearch {
                        isSearchFocused = false
                        searchQuery = ""
                        isShowingSearch = false
                    } else {
                        isShowingSearch = true
                    }
                } label: {
                    LucideIcon(isShowingSearch ? "xmark" : "magnifyingglass")
                }
                .accessibilityLabel(
                    isShowingSearch ? "Close character search" : "Search block characters"
                )
                .accessibilityIdentifier(
                    "\(purpose.accessibilityPrefix)-character-search-button"
                )
            }
        }
        .onChange(of: isShowingSearch) {
            if isShowingSearch {
                isSearchFocused = true
            }
        }
    }

    private var characterSearchField: some View {
        HStack(spacing: 10) {
            LucideIcon("magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Hiragana, katakana, or romaji", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .accessibilityIdentifier(
                    "\(purpose.accessibilityPrefix)-character-search-field"
                )

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    LucideIcon("xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingCharacters.isEmpty {
            LucideContentUnavailableView(
                "No matching block characters",
                icon: "magnifyingglass",
                description: Text("Try hiragana, katakana, or romaji.")
            )
            .frame(maxWidth: 760, minHeight: 180)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        } else {
            AlphabetCharacterPicker(
                characters: matchingCharacters,
                accessibilityPrefix: purpose.accessibilityPrefix,
                onSelect: onSelect
            )
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var characterPicker: some View {
        switch layout.mode {
        case .kana(let columns):
            VStack(alignment: .leading, spacing: 10) {
                LucideLabel("Read down, then move right", icon: "arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                KanaCharacterPicker(
                    columns: columns,
                    accessibilityPrefix: purpose.accessibilityPrefix,
                    onSelect: onSelect
                )
            }
            .frame(maxWidth: .infinity)
        case .alphabet(let characters):
            VStack(alignment: .leading, spacing: 14) {
                if layout.usesOnlyLatinAlphabet {
                    LucideLabel(
                        "Uppercase and lowercase letters identify different areas. Check the letter’s case carefully.",
                        icon: "character.textbox"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 0.5)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "\(purpose.accessibilityPrefix)-alphabet-case-notice")
                }

                AlphabetCharacterPicker(
                    characters: characters,
                    accessibilityPrefix: purpose.accessibilityPrefix,
                    onSelect: onSelect
                )
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct KanaCharacterPicker: View {
    let columns: [WhereAmICharacterLayout.KanaColumn]
    let accessibilityPrefix: String
    let onSelect: (String) -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var cellSize = 88.0
    @State private var edgeFade = HorizontalScrollEdgeFade()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    VStack(spacing: 10) {
                        ForEach(column.cells) { cell in
                            if let character = cell.character {
                                CharacterButton(
                                    character: character,
                                    minimumSize: cellSize,
                                    accessibilityPrefix: accessibilityPrefix,
                                    action: { onSelect(character) }
                                )
                                .frame(width: cellSize)
                            } else {
                                Color.clear
                                    .frame(width: cellSize, height: cellSize)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.leading)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollIndicators(.visible)
        .onScrollGeometryChange(for: HorizontalScrollEdgeFade.self) { geometry in
            HorizontalScrollEdgeFade(geometry: geometry)
        } action: { _, newValue in
            edgeFade = newValue
        }
        .mask {
            HorizontalEdgeFadeMask(edgeFade: edgeFade)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Characters in Gojūon order, starting with あ on the left")
    }
}

private struct HorizontalScrollEdgeFade: Equatable {
    private static let activationDistance: CGFloat = 18

    var leading = 0.0
    var trailing = 0.0

    init() {}

    init(geometry: ScrollGeometry) {
        let leadingDistance = max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
        let trailingDistance = max(
            0,
            geometry.contentSize.width
                + geometry.contentInsets.leading
                + geometry.contentInsets.trailing
                - geometry.containerSize.width
                - leadingDistance
        )
        leading = min(1, leadingDistance / Self.activationDistance)
        trailing = min(1, trailingDistance / Self.activationDistance)
    }
}

private struct HorizontalEdgeFadeMask: View {
    let edgeFade: HorizontalScrollEdgeFade

    private let fadeWidth = 22.0

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - edgeFade.leading), .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)

            Color.black

            LinearGradient(
                colors: [.black, .black.opacity(1 - edgeFade.trailing)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
        }
        .animation(.easeOut(duration: 0.1), value: edgeFade)
    }
}

private struct AlphabetCharacterPicker: View {
    let characters: [String]
    let accessibilityPrefix: String
    let onSelect: (String) -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var cellSize = 88.0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(characters, id: \.self) { character in
                CharacterButton(
                    character: character,
                    minimumSize: cellSize,
                    accessibilityPrefix: accessibilityPrefix,
                    action: { onSelect(character) }
                )
            }
        }
    }
}

private struct CharacterButton: View {
    let character: String
    let minimumSize: CGFloat
    let accessibilityPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(character)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: minimumSize)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(uiColor: .separator).opacity(0.38), lineWidth: 0.5)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block \(character)")
        .accessibilityHint("Select this block letter")
        .accessibilityIdentifier("\(accessibilityPrefix)-character-\(character)")
    }
}

private struct NumberSelectionScreen: View {
    let venue: WhereAmIVenueOption
    let purpose: ComiketLocationPickerPurpose
    let character: String
    @Binding var number: String
    let onKeyPress: () -> Void
    let onComplete: () -> Void

    @ScaledMetric(relativeTo: .title) private var keyHeight = 56.0
    @ScaledMetric(relativeTo: .title2) private var locateHeight = 60.0

    private var completionHint: LocalizedStringResource {
        switch purpose {
        case .currentLocation:
            "Place your position on the venue map"
        case .destination:
            "Pin this table on the map; use current signs and staff directions"
        case .circleSearch:
            "Open the circle details for this table"
        }
    }

    private var tables: [CatalogMapTable] {
        venue.placement.scene.tables.filter { $0.blockName == character }
    }

    private var matchingTable: CatalogMapTable? {
        guard let numericValue = Int(number) else { return nil }
        return WhereAmIResolver.table(
            blockName: character,
            number: numericValue,
            in: venue.placement.scene
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                WhereAmIHeader(
                    step: purpose.numberStep,
                    totalSteps: purpose.stepCount,
                    title: purpose.numberTitle,
                    message: purpose.numberMessage
                )

                LucideLabel("\(venue.displayName) · Block \(character)", icon: "mappin.and.ellipse")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                numberDisplay
                numberRange
                keypad

                if !number.isEmpty, matchingTable == nil {
                    LucideLabel(
                        "That space is not present in this block.", icon: "exclamationmark.circle"
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(purpose.accessibilityPrefix)-number-error")
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            Button(action: onComplete) {
                LucideLabel(resource: purpose.actionTitle, icon: purpose.actionIcon)
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: locateHeight)
            }
            .buttonStyle(.borderedProminent)
            .disabled(matchingTable == nil)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .accessibilityHint(completionHint)
            .accessibilityIdentifier(purpose.actionIdentifier)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Block \(character)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var numberDisplay: some View {
        Text(number.isEmpty ? String(localized: "Enter 1–2 digits") : number)
            .font(
                number.isEmpty
                    ? .title3.weight(.semibold)
                    : .largeTitle.monospacedDigit().weight(.bold)
            )
            .foregroundStyle(numberDisplayColor)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        !number.isEmpty && matchingTable == nil
                            ? Color.red.opacity(0.8)
                            : Color(uiColor: .separator).opacity(0.38),
                        lineWidth: !number.isEmpty && matchingTable == nil ? 1.5 : 0.5
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                number.isEmpty
                    ? String(localized: "No number entered")
                    : String(localized: "Entered number \(number)")
            )
            .accessibilityIdentifier("\(purpose.accessibilityPrefix)-number-display")
    }

    private var numberDisplayColor: Color {
        if number.isEmpty { return .secondary }
        return matchingTable == nil ? .red : .primary
    }

    @ViewBuilder
    private var numberRange: some View {
        if let minimum = tables.map(\.id.spaceNumber).min(),
            let maximum = tables.map(\.id.spaceNumber).max()
        {
            Text("Available spaces: \(minimum) through \(maximum)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var keypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            ForEach(NumberKey.allCases) { key in
                Button {
                    handle(key)
                } label: {
                    key.label
                        .font(key.font)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(uiColor: .separator).opacity(0.38), lineWidth: 0.5)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(key == .delete && number.isEmpty)
                .accessibilityLabel(key.accessibilityLabel)
                .accessibilityIdentifier("\(purpose.accessibilityPrefix)-\(key.identifierSuffix)")
            }
        }
    }

    private func handle(_ key: NumberKey) {
        switch key {
        case .digit(let digit):
            guard number.count < 2 else { return }
            number.append(digit)
        case .clear:
            number = ""
        case .delete:
            number = String(number.dropLast())
        }
        onKeyPress()
    }
}

private enum NumberKey: Hashable, CaseIterable, Identifiable {
    case digit(Character)
    case clear
    case delete

    static let allCases: [NumberKey] = [
        .digit("1"), .digit("2"), .digit("3"),
        .digit("4"), .digit("5"), .digit("6"),
        .digit("7"), .digit("8"), .digit("9"),
        .clear, .digit("0"), .delete,
    ]

    var id: String { identifierSuffix }

    @MainActor @ViewBuilder
    var label: some View {
        switch self {
        case .digit(let digit): Text(String(digit))
        case .clear: Text("Clear")
        case .delete: LucideIcon("delete.left.fill")
        }
    }

    var font: Font {
        switch self {
        case .digit: .title.weight(.bold).monospacedDigit()
        case .clear: .headline
        case .delete: .title2
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .digit(let digit): String(digit)
        case .clear: String(localized: "Clear number")
        case .delete: String(localized: "Delete last digit")
        }
    }

    var identifierSuffix: String {
        switch self {
        case .digit(let digit): "digit-\(digit)"
        case .clear: "clear"
        case .delete: "delete"
        }
    }
}

private struct WhereAmIHeader: View {
    let step: Int
    let totalSteps: Int
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    init(
        step: Int,
        totalSteps: Int = 3,
        title: LocalizedStringResource,
        message: LocalizedStringResource
    ) {
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(step) of \(totalSteps)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
    #Preview {
        WhereAmIView(
            mapModel: .previewCampusFixture(),
            locationService: WhereAmILocationService(
                simulatedReading: WhereAmILocationReading(
                    coordinate: BigSightCampusLayout.eastBuilding,
                    horizontalAccuracy: 12,
                    timestamp: .now
                ),
                simulatedHeading: 72
            )
        )
    }
#endif
