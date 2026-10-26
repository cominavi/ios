import Observation
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

private struct ExploreCircleNavigationDestination<Destination: View>: ViewModifier {
    @Binding var selection: ExploreCircle?
    let destination: (ExploreCircle) -> Destination

    func body(content: Content) -> some View {
        content.navigationDestination(isPresented: Binding(
            get: { selection != nil },
            set: { isPresented in
                if !isPresented {
                    selection = nil
                }
            }
        )) {
            if let selection {
                destination(selection)
            }
        }
    }
}

extension View {
    func exploreCircleDestination<Destination: View>(
        selection: Binding<ExploreCircle?>,
        @ViewBuilder destination: @escaping (ExploreCircle) -> Destination
    ) -> some View {
        modifier(
            ExploreCircleNavigationDestination(
                selection: selection,
                destination: destination
            )
        )
    }
}

struct ExploreView<EventDayHeader: View>: View {
    @Binding private var selectedDay: Int
    @State private var model: ExploreModel
    @State private var selectedCircle: ExploreCircle?
    @State private var showsFilters = false
    @State private var showsGalleryZoomOnboarding = false
    private let eventDayHeader: EventDayHeader
    private let onboardingStore: FeatureOnboardingStore
    private let favoriteColorLabelStore: FavoriteColorLabelStore

    init(
        dataSource: CirclemsDataSource,
        selectedDay: Binding<Int>,
        onboardingDefaults: UserDefaults = .standard,
        favoriteColorLabelStore: FavoriteColorLabelStore =
            AppData.favoriteColorLabelStore,
        @ViewBuilder eventDayHeader: () -> EventDayHeader
    ) {
        _selectedDay = selectedDay
        _model = State(initialValue: ExploreModel(
            dataSource: dataSource,
            selectedDay: selectedDay.wrappedValue
        ))
        onboardingStore = FeatureOnboardingStore(defaults: onboardingDefaults)
        self.favoriteColorLabelStore = favoriteColorLabelStore
        self.eventDayHeader = eventDayHeader()
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
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
            // The system search field collapses into the navigation bar on
            // scroll, which a fixed row above the gallery never did.
            .searchable(
                text: $model.searchQuery,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("Search circles, creators, tags")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
                        ExploreFilterButtonLabel(activeFilterCount: activeFilterCount)
                    }
                    .accessibilityLabel(
                        ExploreFilterButtonLabel.accessibilityLabel(for: activeFilterCount)
                    )
                    .accessibilityIdentifier("explore-filter-button")
                    .id(activeFilterCount)

                    // Layout and sort are both "how results look", so they
                    // share one labeled menu instead of two ambiguous glyphs.
                    Menu {
                        Picker("Layout", selection: $model.layout) {
                            ForEach(ExploreLayout.allCases) { layout in
                                LucideLabel(verbatim: layout.title, icon: layout.systemImage)
                                    .tag(layout)
                            }
                        }
                        .pickerStyle(.inline)

                        ExploreSortPicker(selection: $model.sort)
                            .pickerStyle(.inline)
                    } label: {
                        LucideLabel("View options", icon: "slider.horizontal.3")
                    }
                    .accessibilityLabel(
                        Text("View options, \(model.layout.title), \(Text(model.sort.title))")
                    )
                    .accessibilityIdentifier("explore-view-options-button")
                }
            }
            .sheet(isPresented: $showsFilters) {
                ExploreFilterSheet(
                    model: model,
                    favoriteColorLabelStore: favoriteColorLabelStore
                )
            }
            .exploreCircleDestination(selection: $selectedCircle) { circle in
                if let dataSource = model.catalogDataSource {
                    CircleDetailView(
                        circles: circle.circles,
                        dataSource: dataSource,
                        tags: circle.tags,
                        favoriteColorLabelStore: favoriteColorLabelStore
                    )
                }
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
                favoriteColorLabels: favoriteColorLabelStore.customLabels,
                headerLayoutVersion: galleryHeaderLayoutVersion,
                onSelect: { selectedCircle = $0 }
            ) {
                scrollingHeader(horizontalPadding: ExploreLayoutMetrics.horizontalContentInset)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        case .list:
            ExploreList(
                circles: model.visibleCircles,
                model: model,
                favoriteColorLabels: favoriteColorLabelStore.customLabels,
                onSelect: { selectedCircle = $0 }
            ) {
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
                activeFilters: model.activeFilters,
                horizontalPadding: horizontalPadding,
                onRemove: { model.clear($0) },
                onClearAll: { model.clearFilters() }
            )

            ExploreDiscoveryCloud(model: model, horizontalPadding: horizontalPadding)
        }
    }

    private var activeFilterCount: Int {
        model.activeFilters.count
    }

    private var galleryHeaderLayoutVersion: Int {
        let hasFilterChipRow = activeFilterCount > 0
        let showsDiscoveryMatchMenu = model.selectedDiscoveryTermIDs.count > 1
        let showsDiscoveryCloud = ExploreDiscoveryCloud.hasContent(model)
        return (hasFilterChipRow ? 1 : 0)
            | (showsDiscoveryMatchMenu ? 2 : 0)
            | (showsDiscoveryCloud ? 4 : 0)
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

/// Static placeholder cards in the same grid shape as the gallery, so the
/// first load reads as "circles are on the way" instead of a separate screen.
private struct ExploreLoadingScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: horizontalSizeClass == .compact ? 2 : 4
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(0..<12, id: \.self) { _ in
                    ExploreSkeletonCard()
                }
            }
            .padding(.horizontal, ExploreLayoutMetrics.horizontalContentInset)
            .padding(.top, 12)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading circles…")
        .accessibilityIdentifier("explore-loading-screen")
    }
}

