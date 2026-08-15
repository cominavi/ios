import SwiftUI

enum ExploreLayoutMetrics {
    static let horizontalContentInset: CGFloat = 16
    static let listArtworkWidth: CGFloat = 76
    static let circleArtworkAspectRatio = ShinagakiArtworkLayout.a4PortraitAspectRatio

    static func artworkPixelSize(
        width: CGFloat,
        displayScale: CGFloat
    ) -> ExploreArtworkPixelSize {
        ExploreArtworkPixelSize(
            width: Int(ceil(width * displayScale)),
            height: Int(ceil(width / circleArtworkAspectRatio * displayScale))
        )
    }
}

struct ExploreView<EventDayHeader: View>: View {
    @Binding private var selectedDay: Int
    @State private var model: ExploreModel
    @State private var showsFilters = false
    @State private var showsGalleryZoomOnboarding = false
    private let eventDayHeader: EventDayHeader
    private let onboardingStore: FeatureOnboardingStore

    init(
        dataSource: CirclemsDataSource,
        selectedDay: Binding<Int>,
        onboardingDefaults: UserDefaults = .standard,
        @ViewBuilder eventDayHeader: () -> EventDayHeader
    ) {
        _selectedDay = selectedDay
        _model = State(initialValue: ExploreModel(
            dataSource: dataSource,
            selectedDay: selectedDay.wrappedValue
        ))
        onboardingStore = FeatureOnboardingStore(defaults: onboardingDefaults)
        self.eventDayHeader = eventDayHeader()
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(spacing: 0) {
                ExploreSearchField(model: model)

                Group {
                    if model.isLoading, model.allCircles.isEmpty {
                        ExploreLoadingScreen()
                    } else if model.visibleCircles.isEmpty {
                        ContentUnavailableView {
                            LucideLabel("No circles found", icon: "sparkle.magnifyingglass")
                        } description: {
                            Text(emptyMessage)
                        } actions: {
                            if activeFilterCount > 0 {
                                Button("Clear filters") {
                                    model.clearFilters()
                                }
                            }
                        }
                    } else {
                        results
                    }
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    eventDayHeader
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsFilters = true
                    } label: {
                        LucideLabel(
                            "Filter",
                            icon: activeFilterCount == 0
                                ? "line.3.horizontal.decrease"
                                : "line.3.horizontal.decrease.circle.fill"
                        )
                    }
                    .accessibilityValue(activeFilterCount == 0 ? "No filters" : "\(activeFilterCount) active")
                    .accessibilityIdentifier("explore-filter-button")
                    .id(activeFilterCount)

                    Button {
                        model.layout = model.layout == .gallery ? .list : .gallery
                    } label: {
                        LucideLabel("Layout", icon: model.layout.systemImage)
                    }
                    .accessibilityValue(model.layout.title)
                    .accessibilityIdentifier("explore-layout-button")

                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            ForEach(ExploreSort.allCases) { sort in
                                LucideLabel(resource: sort.title, icon: sort.systemImage)
                                    .tag(sort)
                            }
                        }
                    } label: {
                        LucideLabel("Sort", icon: "chevron.up.chevron.down")
                    }
                    .accessibilityValue(Text(model.sort.title))
                    .accessibilityIdentifier("explore-sort-button")
                }
            }
            .sheet(isPresented: $showsFilters) {
                ExploreFilterSheet(model: model)
            }
        }
        .task {
            model.select(day: selectedDay)
            await model.load()
            presentGalleryZoomOnboardingIfNeeded()
        }
        .onAppear {
            Task {
                await model.refreshUserPlan()
            }
        }
        .onChange(of: selectedDay) { _, day in
            model.select(day: day)
        }
        .onChange(of: model.layout) {
            presentGalleryZoomOnboardingIfNeeded()
        }
        .featureOnboardingDialog(
            isPresented: $showsGalleryZoomOnboarding,
            accessibilityIdentifier: "explore-zoom-onboarding",
            title: "Make Explore yours",
            message: "Pinch the gallery to make circle images larger or fit more on screen.",
            dismissButtonTitle: "Got it",
            onDismiss: completeGalleryZoomOnboarding
        ) {
            ExploreGalleryZoomOnboardingIllustration()
        }
        .accessibilityIdentifier("explore-screen")
    }

    @ViewBuilder
    private var results: some View {
        switch model.layout {
        case .gallery:
            ExploreGallery(
                circles: model.visibleCircles,
                model: model,
                headerLayoutVersion: galleryHeaderLayoutVersion
            ) {
                scrollingHeader(horizontalPadding: ExploreLayoutMetrics.horizontalContentInset)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        case .list:
            ExploreList(circles: model.visibleCircles, model: model) {
                scrollingHeader(horizontalPadding: ExploreLayoutMetrics.horizontalContentInset)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func scrollingHeader(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            ExploreResultsHeader(
                visibleCount: model.visibleCircles.count,
                totalCount: model.selectedDayCircleCount,
                selectedGenre: model.genreFacets.first { $0.id == model.selectedGenreID }?.name,
                selectedTag: model.selectedTag,
                selectedShinagakiFilter: model.shinagakiFilter == .all
                    ? nil
                    : String(localized: model.shinagakiFilter.title),
                horizontalPadding: horizontalPadding,
                onClearGenre: { model.selectedGenreID = nil },
                onClearTag: { model.selectedTag = nil },
                onClearShinagaki: { model.shinagakiFilter = .all }
            )

            ExploreDiscoveryCloud(model: model, horizontalPadding: horizontalPadding)
        }
    }

    private var activeFilterCount: Int {
        (model.selectedGenreID == nil ? 0 : 1)
            + (model.selectedTag == nil ? 0 : 1)
            + model.selectedDiscoveryTermIDs.count
            + (model.shinagakiFilter == .all ? 0 : 1)
            + (model.favoriteFilter == .all ? 0 : 1)
            + (model.selectedFavoriteColors.isEmpty ? 0 : 1)
            + (model.attendanceFilter == .all ? 0 : 1)
            + (model.spaceFilter == .all ? 0 : 1)
    }

    private var galleryHeaderLayoutVersion: Int {
        let hasFilterChipRow = model.selectedGenreID != nil
            || model.selectedTag != nil
            || model.shinagakiFilter != .all
        let showsDiscoveryMatchMenu = model.selectedDiscoveryTermIDs.count > 1
        return (hasFilterChipRow ? 1 : 0) | (showsDiscoveryMatchMenu ? 2 : 0)
    }

    private var emptyMessage: String {
        if !model.searchQuery.isEmpty {
            return String(localized: "Try another search or clear a filter.")
        }
        return String(localized: "No circles match the selected filters and interests.")
    }

    private func presentGalleryZoomOnboardingIfNeeded() {
        guard model.layout == .gallery,
              !model.visibleCircles.isEmpty,
              !showsGalleryZoomOnboarding
        else { return }

        let arguments = ProcessInfo.processInfo.arguments
        let isForcedForUITesting = arguments.contains(
            "-cominavi-ui-testing-show-explore-onboarding"
        )
        let isSuppressedFixture = arguments.contains("-cominavi-demo-data")
            && !isForcedForUITesting
        guard !isSuppressedFixture,
              isForcedForUITesting
                || onboardingStore.shouldPresent(.exploreGalleryZoom)
        else { return }

        showsGalleryZoomOnboarding = true
    }

    private func completeGalleryZoomOnboarding() {
        onboardingStore.markCompleted(.exploreGalleryZoom)
    }
}

private struct ExploreLoadingScreen: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.accentColor)

            Text("Organizing circles…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Organizing circles…")
        .accessibilityIdentifier("explore-loading-screen")
    }
}

