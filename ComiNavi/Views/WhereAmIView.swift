import SwiftUI
import UIKit

private enum ComiketLocationPickerPurpose: Equatable {
    case currentLocation
    /// "Go to space": the attendee knows a space code and wants the circle
    /// there. The flow ends on the circle sheet, which can pin the space.
    case destination

    var flowTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Where am I?"
        case .destination: "Go to Space"
        }
    }

    var venueTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Where are you?"
        case .destination: "Which venue is the circle in?"
        }
    }

    var venueMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Choose your venue manually."
        case .destination:
            "Choose the venue containing the circle you want to visit."
        }
    }

    var characterTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Which letter do you see?"
        case .destination: "Which block letter is the circle in?"
        }
    }

    var characterMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Look for the large block letter nearest to you, then tap the same character below."
        case .destination:
            "Choose the block letter from the circle's Comiket address."
        }
    }

    var numberTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "What number do you see?"
        case .destination: "What space number is the circle in?"
        }
    }

    var numberMessage: LocalizedStringResource {
        switch self {
        case .currentLocation:
            "Enter the one- or two-digit space number printed beside the block letter."
        case .destination:
            "Enter the one- or two-digit space number from the circle's Comiket address."
        }
    }

    var actionTitle: LocalizedStringResource {
        switch self {
        case .currentLocation: "Locate me"
        case .destination: "Show circle"
        }
    }

    var actionIcon: String {
        switch self {
        case .currentLocation: "location.viewfinder"
        case .destination: "mappin.and.ellipse"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .currentLocation: "where-am-i"
        case .destination: "find-table"
        }
    }

    var actionIdentifier: String {
        switch self {
        case .currentLocation: "where-am-i-locate"
        case .destination: "find-table-show"
        }
    }

    /// Only the destination flow lets the attendee pick a day. The choice
    /// stays local until the flow completes.
    var includesDayChoice: Bool {
        self == .destination
    }

    var venueStep: Int { 1 }
    var characterStep: Int { 2 }
    var numberStep: Int { 3 }
    var stepCount: Int { 3 }
}

struct WhereAmIView: View {
    let mapModel: MapScreenModel

    var body: some View {
        ComiketLocationPickerView(
            mapModel: mapModel,
            purpose: .currentLocation
        )
    }
}

/// The "Go to space" flow: day, hall, block, and number lead to the circle
/// sheet for that space.
struct DestinationPickerView: View {
    let mapModel: MapScreenModel

    var body: some View {
        ComiketLocationPickerView(
            mapModel: mapModel,
            purpose: .destination,
            days: mapModel.days
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
    @State private var path: [Step] = []
    @State private var selectedDay: Int
    @State private var venues: [WhereAmIVenueOption] = []
    @State private var selectedVenue: WhereAmIVenueOption?
    @State private var selectedCharacter: String?
    @State private var number = ""
    @State private var isLoadingVenues = true
    @State private var venueError: String?
    @State private var selectionFeedback = 0
    @State private var completionFeedback = 0

    init(
        mapModel: MapScreenModel,
        purpose: ComiketLocationPickerPurpose,
        days: [UFDSchema.Day] = []
    ) {
        self.mapModel = mapModel
        self.purpose = purpose
        self.days = days
        _selectedDay = State(initialValue: mapModel.selectedDay)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VenueSelectionScreen(
                venues: venues,
                purpose: purpose,
                days: purpose.includesDayChoice ? days : [],
                selectedDay: $selectedDay,
                isLoading: isLoadingVenues,
                errorMessage: venueError,
                onSelect: selectVenue
            )
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
                    MapSheetCloseButton {
                        dismiss()
                    }
                    .accessibilityIdentifier("\(purpose.accessibilityPrefix)-close")
                }
            }
        }
        .tint(.accentColor)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .task(id: selectedDay) {
            await loadVenues()
        }
        .accessibilityIdentifier("\(purpose.accessibilityPrefix)-flow")
    }

    private func loadVenues() async {
        isLoadingVenues = true
        venueError = nil
        do {
            venues = try await mapModel.whereAmIVenues(day: selectedDay)
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
                headingDegrees: nil,
                locationReading: nil
            )
            mapModel.locateUser(user)
        case .destination:
            // The app-wide day changes only now, when the attendee confirms.
            mapModel.setSearchPresented(false)
            mapModel.open(
                table: table,
                mapID: selectedVenue.id,
                day: selectedDay,
                preferredSubspace: 0
            )
        }
        completionFeedback += 1
        dismiss()
    }
}

