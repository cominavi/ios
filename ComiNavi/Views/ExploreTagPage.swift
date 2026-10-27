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
                // The same skeleton as Explore, so both screens share one
                // loading state.
                ExploreLoadingScreen()
            } else if model.visibleCircles.isEmpty {
                EmptyStateView(
                    "No circles found",
                    icon: "tag.slash",
                    message: "No circles on this day use this tag."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleCircles) { circle in
                            ExploreCircleListRow(
                                circle: circle,
                                model: model,
                                favoriteColorLabels: favoriteColorLabelStore.customLabels,
                                accessibilityIdentifier: "explore-tag-circle-\(circle.id)",
                                onSelect: { selectedCircle = circle },
                                onLongPress: { openLightbox(circle) }
                            )
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
                    Label {
                        Text("Sort")
                    } icon: {
                        LucideIcon(model.sort.systemImage, size: IconSize.action)
                    }
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
                    ExploreCircleListRow(
                        circle: circle,
                        model: model,
                        favoriteColorLabels: [:],
                        accessibilityIdentifier: "explore-tag-circle-\(circle.id)",
                        onSelect: { onSelect(circle) },
                        onLongPress: { openLightbox() }
                    )
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
