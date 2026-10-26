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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsFilters = true
                } label: {
                    ExploreFilterButtonLabel(activeFilterCount: activeFilterCount)
                }
                .accessibilityLabel(
                    ExploreFilterButtonLabel.accessibilityLabel(for: activeFilterCount)
                )
                .accessibilityIdentifier("circle-tag-filters")
                .id(activeFilterCount)

                Menu {
                    ExploreSortPicker(selection: $model.sort)
                        .pickerStyle(.inline)
                } label: {
                    LucideLabel("Sort", icon: model.sort.systemImage)
                }
                .accessibilityLabel(Text("Sort, \(Text(model.sort.title))"))
                .accessibilityIdentifier("circle-tag-sort")
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
            ExploreFilterSheet(
                model: model,
                favoriteColorLabelStore: favoriteColorLabelStore
            )
        }
        .onDisappear {
            lightboxController.cancelPendingLoad()
        }
        .accessibilityIdentifier("circle-tag-page")
    }

    private var activeFilterCount: Int {
        model.activeFilters.count
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