private struct VenueSelectionScreen: View {
    let venues: [WhereAmIVenueOption]
    let purpose: ComiketLocationPickerPurpose
    let days: [UFDSchema.Day]
    @Binding var selectedDay: Int
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (WhereAmIVenueOption) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                WhereAmIHeader(
                    step: purpose.venueStep,
                    totalSteps: purpose.stepCount,
                    title: purpose.venueTitle,
                    message: purpose.venueMessage
                )

                if days.count > 1 {
                    dayPicker
                }

                if purpose == .currentLocation {
                    // A full-width card: the tip wraps at the column edge,
                    // like the venue cards below it, and reads as one element.
                    InlineBanner(
                        "Tip: Touch and hold the map to set your position.",
                        icon: "hand.tap.fill"
                    )
                    .accessibilityIdentifier("where-am-i-long-press-tip")
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
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.xLarge)
            .padding(.bottom, Spacing.xxxLarge)
            .readableWidth()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(purpose.flowTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dayPicker: some View {
        Picker("Day", selection: $selectedDay) {
            ForEach(days.sorted { $0.dayIndex < $1.dayIndex }) { day in
                Text("Day \(day.dayIndex)")
                    .tag(day.dayIndex)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("\(purpose.accessibilityPrefix)-day-picker")
    }

    private var venueButtons: some View {
        VStack(spacing: Spacing.medium) {
            ForEach(venues) { venue in
                LargeVenueButton(
                    venue: venue,
                    accessibilityPrefix: purpose.accessibilityPrefix,
                    action: { onSelect(venue) }
                )
            }
        }
    }
}

private struct LargeVenueButton: View {
    let venue: WhereAmIVenueOption
    let accessibilityPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.iconToText) {
                // Decoration: the badge glyphs (東, EAST) repeat the name.
                BigSightVenueBadge(icon: venue.placement.kind.icon)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                Text(venue.displayName)
                    .font(.sectionTitle)
                    .foregroundStyle(.primary)
                    .wrapsFully()
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LucideIcon("chevron.forward", size: IconSize.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card)
            .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        // The button is one element with the venue name as its label. An
        // extra accessibility container on it would add a second copy.
        .accessibilityLabel(venue.displayName)
        .accessibilityHint("Select this venue")
        .accessibilityIdentifier("\(accessibilityPrefix)-venue-\(venue.id)")
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
            VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
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
                    .font(.rowTitle)
                    .foregroundStyle(.secondary)

                    if isShowingSearch {
                        characterSearchField
                    }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .readableWidth()

                if isFiltering {
                    searchResults
                } else {
                    characterPicker
                }
            }
            .padding(.top, Spacing.xLarge)
            .padding(.bottom, Spacing.xxxLarge)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
        HStack(spacing: Spacing.small) {
            LucideIcon("magnifyingglass", size: IconSize.inline)
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
                    LucideIcon("xmark.circle.fill", size: IconSize.inline)
                        .foregroundStyle(.secondary)
                        .minimumHitArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Spacing.medium)
        // The clear button draws its own 44 pt target to the edge.
        .padding(.trailing, searchQuery.isEmpty ? Spacing.medium : 0)
        .frame(minHeight: HitArea.minimum)
        .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingCharacters.isEmpty {
            LucideContentUnavailableView(
                "No matching block characters",
                icon: "magnifyingglass",
                description: Text("Try hiragana, katakana, or romaji.")
            )
            .frame(minHeight: 180)
            .padding(.horizontal, Spacing.screenGutter)
            .readableWidth()
        } else {
            AlphabetCharacterPicker(
                characters: matchingCharacters,
                accessibilityPrefix: purpose.accessibilityPrefix,
                onSelect: onSelect
            )
            .padding(.horizontal, Spacing.screenGutter)
            .readableWidth()
        }
    }

    @ViewBuilder
    private var characterPicker: some View {
        switch layout.mode {
        case .kana(let columns):
            VStack(alignment: .leading, spacing: Spacing.small) {
                LucideLabel("Read down, then move right", icon: "arrow.down.right")
                    .font(.control)
                    .foregroundStyle(.secondary)
                    // Aligned with the first column of the picker below.
                    .padding(.horizontal, Spacing.screenGutter)
                KanaCharacterPicker(
                    columns: columns,
                    accessibilityPrefix: purpose.accessibilityPrefix,
                    onSelect: onSelect
                )
            }
            .frame(maxWidth: .infinity)
        case .alphabet(let characters):
            VStack(alignment: .leading, spacing: Spacing.medium) {
                if layout.usesOnlyLatinAlphabet {
                    InlineBanner(
                        "Uppercase and lowercase letters identify different areas. Check the letter’s case carefully.",
                        icon: "character.textbox",
                        tone: .warning
                    )
                    .accessibilityIdentifier(
                        "\(purpose.accessibilityPrefix)-alphabet-case-notice")
                }

                AlphabetCharacterPicker(
                    characters: characters,
                    accessibilityPrefix: purpose.accessibilityPrefix,
                    onSelect: onSelect
                )
            }
            .padding(.horizontal, Spacing.screenGutter)
            .readableWidth()
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
            HStack(alignment: .top, spacing: Spacing.medium) {
                ForEach(columns) { column in
                    VStack(spacing: Spacing.medium) {
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
            .padding(.vertical, Spacing.xxSmall)
        }
        .defaultScrollAnchor(.leading)
        .contentMargins(.horizontal, Spacing.screenGutter, for: .scrollContent)
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
        [GridItem(.adaptive(minimum: cellSize), spacing: Spacing.medium)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.medium) {
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
                .background(keyShape.fill(Color(uiColor: .secondarySystemBackground)))
                .overlay { keyShape.strokeBorder(Color.hairline, lineWidth: 0.5) }
                .contentShape(keyShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block \(character)")
        .accessibilityHint("Select this block letter")
        .accessibilityIdentifier("\(accessibilityPrefix)-character-\(character)")
    }

    private var keyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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

    private var completionHint: LocalizedStringResource {
        switch purpose {
        case .currentLocation:
            "Place your position on the venue map"
        case .destination:
            "Open the circle details for this circle"
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
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                WhereAmIHeader(
                    step: purpose.numberStep,
                    totalSteps: purpose.stepCount,
                    title: purpose.numberTitle,
                    message: purpose.numberMessage
                )

                LucideLabel("\(venue.displayName) · Block \(character)", icon: "mappin.and.ellipse")
                    .font(.rowTitle)
                    .foregroundStyle(.secondary)

                numberDisplay
                numberRange
                keypad

                if !number.isEmpty, matchingTable == nil {
                    LucideLabel(
                        "That space is not present in this block.", icon: "exclamationmark.circle"
                    )
                    .font(.rowTitle)
                    .foregroundStyle(.red)
                    .wrapsFully()
                    .accessibilityIdentifier("\(purpose.accessibilityPrefix)-number-error")
                }
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.xLarge)
            .readableWidth(ReadableWidth.form)

            Spacer(minLength: 0)

            Button(action: onComplete) {
                LucideLabel(resource: purpose.actionTitle, icon: purpose.actionIcon)
            }
            .buttonStyle(ActionButtonStyle(role: .primary, size: .large))
            .disabled(matchingTable == nil)
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.small)
            .readableWidth(ReadableWidth.form)
            .accessibilityHint(completionHint)
            .accessibilityIdentifier(purpose.actionIdentifier)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: .rect(cornerRadius: Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(
                        !number.isEmpty && matchingTable == nil
                            ? Color.red.opacity(0.8)
                            : Color.hairline,
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
                .font(.control)
                .foregroundStyle(.secondary)
                .wrapsFully()
        }
    }

    private var keypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.medium), count: 3),
            spacing: Spacing.medium
        ) {
            ForEach(NumberKey.allCases) { key in
                Button {
                    handle(key)
                } label: {
                    key.label
                        .font(key.font)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: .rect(cornerRadius: Radius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Color.hairline, lineWidth: 0.5)
                        }
                        .contentShape(.rect(cornerRadius: Radius.control, style: .continuous))
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
        // Compact at every size: at accessibility sizes the first choices
        // stay above the fold.
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Step \(step) of \(totalSteps)")
                .font(.meta.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
        }
        .wrapsFully()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
    #Preview {
        WhereAmIView(mapModel: .previewCampusFixture())
    }
#endif