private struct ExploreSearchField: View {
    let model: ExploreModel

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            LucideIcon("magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                "Circle, creator, X handle, post, artwork text, or tag",
                text: $model.searchQuery
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityIdentifier("explore-search-field")

            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    LucideLabel("Clear search", icon: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("explore-search-clear-button")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
        .padding(.horizontal, ExploreLayoutMetrics.horizontalContentInset)
        .padding(.vertical, 12)
    }
}

private struct ExploreDiscoveryCloud: View {
    let model: ExploreModel
    let horizontalPadding: CGFloat

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Popular tags")
                        .font(.headline)
                    Text("Most-used tags for this day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if model.selectedDiscoveryTermIDs.count > 1 {
                    Menu {
                        Picker("Match tags", selection: $model.discoveryMatchMode) {
                            ForEach(ExploreDiscoveryMatchMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } label: {
                        LucideLabel(
                            resource: model.discoveryMatchMode.shortTitle,
                            icon: "slider.horizontal.3"
                        )
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Tag matching")
                    .accessibilityValue(Text(model.discoveryMatchMode.title))
                    .accessibilityIdentifier("explore-discovery-match-mode")
                }
            }
            .padding(.horizontal, horizontalPadding)

            if model.discoveryTerms.isEmpty, model.isDiscoveryLoading {
                ExploreDiscoverySkeleton(horizontalPadding: horizontalPadding)
            } else {
                ScrollView(.horizontal) {
                    HorizontalStaggeredLayout(spacing: 8) {
                        ForEach(model.discoveryTerms) { term in
                            ExploreDiscoveryTermButton(
                                term: term,
                                isSelected: model.selectedDiscoveryTermIDs.contains(term.id),
                                action: { model.toggleDiscoveryTerm(term.id) }
                            )
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                .scrollIndicators(.hidden)
                .frame(minHeight: 96)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Popular tags")
        .accessibilityIdentifier("explore-discovery-cloud")
    }
}

private struct ExploreDiscoverySkeleton: View {
    private struct Item: Identifiable, Sendable {
        let id: Int
        let width: CGFloat
    }

    private static let items = [
        Item(id: 0, width: 132),
        Item(id: 1, width: 104),
        Item(id: 2, width: 148),
        Item(id: 3, width: 118),
        Item(id: 4, width: 164),
        Item(id: 5, width: 96),
        Item(id: 6, width: 140),
        Item(id: 7, width: 110),
        Item(id: 8, width: 152),
        Item(id: 9, width: 122),
    ]

    let horizontalPadding: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            HorizontalStaggeredLayout(spacing: 8) {
                ForEach(Self.items) { item in
                    ExploreDiscoverySkeletonChip(width: item.width)
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .frame(minHeight: 96)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding popular tags…")
        .accessibilityIdentifier("explore-discovery-loading")
    }
}

private struct ExploreDiscoverySkeletonChip: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(uiColor: .quaternaryLabel))
                .frame(width: 16, height: 16)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color(uiColor: .quaternaryLabel))
                .frame(width: width - 56, height: 10)
        }
        .padding(.horizontal, 12)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 44, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: .capsule
        )
        .overlay {
            Capsule()
                .stroke(
                    Color(uiColor: .separator).opacity(0.14),
                    lineWidth: 0.5
                )
        }
    }
}

/// Two independent horizontal lanes for intrinsically-sized discovery chips.
/// Unlike `LazyHGrid`, a long label in one lane does not reserve the same
/// horizontal column width in the other lane.
private struct HorizontalStaggeredLayout: Layout {
    private struct Placement {
        let row: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Arrangement {
        let placements: [Placement]
        let firstRowHeight: CGFloat
        let size: CGSize
    }

    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(for: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrangement(for: subviews)
        let secondRowY = bounds.minY + arrangement.firstRowHeight + spacing

        for (subview, placement) in zip(subviews, arrangement.placements) {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.x,
                    y: placement.row == 0 ? bounds.minY : secondRowY
                ),
                anchor: UnitPoint.topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    private func arrangement(for subviews: Subviews) -> Arrangement {
        var rowWidths = [CGFloat.zero, .zero]
        var rowHeights = [CGFloat.zero, .zero]
        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let row = rowWidths[0] <= rowWidths[1] ? 0 : 1
            let x = rowWidths[row] == 0 ? 0 : rowWidths[row] + spacing
            placements.append(Placement(row: row, x: x, size: size))
            rowWidths[row] = x + size.width
            rowHeights[row] = max(rowHeights[row], size.height)
        }

        let hasSecondRow = rowHeights[1] > 0
        return Arrangement(
            placements: placements,
            firstRowHeight: rowHeights[0],
            size: CGSize(
                width: rowWidths.max() ?? 0,
                height: rowHeights[0] + (hasSecondRow ? spacing + rowHeights[1] : 0)
            )
        )
    }
}

private struct ExploreDiscoveryTermButton: View {
    let term: ExploreDiscoveryTerm
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideLabel(verbatim: term.title, icon: term.kind.systemImage)
                .font(font)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                    in: .capsule
                )
                .overlay {
                    if !isSelected {
                        Capsule()
                            .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(term.title)
        .accessibilityValue("\(term.kind.title), \(term.count) circles")
        .accessibilityHint(isSelected ? "Double tap to remove this tag" : "Double tap to filter by this tag")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("explore-discovery-term-\(term.id)")
    }

    private var font: Font {
        switch term.prominence {
        case 2: .headline
        case 1: .subheadline.weight(.semibold)
        default: .subheadline
        }
    }
}

private struct ExploreResultsHeader: View {
    let visibleCount: Int
    let totalCount: Int
    let selectedGenre: String?
    let selectedTag: String?
    let selectedShinagakiFilter: String?
    let horizontalPadding: CGFloat
    let onClearGenre: () -> Void
    let onClearTag: () -> Void
    let onClearShinagaki: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if visibleCount == totalCount {
                    Text("\(totalCount) circles")
                } else {
                    Text("\(visibleCount) of \(totalCount) circles")
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)