private struct ExploreSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemFill))
                .aspectRatio(
                    ExploreLayoutMetrics.circleArtworkAspectRatio,
                    contentMode: .fit
                )

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .quaternaryLabel))
                    .frame(height: 10)
                    .padding(.trailing, 24)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .quaternaryLabel))
                    .frame(width: 48, height: 10)
            }
        }
    }
}

private struct ExploreDiscoveryCloud: View {
    let model: ExploreModel
    let horizontalPadding: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The demo and App Review catalogs ship without enrichment, so they never
    /// produce tags. Hide the whole section, header included, instead of
    /// leaving a titled empty band above the results.
    static func hasContent(_ model: ExploreModel) -> Bool {
        model.isDiscoveryLoading || !model.discoveryTerms.isEmpty
    }

    /// Compact widths get one lane so the cloud does not push the first row
    /// of circles below the fold; wider layouts keep two staggered lanes.
    private var laneCount: Int {
        horizontalSizeClass == .compact ? 1 : 2
    }

    var body: some View {
        @Bindable var model = model

        if Self.hasContent(model) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Popular tags")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
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

                if model.discoveryTerms.isEmpty {
                    ExploreDiscoverySkeleton(
                        laneCount: laneCount,
                        horizontalPadding: horizontalPadding
                    )
                } else {
                    ScrollView(.horizontal) {
                        HorizontalStaggeredLayout(laneCount: laneCount, spacing: 8) {
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
                    .frame(minHeight: ExploreDiscoveryMetrics.height(laneCount: laneCount))
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .background(Color(uiColor: .systemBackground))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore-discovery-cloud")
        }
    }
}

private enum ExploreDiscoveryMetrics {
    static let chipHeight: CGFloat = 44
    static let laneSpacing: CGFloat = 8

    static func height(laneCount: Int) -> CGFloat {
        let lanes = CGFloat(max(laneCount, 1))
        return chipHeight * lanes + laneSpacing * (lanes - 1)
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

    let laneCount: Int
    let horizontalPadding: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            HorizontalStaggeredLayout(laneCount: laneCount, spacing: 8) {
                ForEach(Self.items) { item in
                    ExploreDiscoverySkeletonChip(width: item.width)
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .frame(minHeight: ExploreDiscoveryMetrics.height(laneCount: laneCount))
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

/// Independent horizontal lanes for intrinsically-sized discovery chips.
/// Unlike `LazyHGrid`, a long label in one lane does not reserve the same
/// horizontal column width in the other lanes.
private struct HorizontalStaggeredLayout: Layout {
    private struct Placement {
        let lane: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Arrangement {
        let placements: [Placement]
        let laneOffsets: [CGFloat]
        let size: CGSize
    }

    let laneCount: Int
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

        for (subview, placement) in zip(subviews, arrangement.placements) {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.x,
                    y: bounds.minY + arrangement.laneOffsets[placement.lane]
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
        let lanes = max(laneCount, 1)
        var laneWidths = Array(repeating: CGFloat.zero, count: lanes)
        var laneHeights = Array(repeating: CGFloat.zero, count: lanes)
        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // Fill the shortest lane so lanes stay balanced in width.
            let lane = laneWidths.indices.min { laneWidths[$0] < laneWidths[$1] } ?? 0
            let x = laneWidths[lane] == 0 ? 0 : laneWidths[lane] + spacing
            placements.append(Placement(lane: lane, x: x, size: size))
            laneWidths[lane] = x + size.width
            laneHeights[lane] = max(laneHeights[lane], size.height)
        }

        var laneOffsets: [CGFloat] = []
        var height: CGFloat = 0
        for laneHeight in laneHeights {
            laneOffsets.append(height == 0 ? 0 : height + spacing)
            if laneHeight > 0 {
                height = (height == 0 ? 0 : height + spacing) + laneHeight
            }
        }
        return Arrangement(
            placements: placements,
            laneOffsets: laneOffsets,
            size: CGSize(width: laneWidths.max() ?? 0, height: height)
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
        .accessibilityValue("\(term.count) circles")
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
    let activeFilters: [ExploreActiveFilter]
    let horizontalPadding: CGFloat
    let onRemove: (ExploreActiveFilterKind) -> Void
    let onClearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Group {
                    if visibleCount == totalCount {
                        Text("\(totalCount) circles")
                    } else {
                        Text("\(visibleCount) of \(totalCount) circles")
                    }
                }
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.trailing, activeFilters.isEmpty ? 0 : 4)

                ForEach(activeFilters) { filter in
                    FilterChip(
                        title: filter.title,
                        systemImage: filter.systemImage,
                        onRemove: { onRemove(filter.kind) }
                    )
                }

                if activeFilters.count > 1 {
                    Button("Clear all", action: onClearAll)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("explore-clear-all-filters")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, horizontalPadding)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 6)
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
            HStack(spacing: 6) {
                LucideIcon(systemImage)
                Text(title)
                    .lineLimit(1)
                LucideIcon("xmark", size: 12)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) filter")
    }
}

/// Filter glyph with a visible count, matching the tag page. The state is part
/// of the label so VoiceOver reads it even where `accessibilityValue` is dropped.
struct ExploreFilterButtonLabel: View {
    let activeFilterCount: Int

    var body: some View {
        HStack(spacing: 5) {
            LucideIcon("line.3.horizontal.decrease")
            if activeFilterCount > 0 {
                Text(activeFilterCount, format: .number)
                    .font(.caption.monospacedDigit().weight(.bold))
            }
        }
    }

    static func accessibilityLabel(for activeFilterCount: Int) -> Text {
        activeFilterCount == 0
            ? Text("Filter")
            : Text("Filter, \(activeFilterCount) active")
    }
}

#if DEBUG
    struct ExploreLongPressUITestHost: View {
        private enum Surface: String, CaseIterable, Identifiable {
            case gallery
            case list
            case tag

            var id: Self { self }

            var title: String {
                rawValue.capitalized
            }
        }

        @State private var selectedSurface = Surface.gallery
        @State private var model: ExploreModel
        @State private var visibleCircles: [ExploreCircle]
        @State private var selectedCircle: ExploreCircle?

        init() {
            let circle = Self.makeCircle()
            _model = State(initialValue: ExploreModel(
                circles: [circle],
                selectedDay: 2
            ))
            _visibleCircles = State(initialValue: [circle])
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    Text("Explore multi-post fixture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("explore-longpress-fixture-title")
                        .padding(.top, 8)

                    HStack(spacing: 8) {
                        ForEach(Surface.allCases) { surface in
                            Button(surface.title) {
                                selectedSurface = surface
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedSurface == surface ? .accentColor : .secondary)
                            .accessibilityAddTraits(
                                selectedSurface == surface ? .isSelected : []
                            )
                            .accessibilityIdentifier(
                                "explore-longpress-surface-\(surface.rawValue)"
                            )
                        }
                    }
                    .padding(8)

                    Divider()

                    switch selectedSurface {
                    case .gallery:
                        ExploreGallery(
                            circles: visibleCircles,
                            model: model,
                            favoriteColorLabels: [:],
                            headerLayoutVersion: 0,
                            onSelect: { selectedCircle = $0 }
                        ) {
                            EmptyView()
                        }
                    case .list:
                        ExploreList(
                            circles: visibleCircles,
                            model: model,
                            favoriteColorLabels: [:],
                            onSelect: { selectedCircle = $0 }
                        ) {
                            EmptyView()
                        }
                    case .tag:
                        if let visibleCircle = visibleCircles.first {
                            ExploreTagLongPressUITestSurface(
                                circle: visibleCircle,
                                model: model,
                                onSelect: { selectedCircle = $0 }
                            )
                        }
                    }
                }
                .navigationTitle("Long-press fixture")
                .navigationBarTitleDisplayMode(.inline)
                .exploreCircleDestination(selection: $selectedCircle) { circle in
                    VStack(spacing: 20) {
                        Text(circle.displayName)
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("explore-filtered-detail")

                        Button("Remove from Saved Only results") {
                            visibleCircles.removeAll()
                        }
                        .accessibilityIdentifier("explore-filtered-detail-remove-result")
                    }
                    .navigationTitle(circle.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }

        private static func makeCircle() -> ExploreCircle {
            let posts = [
                makePost(
                    id: "ui-test-post-one",
                    mediaPath: "post-one.jpg",
                    createdAt: Date(timeIntervalSince1970: 100)
                ),
                makePost(
                    id: "ui-test-post-two",
                    mediaPath: "post-two.jpg",
                    createdAt: Date(timeIntervalSince1970: 200)
                ),
            ]
            return ExploreCircle(
                circle: CirclemsDataSchema.ComiketCircleWC(
                    comiketNo: 108,
                    id: 10_802_055,
                    pageNo: 1,
                    cutIndex: 1,
                    day: 2,
                    blockId: 1,
                    spaceNo: 55,
                    spaceNoSub: 0,
                    genreId: 1,
                    circleName: "Two Post Circle",
                    circleKana: "TWO POST CIRCLE",
                    penName: "UI Test Artist",
                    bookName: nil,
                    url: nil,
                    mailAddr: nil,
                    description: "Deterministic Explore long-press fixture",
                    memo: nil,
                    updateId: 10_802_055,
                    updateData: nil,
                    circlems: nil,
                    rss: nil,
                    updateFlag: nil
                ),
                genreName: "UI Test",
                blockName: "A",
                tags: ["UI Test"],
                enrichment: CatalogCircleEnrichment(posts: posts)
            )
        }

        private static func makePost(
            id: String,
            mediaPath: String,
            createdAt: Date
        ) -> CatalogShinagakiPost {
            CatalogShinagakiPost(
                id: id,
                postURL: testURL("\(id).html"),
                text: "Two-post Explore fixture",
                createdAt: createdAt,
                authorHandle: "cominavi_ui_test",
                authorName: "ComiNavi UI Test",
                authorBio: nil,
                authorProfileImageURL: nil,
                media: [
                    CatalogShinagakiMedia(
                        kind: .photo,
                        url: testURL(mediaPath),
                        previewURL: nil
                    ),
                ],
                tags: [],
                postConfidence: .high,
                placementConfidence: .high,
                matchScore: 1_000,
                matchReasons: ["ui-test"]
            )
        }

        private static func testURL(_ path: String) -> URL {
            URL(string: "https://ui-test.invalid/\(path)")!
        }
    }
#endif

private struct ExploreGallery<Header: View>: View {
    let circles: [ExploreCircle]
    let model: ExploreModel
    let favoriteColorLabels: [BookmarkColor: String]
    let headerLayoutVersion: Int
    let onSelect: (ExploreCircle) -> Void
    let header: Header
    @State private var lightboxController = ExploreArtworkLightboxController()

    init(
        circles: [ExploreCircle],
        model: ExploreModel,
        favoriteColorLabels: [BookmarkColor: String],
        headerLayoutVersion: Int,
        onSelect: @escaping (ExploreCircle) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        self.circles = circles
        self.model = model
        self.favoriteColorLabels = favoriteColorLabels
        self.headerLayoutVersion = headerLayoutVersion
        self.onSelect = onSelect
        self.header = header()
    }

    var body: some View {
        @Bindable var lightboxController = lightboxController

        ExploreGalleryCollection(
            circles: circles,
            model: model,
            favoriteColorLabels: favoriteColorLabels,
            onSelect: { circleID in
                guard let circle = circles.first(where: { $0.id == circleID }) else { return }
                onSelect(circle)
            },
            onLongPress: { circleID in openLightbox(circleID: circleID) },
            headerLayoutVersion: headerLayoutVersion,
            header: { header }
        )
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

    private func openLightbox(circleID: Int) {
        guard let circle = circles.first(where: { $0.id == circleID }) else { return }
        lightboxController.present(circle: circle) {
            await model.fullCoverImage(for: circle)
        }
    }
}

@MainActor
@Observable
final class ExploreArtworkLightboxController {
    var presentation: ShinagakiLightboxPresentation?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func present(
        circle: ExploreCircle,
        loadFallbackImage: @escaping @MainActor () async -> UIImage?
    ) {
        cancelPendingLoad()

        if let shinagakiPresentation = circle.shinagakiLightboxPresentation {
            presentation = shinagakiPresentation
            return
        }

        presentation = nil
        loadTask = Task { [weak self] in
            let image = await loadFallbackImage()
            guard !Task.isCancelled, let self, let image else { return }
            let page = ShinagakiLightboxPage(
                id: "circle-\(circle.id)-cover",
                image: image,
                accessibilityLabel: String(
                    localized: "Circle cover for \(circle.displayName)"
                )
            )
            presentation = ShinagakiLightboxPresentation(
                pages: [page],
                selectedPageID: page.id
            )
            loadTask = nil
        }
    }

    func cancelPendingLoad() {
        loadTask?.cancel()
        loadTask = nil
    }
}

extension ExploreCircle {
    var shinagakiLightboxPresentation: ShinagakiLightboxPresentation? {
        struct PageSource {
            let id: String
            let media: CatalogShinagakiMedia
        }

        guard let enrichment else { return nil }
        let sources = enrichment.posts.flatMap { post in
            post.media.enumerated().compactMap { index, media -> PageSource? in
                guard media.kind != .video || media.previewURL != nil else { return nil }
                return PageSource(
                    id: "\(post.id)-media-\(index)",
                    media: media
                )
            }
        }
        guard !sources.isEmpty else { return nil }

        let context = String(localized: "Circle cover for \(displayName)")
        let pages = sources.enumerated().map { index, source in
            ShinagakiLightboxPage(
                id: source.id,
                media: source.media,
                accessibilityLabel: String(
                    localized: "Image \(index + 1) of \(sources.count): \(context)",
                    comment: "Accessibility label for one image in a multi-image Shinagaki post."
                )
            )
        }
        let preferredURL = preferredCoverURL
        let selectedPageID = zip(sources, pages).first { source, _ in
            source.media.displayURL == preferredURL
                || source.media.url == preferredURL
        }?.1.id ?? pages[0].id
        return ShinagakiLightboxPresentation(
            pages: pages,
            selectedPageID: selectedPageID
        )
    }
}

enum ExploreGalleryCardDetail: Equatable {
    case full
    case title
    case artworkOnly
}

struct ExploreGalleryCard: View {
    let circle: ExploreCircle
    let model: ExploreModel
    let favoriteColorLabels: [BookmarkColor: String]
    let artworkPixelSize: ExploreArtworkPixelSize
    var detail: ExploreGalleryCardDetail = .full
    /// VoiceOver paths for the cell's tap and long-press gestures, which live
    /// on the hosting collection view and are invisible to assistive tech.
    var onOpen: (() -> Void)?
    var onViewArtwork: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExploreCircleArtwork(
                circle: circle,
                model: model,
                targetPixelSize: artworkPixelSize
            )

            if detail != .artworkOnly {
                VStack(alignment: .leading, spacing: 2) {
                    // Narrow cards drop the pen name first; the space code is
                    // what an attendee needs to walk to the circle.
                    if detail == .full {
                        Text(circle.penName ?? " ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1, reservesSpace: true)
                            .opacity(circle.penName == nil ? 0 : 1)
                    }

                    Text(circle.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        Text(circle.spaceLabel)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 0)

                        favoriteLabel
                    }
                    .frame(minHeight: FavoriteColorLabelMetrics.baseHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens circle details")
        .accessibilityAction {
            onOpen?()
        }
        .accessibilityActions {
            if let onViewArtwork {
                Button("View artwork", action: onViewArtwork)
            }
        }
    }

    private var accessibilityLabel: String {
        [circle.penName, circle.displayName, circle.spaceLabel, favoriteAccessibilityLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var favoriteLabel: some View {
        if let bookmark = model.bookmark(for: circle), bookmark.isFavorite {
            FavoriteColorLabelBadge(
                color: bookmark.color,
                label: favoriteColorLabels[bookmark.color]
            )
        }
    }

    private var favoriteAccessibilityLabel: String? {
        guard let bookmark = model.bookmark(for: circle), bookmark.isFavorite else {
            return nil
        }
        return favoriteColorLabels[bookmark.color]
            ?? String(localized: bookmark.color.displayName)
    }
}

private struct ExploreList<Header: View>: View {
    let circles: [ExploreCircle]
    let model: ExploreModel
    let favoriteColorLabels: [BookmarkColor: String]
    let onSelect: (ExploreCircle) -> Void
    let header: Header
    @State private var lightboxController = ExploreArtworkLightboxController()

    init(
        circles: [ExploreCircle],
        model: ExploreModel,
        favoriteColorLabels: [BookmarkColor: String],
        onSelect: @escaping (ExploreCircle) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        self.circles = circles
        self.model = model
        self.favoriteColorLabels = favoriteColorLabels
        self.onSelect = onSelect
        self.header = header()
    }

    var body: some View {
        @Bindable var lightboxController = lightboxController

        ScrollView {
            LazyVStack(spacing: 0) {
                header

                ForEach(circles) { circle in
                    Button {
                        onSelect(circle)
                    } label: {
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
                    .buttonStyle(CircleListRowButtonStyle())
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in openLightbox(circle) }
                    )
                    .accessibilityIdentifier("explore-list-circle-\(circle.id)")

                    Divider()
                        .padding(.leading, ExploreLayoutMetrics.horizontalContentInset + artworkWidth + 12)
                }
            }
        }
        .accessibilityIdentifier("explore-list")
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

    @ScaledMetric(relativeTo: .body)
    private var artworkWidth = ExploreLayoutMetrics.listArtworkWidth

    private func openLightbox(_ circle: ExploreCircle) {
        lightboxController.present(circle: circle) {
            await model.fullCoverImage(for: circle)
        }
    }
}

struct ExploreCircleRow: View {
    let circle: ExploreCircle
    let model: ExploreModel
    let favoriteColorLabels: [BookmarkColor: String]

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

                HStack(spacing: 6) {
                    Text(circle.spaceLabel)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 0)

                    if let bookmark = model.bookmark(for: circle), bookmark.isFavorite {
                        FavoriteColorLabelBadge(
                            color: bookmark.color,
                            label: favoriteColorLabels[bookmark.color]
                        )
                    }
                }
                .frame(minHeight: FavoriteColorLabelMetrics.baseHeight)

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
                        // The plain fill is the loading state; only a failed
                        // load gets a glyph.
                        if didFinishLoading {
                            LucideIcon("photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
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
