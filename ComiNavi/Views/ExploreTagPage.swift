import SwiftUI

struct ExploreTagPage: View {
    let tag: String
    let dataSource: CirclemsDataSource

    @State private var model: ExploreModel
    @State private var lightboxImage: UIImage?
    @State private var showsFilters = false

    init(tag: String, day: Int, dataSource: CirclemsDataSource) {
        self.tag = tag
        self.dataSource = dataSource
        _model = State(initialValue: ExploreModel(
            dataSource: dataSource,
            selectedDay: day,
            selectedTag: tag
        ))
    }

    var body: some View {
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
                            NavigationLink {
                                CircleDetailView(
                                    circles: circle.circles,
                                    dataSource: dataSource,
                                    tags: circle.tags
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    ExploreCircleRow(circle: circle, model: model)

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
                            .onLongPressGesture(minimumDuration: 0.45) {
                                openLightbox(circle)
                            }

                            Divider()
                                .padding(.leading, 104)
                        }
                    }
                }
            }
        }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: Binding(
            get: { lightboxImage != nil },
            set: { if !$0 { lightboxImage = nil } }
        )) {
            if let lightboxImage {
                ShinagakiLightbox(
                    image: lightboxImage,
                    accessibilityLabel: String(localized: "Circle cover")
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
            }
        }
        .sheet(isPresented: $showsFilters) {
            ExploreTagFilterSheet(model: model, dataSource: dataSource)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        Task { @MainActor in
            guard let data = await model.fullCoverImageData(for: circle) else { return }
            lightboxImage = UIImage(data: data)
        }
    }
}

private struct ExploreTagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ExploreModel
    let dataSource: CirclemsDataSource

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("Catalog") {
                    Picker("Day", selection: Binding(
                        get: { model.selectedDay },
                        set: { model.select(day: $0) }
                    )) {
                        ForEach(dataSource.comiket.days, id: \.dayIndex) { day in
                            Text("Day \(day.dayIndex)").tag(day.dayIndex)
                        }
                    }

                    Picker("Genre", selection: $model.selectedGenreID) {
                        Text("All genres").tag(Int?.none)
                        ForEach(model.genreFacets) { genre in
                            Text("\(genre.name) (\(genre.count))").tag(Int?.some(genre.id))
                        }
                    }

                    Picker("Shinagaki", selection: $model.shinagakiFilter) {
                        ForEach(ExploreShinagakiFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }

                    Picker("Attendance", selection: $model.attendanceFilter) {
                        ForEach(ExploreAttendanceFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }

                    Picker("Space", selection: $model.spaceFilter) {
                        ForEach(ExploreSpaceFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                }

                Section("Your plan") {
                    Picker("Saved", selection: $model.favoriteFilter) {
                        ForEach(ExploreFavoriteFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(BookmarkColor.selectableColors) { color in
                                Button {
                                    if model.selectedFavoriteColors.contains(color) {
                                        model.selectedFavoriteColors.remove(color)
                                    } else {
                                        model.selectedFavoriteColors.insert(color)
                                    }
                                } label: {
                                    Circle()
                                        .fill(color.swiftUIColor)
                                        .frame(width: 30, height: 30)
                                        .padding(7)
                                        .overlay {
                                            Circle()
                                                .stroke(
                                                    model.selectedFavoriteColors.contains(color)
                                                        ? Color.primary
                                                        : Color.clear,
                                                    lineWidth: 2
                                                )
                                        }
                                        .contentShape(.circle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(color.displayName)
                                .accessibilityValue(
                                    model.selectedFavoriteColors.contains(color)
                                        ? "Selected"
                                        : "Not selected"
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                Section("Order") {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(ExploreSort.allCases) { sort in
                            Text(sort.title).tag(sort)
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