            if selectedGenre != nil || selectedTag != nil || selectedShinagakiFilter != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if let selectedGenre {
                            FilterChip(title: selectedGenre, systemImage: "theatermasks", onRemove: onClearGenre)
                        }
                        if let selectedTag {
                            FilterChip(title: selectedTag, systemImage: "tag", onRemove: onClearTag)
                        }
                        if let selectedShinagakiFilter {
                            FilterChip(
                                title: selectedShinagakiFilter,
                                systemImage: "doc.richtext",
                                onRemove: onClearShinagaki
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct FilterChip: View {
    let title: String
    let systemImage: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                LucideIcon(systemImage)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) filter")
    }
}

private struct ExploreGallery<Header: View>: View {
    let circles: [ExploreCircle]
    let model: ExploreModel
    let headerLayoutVersion: Int
    let header: Header
    @State private var selectedCircleID: Int?
    @State private var lightboxItem: ExploreArtworkLightboxItem?

    init(
        circles: [ExploreCircle],
        model: ExploreModel,
        headerLayoutVersion: Int,
        @ViewBuilder header: () -> Header
    ) {
        self.circles = circles
        self.model = model
        self.headerLayoutVersion = headerLayoutVersion
        self.header = header()
    }

    var body: some View {
        ExploreGalleryCollection(
            circles: circles,
            model: model,
            onSelect: { selectedCircleID = $0 },
            onLongPress: { circleID in openLightbox(circleID: circleID) },
            headerLayoutVersion: headerLayoutVersion,
            header: { header }
        )
        .navigationDestination(isPresented: Binding(
            get: { selectedCircleID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedCircleID = nil
                }
            }
        )) {
            if let selectedCircle, let dataSource = model.catalogDataSource {
                CircleDetailView(
                    circles: selectedCircle.circles,
                    dataSource: dataSource,
                    tags: selectedCircle.tags
                )
            }
        }
        .sheet(item: $lightboxItem) { item in
            ShinagakiLightbox(
                image: item.image,
                accessibilityLabel: String(localized: "Circle cover for \(item.circleName)")
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black)
        }
    }

