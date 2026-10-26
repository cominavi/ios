import SwiftUI

/// The one filter sheet for every circle list: Explore and the tag pages show
/// the same form, the same Clear rule and the same detents.
struct ExploreFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: ExploreModel
    let favoriteColorLabelStore: FavoriteColorLabelStore

    var body: some View {
        NavigationStack {
            ExploreFilterForm(
                model: model,
                favoriteColorLabelStore: favoriteColorLabelStore
            )
            .navigationTitle("Filter circles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.activeFilters.isEmpty {
                        Button("Clear") {
                            model.clearFilters()
                        }
                        .accessibilityIdentifier("explore-filter-clear")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("explore-filter-sheet")
    }
}

struct ExploreFilterForm: View {
    let model: ExploreModel
    let favoriteColorLabelStore: FavoriteColorLabelStore

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Genre", selection: $model.selectedGenreID) {
                    Text("All genres").tag(Int?.none)
                    ForEach(model.genreFacets) { genre in
                        Text("\(genre.name) (\(genre.count))").tag(Int?.some(genre.id))
                    }
                }
                .accessibilityIdentifier("explore-genre-picker")

                // A tag page is already scoped to one tag. Catalogs without
                // enrichment have no tags, so the row would lead nowhere.
                if !model.hasFixedTag, !model.allDiscoveryTerms.isEmpty {
                    NavigationLink {
                        ExploreTagFilterList(model: model)
                    } label: {
                        LabeledContent("Tags") {
                            Text(selectedTagSummary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("explore-tag-picker")
                }

                ExploreExpandedFilterField(title: "Shinagaki") {
                    ExploreFilterFlowLayout {
                        ForEach(ExploreShinagakiFilter.allCases) { filter in
                            ExploreFilterChoice(
                                isSelected: model.shinagakiFilter == filter,
                                action: { model.shinagakiFilter = filter }
                            ) {
                                Text(filter.title)
                            }
                            .accessibilityIdentifier("explore-shinagaki-\(filter.rawValue)")
                        }
                    }
                }

                ExploreExpandedFilterField(title: "Attendance") {
                    ExploreFilterFlowLayout {
                        ForEach(ExploreAttendanceFilter.allCases) { filter in
                            ExploreFilterChoice(
                                isSelected: model.attendanceFilter == filter,
                                action: { model.attendanceFilter = filter }
                            ) {
                                Text(filter.title)
                            }
                            .accessibilityIdentifier("explore-attendance-\(filter.rawValue)")
                        }
                    }
                }

                ExploreExpandedFilterField(title: "Space") {
                    ExploreFilterFlowLayout {
                        ForEach(ExploreSpaceFilter.allCases) { filter in
                            ExploreFilterChoice(
                                isSelected: model.spaceFilter == filter,
                                action: { model.spaceFilter = filter }
                            ) {
                                Text(filter.title)
                            }
                            .accessibilityIdentifier("explore-space-\(filter.rawValue)")
                        }
                    }
                }
            } header: {
                Text("Catalog")
            } footer: {
                // Catalogs without enrichment never produce tags, so a
                // loading footer would never resolve. Only explain failures.
                if case .unavailable = model.tagState {
                    Text("Some tags are unavailable right now.")
                }
            }

            Section("Your plan") {
                ExploreExpandedFilterField(title: "Saved") {
                    ExploreFilterFlowLayout {
                        ForEach(ExploreFavoriteFilter.allCases) { filter in
                            ExploreFilterChoice(
                                isSelected: model.favoriteFilter == filter,
                                action: { model.favoriteFilter = filter }
                            ) {
                                Text(filter.title)
                            }
                            .accessibilityIdentifier("explore-saved-\(filter.rawValue)")
                        }
                    }
                }

                ExploreFavoriteColorFilter(
                    selection: $model.selectedFavoriteColors,
                    colorLabelStore: favoriteColorLabelStore
                )
            }
        }
    }

    private var selectedTagSummary: String {
        let titles = model.allDiscoveryTerms
            .filter { model.selectedDiscoveryTermIDs.contains($0.id) }
            .map(\.title)
        guard !titles.isEmpty else { return String(localized: "All tags") }
        return titles.formatted(.list(type: model.discoveryMatchMode == .all ? .and : .or))
    }
}

