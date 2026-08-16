import SwiftUI

struct ExploreTagPage: View {
    let tag: String
    let dataSource: CirclemsDataSource
    let favoriteColorLabelStore: FavoriteColorLabelStore

    @State private var model: ExploreModel
    @State private var lightboxController = ExploreArtworkLightboxController()
    @State private var selectedCircle: ExploreCircle?
    @State private var showsFilters = false

    init(
        tag: String,
        day: Int,
        dataSource: CirclemsDataSource,
        favoriteColorLabelStore: FavoriteColorLabelStore =
            AppData.favoriteColorLabelStore
    ) {
        self.tag = tag
        self.dataSource = dataSource
        self.favoriteColorLabelStore = favoriteColorLabelStore
        _model = State(initialValue: ExploreModel(
            dataSource: dataSource,
            selectedDay: day,
            selectedTag: tag
        ))
    }

    var body: some View {
        @Bindable var lightboxController = lightboxController

        Group {
            if (model.isLoading && model.allCircles.isEmpty) || model.isResolvingFixedTag {
                ProgressView("Loading circles…")
            } else if model.visibleCircles.isEmpty {
                LucideContentUnavailableView(
                    "No circles found",
                    icon: "tag.slash",
                    description: Text("No circles on this day use this tag.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleCircles) { circle in
                            ExploreTagCircleLink(
                                circle: circle,
                                model: model,
                                favoriteColorLabels: favoriteColorLabelStore.customLabels,
                                onSelect: { selectedCircle = circle },
                                onLongPress: { openLightbox(circle) }
                            )

                            Divider()
                                .padding(.leading, 104)
                        }
                    }
                }
            }
        }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .exploreCircleDestination(selection: $selectedCircle) { circle in
            CircleDetailView(
                circles: circle.circles,
                dataSource: dataSource,
                tags: circle.tags,
                favoriteColorLabelStore: favoriteColorLabelStore
            )
        }
        .searchable(text: $model.searchQuery, prompt: "Search within this tag")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsFilters = true
                } label: {
                    HStack(spacing: 5) {
                        LucideIcon("slider.horizontal.3")
                        if activeFilterCount > 0 {
                            Text(activeFilterCount, format: .number)
                                .font(.caption.monospacedDigit().weight(.bold))
                        }
                    }
                }
                .accessibilityLabel("Filters")
                .accessibilityValue("\(activeFilterCount) active")
                .accessibilityIdentifier("circle-tag-filters")
            }
        }
        .task(id: tag) {
            await model.load()
        }
        .sheet(item: $lightboxController.presentation) { presentation in
            ShinagakiLightbox(presentation: presentation)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showsFilters) {
            ExploreTagFilterSheet(model: model, dataSource: dataSource)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            lightboxController.cancelPendingLoad()
        }
        .accessibilityIdentifier("circle-tag-page")
    }

    private var activeFilterCount: Int {
        (model.selectedGenreID == nil ? 0 : 1)
            + (model.shinagakiFilter == .all ? 0 : 1)
            + (model.favoriteFilter == .all ? 0 : 1)
            + (model.selectedFavoriteColors.isEmpty ? 0 : 1)
            + (model.attendanceFilter == .all ? 0 : 1)
            + (model.spaceFilter == .all ? 0 : 1)
            + (model.sort == .catalog ? 0 : 1)
    }

    private func openLightbox(_ circle: ExploreCircle) {
        lightboxController.present(circle: circle) {
            await model.fullCoverImage(for: circle)
        }
    }
}

private struct ExploreTagCircleLink: View {
    let circle: ExploreCircle
    let model: ExploreModel
    let favoriteColorLabels: [BookmarkColor: String]
    let onSelect: () -> Void
    let onLongPress: () -> Void

    init(
        circle: ExploreCircle,
        model: ExploreModel,
        favoriteColorLabels: [BookmarkColor: String] = [:],
        onSelect: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) {
        self.circle = circle
        self.model = model
        self.favoriteColorLabels = favoriteColorLabels
        self.onSelect = onSelect
        self.onLongPress = onLongPress
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ExploreCircleRow(
                    circle: circle,
                    model: model,
                    favoriteColorLabels: favoriteColorLabels
                )

                LucideIcon("chevron.forward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ExploreLayoutMetrics.horizontalContentInset)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in onLongPress() }
        )
        .accessibilityIdentifier("explore-tag-circle-\(circle.id)")
    }
}

#if DEBUG
    struct ExploreTagLongPressUITestSurface: View {
        let circle: ExploreCircle
        let model: ExploreModel
        let onSelect: (ExploreCircle) -> Void

        @State private var lightboxController = ExploreArtworkLightboxController()

        var body: some View {
            @Bindable var lightboxController = lightboxController

            ScrollView {
                LazyVStack(spacing: 0) {
                    ExploreTagCircleLink(
                        circle: circle,
                        model: model,
                        onSelect: { onSelect(circle) },
                        onLongPress: { openLightbox() }
                    )

                    Divider()
                        .padding(.leading, 104)
                }
            }
            .accessibilityIdentifier("explore-tag-test-surface")
            .sheet(item: $lightboxController.presentation) { presentation in
                ShinagakiLightbox(presentation: presentation)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
            }
            .onDisappear {
                lightboxController.cancelPendingLoad()
            }
        }

        private func openLightbox() {
            lightboxController.present(circle: circle) {
                await model.fullCoverImage(for: circle)
            }
        }
    }
#endif

private struct ExploreTagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ExploreModel
    let dataSource: CirclemsDataSource

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("Catalog") {
                    ExploreExpandedFilterField(title: "Day") {
                        ExploreFilterFlowLayout {
                            ForEach(dataSource.comiket.days, id: \.dayIndex) { day in
                                ExploreFilterChoice(
                                    isSelected: model.selectedDay == day.dayIndex,
                                    action: { model.select(day: day.dayIndex) }
                                ) {
                                    Text("Day \(day.dayIndex)")
                                }
                            }
                        }
                    }

                    Picker("Genre", selection: $model.selectedGenreID) {
                        Text("All genres").tag(Int?.none)
                        ForEach(model.genreFacets) { genre in
                            Text("\(genre.name) (\(genre.count))").tag(Int?.some(genre.id))
                        }
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
                            }
                        }
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
                            }
                        }
                    }

                    ExploreFavoriteColorFilter(selection: $model.selectedFavoriteColors)
                }

                Section("Order") {
                    ExploreExpandedFilterField(title: "Sort") {
                        ExploreFilterFlowLayout {
                            ForEach(ExploreSort.allCases) { sort in
                                ExploreFilterChoice(
                                    isSelected: model.sort == sort,
                                    action: { model.sort = sort }
                                ) {
                                    Text(sort.title)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter circles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        model.selectedGenreID = nil
                        model.shinagakiFilter = .all
                        model.favoriteFilter = .all
                        model.selectedFavoriteColors = []
                        model.attendanceFilter = .all
                        model.spaceFilter = .all
                        model.sort = .catalog
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