    private var selectedCircle: ExploreCircle? {
        guard let selectedCircleID else { return nil }
        return circles.first { $0.id == selectedCircleID }
    }

    private func openLightbox(circleID: Int) {
        guard let circle = circles.first(where: { $0.id == circleID }) else { return }
        Task { @MainActor in
            guard let image = await model.fullCoverImage(for: circle) else { return }
            lightboxItem = ExploreArtworkLightboxItem(
                image: image,
                circleName: circle.displayName
            )
        }
    }
}

private struct ExploreArtworkLightboxItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let circleName: String
}

enum ExploreGalleryCardDetail: Equatable {
    case full
    case title
    case artworkOnly
}

struct ExploreGalleryCard: View {
    let circle: ExploreCircle
    let model: ExploreModel
    let artworkPixelSize: ExploreArtworkPixelSize
    var detail: ExploreGalleryCardDetail = .full

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExploreCircleArtwork(
                circle: circle,
                model: model,
                targetPixelSize: artworkPixelSize
            )

            if detail != .artworkOnly {
                VStack(alignment: .leading, spacing: 2) {
                    Text(circle.penName ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                        .opacity(circle.penName == nil ? 0 : 1)

                    Text(circle.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if detail == .full {
                        Text(circle.spaceLabel)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [circle.penName, circle.displayName, circle.spaceLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct ExploreList<Header: View>: View {
    let circles: [ExploreCircle]
    let model: ExploreModel
    let header: Header
    @State private var lightboxItem: ExploreArtworkLightboxItem?

    init(
        circles: [ExploreCircle],
        model: ExploreModel,
        @ViewBuilder header: () -> Header
    ) {
        self.circles = circles
        self.model = model
        self.header = header()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header

                ForEach(circles) { circle in
                    NavigationLink {
                        if let dataSource = model.catalogDataSource {
                            CircleDetailView(
                                circles: circle.circles,
                                dataSource: dataSource,
                                tags: circle.tags
                            )
                        }
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
                    .buttonStyle(CircleListRowButtonStyle())
                    .onLongPressGesture(minimumDuration: 0.45) {
                        openLightbox(circle)
                    }
                    .accessibilityIdentifier("explore-list-circle-\(circle.id)")

                    Divider()
                        .padding(.leading, ExploreLayoutMetrics.horizontalContentInset + artworkWidth + 12)
                }
            }
        }
        .accessibilityIdentifier("explore-list")
        .sheet(item: $lightboxItem) { item in
            ShinagakiLightbox(
                image: item.image,
                accessibilityLabel: String(localized: "Circle cover for \(item.circleName)")
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black)
        }
    }

    @ScaledMetric(relativeTo: .body)
    private var artworkWidth = ExploreLayoutMetrics.listArtworkWidth

    private func openLightbox(_ circle: ExploreCircle) {
        Task { @MainActor in
            guard let image = await model.fullCoverImage(for: circle) else { return }
            lightboxItem = ExploreArtworkLightboxItem(
                image: image,
                circleName: circle.displayName
            )
        }
    }
}

struct ExploreCircleRow: View {
    let circle: ExploreCircle
    let model: ExploreModel

    @ScaledMetric(relativeTo: .body)
    private var artworkWidth = ExploreLayoutMetrics.listArtworkWidth
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ExploreCircleArtwork(
                circle: circle,
                model: model,
                targetPixelSize: ExploreLayoutMetrics
                    .artworkPixelSize(
                        width: artworkWidth,
                        displayScale: displayScale
                    )
            )
                .frame(width: artworkWidth)

            VStack(alignment: .leading, spacing: 3) {
                if let penName = circle.penName {
                    Text(penName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(circle.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(circle.spaceLabel)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !circle.tags.isEmpty {
                    Text(circle.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                } else if let description = circle.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExploreCircleArtwork: View {
    let circle: ExploreCircle
    let model: ExploreModel
    let targetPixelSize: ExploreArtworkPixelSize

    @State private var loadedArtwork: LoadedExploreArtwork?
    @State private var didFinishLoading = false

    private var bookmarkColor: BookmarkColor? {
        model.bookmark(for: circle)?.color
    }

    private var isShowingShinagaki: Bool {
        loadedArtwork?.source == .shinagaki
    }

    private var borderStyle: ExploreArtworkBorderStyle {
        ExploreArtworkBorderStyle.resolve(
            isShowingShinagaki: isShowingShinagaki,
            bookmarkColor: bookmarkColor
        )
    }

    var body: some View {
        Group {
            if let loadedArtwork {
                FittedArtworkImage(image: loadedArtwork.image)
            } else {
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        if didFinishLoading {
                            LucideIcon("photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(
            ExploreLayoutMetrics.circleArtworkAspectRatio,
            contentMode: .fit
        )
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            switch borderStyle {
            case .favorite(let color):
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color.swiftUIColor, lineWidth: 2)
            case .none:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if isShowingShinagaki {
                LucideIcon("doc.richtext.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: .circle)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if !isShowingShinagaki {
                CircleFavoriteMark(color: bookmarkColor)
            }
        }
        .task(id: artworkTaskID) {
            loadedArtwork = nil
            didFinishLoading = false
            let cover = await model.coverImage(
                for: circle,
                targetPixelSize: targetPixelSize
            )
            guard !Task.isCancelled else { return }
            let decodedImage = await Image.asyncInit(data: cover?.data)
            guard !Task.isCancelled else { return }
            loadedArtwork = cover.flatMap { cover in
                decodedImage.map {
                    LoadedExploreArtwork(image: $0, source: cover.source)
                }
            }
            didFinishLoading = true
        }
        .accessibilityHidden(true)
    }

    private var artworkTaskID: String {
        "cover-\(circle.id)-\(circle.preferredCoverURL?.absoluteString ?? "circle")-\(targetPixelSize.cacheKey)"
    }
}

enum ExploreArtworkBorderStyle: Equatable {
    case none
    case favorite(BookmarkColor)

    static func resolve(
        isShowingShinagaki: Bool,
        bookmarkColor: BookmarkColor?
    ) -> ExploreArtworkBorderStyle {
        if isShowingShinagaki, let bookmarkColor, bookmarkColor.isFavorite {
            return .favorite(bookmarkColor)
        }
        return .none
    }
}

private struct LoadedExploreArtwork {
    let image: Image
    let source: ExploreCoverSource
}

private struct ExploreFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: ExploreModel

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Picker("Genre", selection: $model.selectedGenreID) {
                        Text("All genres").tag(Int?.none)
                        ForEach(model.genreFacets) { genre in
                            Text("\(genre.name) (\(genre.count))").tag(Int?.some(genre.id))
                        }
                    }
                    .accessibilityIdentifier("explore-genre-picker")

                    Picker("Tag", selection: $model.selectedTag) {
                        Text("All tags").tag(String?.none)
                        ForEach(model.tagFacets) { tag in
                            Text("\(tag.name) (\(tag.count))").tag(String?.some(tag.name))
                        }
                    }
                    .disabled(model.tagFacets.isEmpty)
                    .accessibilityIdentifier("explore-tag-picker")

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
                    switch model.tagState {
                    case .idle, .loading:
                        Text("Loading Circle.ms tags…")
                    case .unavailable:
                        Text("Some tags are unavailable right now.")
                    case .ready:
                        EmptyView()
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

                    ExploreFavoriteColorFilter(selection: $model.selectedFavoriteColors)
                }
            }
            .navigationTitle("Filter circles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.selectedGenreID != nil
                        || model.selectedTag != nil
                        || model.shinagakiFilter != .all
                        || model.favoriteFilter != .all
                        || !model.selectedFavoriteColors.isEmpty
                        || model.attendanceFilter != .all
                        || model.spaceFilter != .all
                    {
                        Button("Clear") {
                            model.clearFilters()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.92), .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("explore-filter-sheet")
    }
}