/// Every tag for the selected day, searchable, with the Any/All match mode.
/// It edits the same selection as the popular-tag shortcuts on Explore.
struct ExploreTagFilterList: View {
    let model: ExploreModel
    @State private var query = ""

    var body: some View {
        @Bindable var model = model

        List {
            Section {
                Picker("Match tags", selection: $model.discoveryMatchMode) {
                    ForEach(ExploreDiscoveryMatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("explore-tag-match-mode")
            }

            Section {
                ForEach(filteredTerms) { term in
                    let isSelected = model.selectedDiscoveryTermIDs.contains(term.id)

                    Button {
                        model.toggleDiscoveryTerm(term.id)
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: term.title)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(term.count, format: .number)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)

                            LucideIcon("checkmark")
                                .foregroundStyle(Color.accentColor)
                                .opacity(isSelected ? 1 : 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: term.title))
                    .accessibilityValue("\(term.count) circles")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("explore-tag-option-\(term.id)")
                }
            }
        }
        .overlay {
            if filteredTerms.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search tags")
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !model.selectedDiscoveryTermIDs.isEmpty {
                    Button("Clear") {
                        model.selectedDiscoveryTermIDs = []
                    }
                }
            }
        }
    }

    private var filteredTerms: [ExploreDiscoveryTerm] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return model.allDiscoveryTerms }
        return model.allDiscoveryTerms.filter {
            $0.title.localizedStandardContains(trimmedQuery)
        }
    }
}

/// Sort choices shared by the Explore view options menu and the tag pages.
struct ExploreSortPicker: View {
    @Binding var selection: ExploreSort

    var body: some View {
        Picker("Sort", selection: $selection) {
            ForEach(ExploreSort.allCases) { sort in
                LucideLabel(resource: sort.title, icon: sort.systemImage)
                    .tag(sort)
            }
        }
    }
}

struct ExploreExpandedFilterField<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExploreFilterChoice<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 48, minHeight: 44)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected
                                ? Color.accentColor.opacity(0.8)
                                : Color(uiColor: .separator).opacity(0.45),
                            lineWidth: 1
                        )
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The selected trait already announces "Selected"; a matching value
        // would make VoiceOver say it twice.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ExploreFavoriteColorFilter: View {
    @Binding var selection: Set<BookmarkColor>
    let colorLabelStore: FavoriteColorLabelStore

    init(
        selection: Binding<Set<BookmarkColor>>,
        colorLabelStore: FavoriteColorLabelStore = AppData.favoriteColorLabelStore
    ) {
        _selection = selection
        self.colorLabelStore = colorLabelStore
    }

    var body: some View {
        ExploreExpandedFilterField(title: "Color") {
            ExploreFilterFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(BookmarkColor.selectableColors) { color in
                    let isSelected = selection.contains(color)

                    FavoriteColorLabelSelectionButton(
                        color: color,
                        label: colorLabelStore.customLabels[color],
                        isSelected: isSelected,
                        accessibilityIdentifier: "explore-favorite-color-\(color.rawValue)"
                    ) {
                        if isSelected {
                            selection.remove(color)
                        } else {
                            selection.insert(color)
                        }
                    }
                }
            }
        }
    }
}

struct ExploreFilterFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let sizes = subviews.map { size(for: $0, maxWidth: maxWidth) }
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if currentX > 0, currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            contentWidth = max(contentWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? contentWidth,
            height: currentY + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = size(for: subview, maxWidth: bounds.width)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func size(for subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let intrinsicSize = subview.sizeThatFits(.unspecified)
        guard intrinsicSize.width > maxWidth else { return intrinsicSize }

        return subview.sizeThatFits(
            ProposedViewSize(width: maxWidth, height: nil)
        )
    }
}
