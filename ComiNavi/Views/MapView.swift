import SwiftUI
import UIKit

struct MapView: View {
    private static let currentLocationSheetHeight: CGFloat = 430

    @State private var model: MapScreenModel
    @State private var showsWhereAmI = false
    @State private var showsWhereToGo = false
    @State private var showsCurrentLocation = false
    @State private var opensWhereAmIAfterSheet = false
    @State private var isMapLegendExpanded = true
    @State private var visibleMapLayers = BigSightMapLayer.defaultVisible
    @Binding private var selectedDay: Int

    private var currentLocationMapBottomInset: CGFloat {
        showsCurrentLocation ? Self.currentLocationSheetHeight : 0
    }

    @MainActor
    init(
        dataSource: CirclemsDataSource,
        selectedDay: Binding<Int>
    ) {
        let model = MapScreenModel(
            days: dataSource.comiket.days,
            eventNumber: dataSource.comiket.number,
            selectedDay: selectedDay.wrappedValue,
            catalog: dataSource.mapCatalog,
            detailArtworkLoader: CircleDetailArtworkLoader(
                eventID: dataSource.eventID,
                eventNumber: dataSource.comiket.number
            ),
            userPlanStore: dataSource.userPlanStore,
            bookmarkSyncCoordinator: dataSource.bookmarkSyncCoordinator
        )
        _model = State(initialValue: model)
        _selectedDay = selectedDay
    }

    @MainActor
    init(model: MapScreenModel) {
        _model = State(initialValue: model)
        _selectedDay = .constant(model.selectedDay)
    }

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .top) {
            mapContent
                .ignoresSafeArea()

            MapControlPanel(
                model: model,
                visibleMapLayers: $visibleMapLayers,
                onWhereAmI: {
                    if model.locatedUser != nil {
                        showsCurrentLocation = true
                    } else {
                        showsWhereAmI = true
                    }
                },
                onUpdateLocation: {
                    showsWhereAmI = true
                },
                onWhereToGo: {
                    showsWhereToGo = true
                },
                onClearDestination: {
                    model.clearNavigationDestination()
                }
            )
                .padding(.horizontal, 14)
                .safeAreaPadding(.top, 8)

            if model.phase == .ready, model.scope == .venue, model.showsGenreOverlay {
                MapLegendView(
                    genrePlacements: model.genrePlacements,
                    isExpanded: $isMapLegendExpanded
                )
                .padding(.trailing, MapChromeLayout.trailingInset)
                .safeAreaPadding(.bottom, 78)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .background(Color(white: 0.94))
        .task {
            if model.scene == nil, model.campusScene == nil {
                model.load()
            }
        }
        .onChange(of: selectedDay, initial: true) { _, day in
            if model.selectedDay != day {
                model.select(day: day)
            }
        }
        .onChange(of: model.selectedDay) { _, day in
            if selectedDay != day {
                selectedDay = day
            }
        }
        .sheet(item: $model.selection) { selection in
            CircleMapDetailSheet(
                selection: selection,
                bookmark: model.bookmark(for: selection.selectedCircle),
                isMutatingBookmark: model.isMutatingBookmark,
                isSyncingBookmark: model.isSyncingBookmarks,
                bookmarkError: model.bookmarkError,
                onSelectCircle: model.select(circle:),
                onToggleBookmark: model.toggleBookmark,
                onSetBookmarkColor: model.setBookmarkColor
            )
            .presentationDetents([.height(300), .medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsCurrentLocation, onDismiss: {
            guard opensWhereAmIAfterSheet else { return }
            opensWhereAmIAfterSheet = false
            showsWhereAmI = true
        }) {
            if let location = model.locatedUser {
                CurrentLocationSheet(location: location) {
                    opensWhereAmIAfterSheet = true
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsWhereAmI, onDismiss: {
            if model.locatedUser != nil {
                showsCurrentLocation = true
            }
        }) {
            WhereAmIView(
                mapModel: model,
                locationService: makeWhereAmILocationService()
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsWhereToGo) {
            WhereToGoView(mapModel: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var mapContent: some View {
        ZStack {
            if let campus = model.campusScene {
                UnifiedBigSightMapView(
                    campus: campus,
                    scope: model.scope,
                    selectedMapID: model.selectedMapID,
                    selectedTableID: model.selection?.table.id,
                    circlePlacements: model.visibleCirclePlacements,
                    circleArtwork: model.visibleCircleArtwork,
                    searchMatches: model.searchMatches,
                    searchActive: !model.searchQuery.isEmpty,
                    genrePlacements: model.genrePlacements,
                    bookmarks: Array(model.bookmarks.values),
                    locatedUser: model.locatedUser,
                    navigationDestination: model.navigationDestination,
                    navigationRoute: model.navigationRoute,
                    visibleMapLayers: visibleMapLayers,
                    locationFocusBottomInset: currentLocationMapBottomInset,
                    onViewportChange: model.updateViewport,
                    onSelectVenue: model.select(mapID:),
                    onShowCampus: model.showCampus,
                    onSelectTable: model.select(table:preferredSubspace:),
                    onSelectLocatedUser: {
                        showsCurrentLocation = true
                    },
                    onLocate: { mapID, point, table, subspace in
                        if model.locateUser(
                            at: point,
                            nearest: table,
                            subspace: subspace,
                            mapID: mapID
                        ) != nil {
                            showsCurrentLocation = true
                        }
                    }
                )
                .allowsHitTesting(model.phase == .ready)
            } else if let scene = model.scene {
                InteractiveMapCanvas(
                    scene: scene,
                    selectedTableID: model.selection?.table.id,
                    circlePlacements: model.visibleCirclePlacements,
                    circleArtwork: model.visibleCircleArtwork,
                    searchMatches: model.searchMatches,
                    searchActive: !model.searchQuery.isEmpty,
                    genrePlacements: model.genrePlacements,
                    bookmarks: Array(model.bookmarks.values),
                    locatedUser: model.locatedUser,
                    locationFocusBottomInset: currentLocationMapBottomInset,
                    onViewportChange: model.updateViewport,
                    onSelect: model.select(table:preferredSubspace:),
                    onSelectLocatedUser: {
                        showsCurrentLocation = true
                    },
                    onLocate: { point, table, subspace in
                        if model.locateUser(
                            at: point,
                            nearest: table,
                            subspace: subspace
                        ) != nil {
                            showsCurrentLocation = true
                        }
                    }
                )
                .allowsHitTesting(model.phase == .ready)
            } else if case .failed(let message) = model.phase {
                ContentUnavailableView(
                    "Map unavailable",
                    systemImage: "map.fill",
                    description: Text(message)
                )
            } else {
                MapLoadingView(
                    message: model.scope == .campus ? "Loading campus…" : "Loading venue…"
                )
            }

            if model.phase == .loading,
               model.campusScene != nil || model.scene != nil
            {
                MapRefreshIndicator(
                    message: model.scope == .campus ? "Updating campus…" : "Updating venue…"
                )
            }
        }
    }

    @MainActor
    private func makeWhereAmILocationService() -> WhereAmILocationService {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-where-am-i") {
            return WhereAmILocationService(
                simulatedReading: WhereAmILocationReading(
                    coordinate: BigSightCampusLayout.eastBuilding,
                    horizontalAccuracy: 12,
                    timestamp: .now
                ),
                simulatedHeading: 72
            )
        }
        #endif
        return WhereAmILocationService()
    }
}

private struct MapControlPanel: View {
    let model: MapScreenModel
    @Binding var visibleMapLayers: Set<BigSightMapLayer>
    let onWhereAmI: () -> Void
    let onUpdateLocation: () -> Void
    let onWhereToGo: () -> Void
    let onClearDestination: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            MapSelectorBar(model: model, visibleMapLayers: $visibleMapLayers)
            WhereAmIEntryButton(
                location: model.locatedUser,
                action: onWhereAmI,
                updateAction: onUpdateLocation
            )
            WhereToGoEntryButton(
                destination: model.navigationDestination,
                route: model.navigationRoute,
                hasCurrentLocation: model.locatedUser != nil,
                action: onWhereToGo,
                clearAction: onClearDestination
            )
            if model.isSearchPresented {
                MapSearchField(model: model)
            }
        }
    }
}

private struct WhereToGoEntryButton: View {
    let destination: MapNavigationDestination?
    let route: BigSightNavigationRoute?
    let hasCurrentLocation: Bool
    let action: () -> Void
    let clearAction: () -> Void

    @ScaledMetric(relativeTo: .headline) private var minimumHeight = 58.0

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            destination.map { String(localized: "Going to \($0.spaceCode)") }
                                ?? String(localized: "Where do you want to go?")
                        )
                        .font(.headline)
                        .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 18)
                .padding(.trailing, destination == nil ? 18 : 12)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a destination using its Comiket address")
            .accessibilityIdentifier("where-to-button")

            if destination != nil {
                Divider()
                    .frame(height: 34)

                Button(action: clearAction) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .frame(width: 56, height: minimumHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination")
                .accessibilityIdentifier("clear-destination-button")
            }
        }
        .background(Color(uiColor: .systemBackground).opacity(0.94))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }

    private var subtitle: String {
        guard destination != nil else {
            return String(localized: "Enter a Comiket table address")
        }
        guard hasCurrentLocation else {
            return String(localized: "Set your current location to build the route")
        }
        guard let route else {
            return String(localized: "Building walking route…")
        }
        if route.usesFallback {
            return String(localized: "Path data incomplete · \(route.distanceMeters) m")
        }
        return String(
            localized: "\(route.distanceMeters) m · About \(route.estimatedWalkingMinutes) min"
        )
    }
}

private struct WhereAmIEntryButton: View {
    let location: LocatedMapUser?
    let action: () -> Void
    let updateAction: () -> Void

    @ScaledMetric(relativeTo: .headline) private var minimumHeight = 58.0

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "location.viewfinder")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            location.map { String(localized: "You are near \($0.spaceCode)") }
                                ?? String(localized: "Where am I?")
                        )
                        .font(.headline)
                        .foregroundStyle(.primary)
                        Text(
                            location == nil
                                ? "Press and hold the map to set your position"
                                : "View and copy your current location"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 18)
                .padding(.trailing, location == nil ? 18 : 12)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                location == nil
                    ? "Open the large-button venue locator. You can also press and hold the map."
                    : "View and copy your current location"
            )
            .accessibilityIdentifier(location == nil ? "where-am-i-button" : "current-location-button")

            if location != nil {
                Divider()
                    .frame(height: 34)

                Button {
                    updateAction()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "location.viewfinder")
                            .font(.headline.weight(.semibold))
                        Text("Update location")
                            .font(.caption2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .frame(width: 72)
                .frame(minHeight: minimumHeight)
                .accessibilityIdentifier("banner-update-location")
            }
        }
        .background(Color(uiColor: .systemBackground).opacity(0.94))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }
}

private struct MapSelectorBar: View {
    let model: MapScreenModel
    @Binding var visibleMapLayers: Set<BigSightMapLayer>

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    model.showCampus()
                } label: {
                    if model.scope == .campus {
                        Label("Campus", systemImage: "checkmark")
                    } else {
                        Text("Campus")
                    }
                }

                Divider()

                ForEach(model.halls, id: \.id) { hall in
                    Button {
                        model.select(mapID: hall.externalMapId)
                    } label: {
                        if model.scope == .venue, hall.externalMapId == model.selectedMapID {
                            Label(hall.name, systemImage: "checkmark")
                        } else {
                            Text(hall.name)
                        }
                    }
                }
            } label: {
                SelectorLabel(
                    title: selectedHallName,
                    systemImage: "building.2"
                )
            }
            .accessibilityIdentifier("map-venue-selector")

            Spacer(minLength: 0)

            Menu {
                Section("Quick Views") {
                    Button("Before arrival", systemImage: "map.fill") {
                        visibleMapLayers = [.essentials, .assistance, .cosplay]
                    }
                    Button("Arrival", systemImage: "figure.walk.arrival") {
                        visibleMapLayers = [.gates, .essentials, .assistance, .crowdFlow]
                    }
                    Button("On-site", systemImage: "building.2.fill") {
                        visibleMapLayers = [.essentials, .assistance, .verticalAccess, .cosplay]
                    }
                }

                Section("Layers") {
                    ForEach(BigSightMapLayer.allCases) { layer in
                        Toggle(
                            isOn: Binding(
                                get: { visibleMapLayers.contains(layer) },
                                set: { isVisible in
                                    if isVisible {
                                        visibleMapLayers.insert(layer)
                                    } else {
                                        visibleMapLayers.remove(layer)
                                    }
                                }
                            )
                        ) {
                            Label(layer.title, systemImage: layer.systemImage)
                        }
                    }
                }

                Divider()

                Button("Show All", systemImage: "eye") {
                    visibleMapLayers = BigSightMapLayer.defaultVisible
                }
                Button("Hide Optional Layers", systemImage: "eye.slash") {
                    visibleMapLayers.removeAll()
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        visibleMapLayers == BigSightMapLayer.defaultVisible
                            ? Color.primary
                            : Color.accentColor
                    )
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map layers")
            .accessibilityValue(
                "\(visibleMapLayers.count) of \(BigSightMapLayer.allCases.count) shown"
            )
            .accessibilityIdentifier("map-layer-button")

            if model.scope == .venue {
                Button {
                    model.setSearchPresented(!model.isSearchPresented)
                } label: {
                    Image(systemName: model.isSearchPresented ? "xmark" : "magnifyingglass")
                        .font(.callout.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isSearchPresented ? "Close map search" : "Search circles")
                .accessibilityIdentifier("map-search-button")

                Button {
                    model.toggleGenreOverlay()
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.showsGenreOverlay ? Color.accentColor : .primary)
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.showsGenreOverlay ? "Hide genre overlay" : "Show genre overlay")
                .accessibilityIdentifier("map-genre-button")
            }
        }
    }

    private var selectedHallName: String {
        guard model.scope == .venue else { return String(localized: "Campus") }
        return model.halls.first(where: { $0.externalMapId == model.selectedMapID })?.name
            ?? String(localized: "Venue")
    }

}

private struct MapSearchField: View {
    let model: MapScreenModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "Circle, creator, or description",
                text: $text
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
            .submitLabel(.search)
            .accessibilityIdentifier("map-search-field")

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.searchQuery.isEmpty {
                Text("\(model.searchMatches.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(model.searchMatches.count) matching circles")
                    .accessibilityIdentifier("map-search-summary")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.55), lineWidth: 0.5)
        }
        .onAppear {
            text = model.searchQuery
            isFocused = true
        }
        .onChange(of: text) { _, value in
            model.updateSearchQuery(value)
        }
    }
}

private struct SelectorLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(.thinMaterial, in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.5), lineWidth: 0.5)
            }
            .contentShape(.capsule)
    }
}

private struct MapLoadingView: View {
    let message: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MapRefreshIndicator: View {
    let message: LocalizedStringResource

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("map-refresh-indicator")
        .allowsHitTesting(false)
    }
}

private struct MapTransformGestureState: Equatable {
    var magnification: CGFloat = 1
    var magnificationAnchor: CGPoint = .zero
    var rotation: CGFloat = 0
    var rotationAnchor: CGPoint = .zero
}

private struct InteractiveMapCanvas: View {
    let scene: CatalogMapScene
    let selectedTableID: CatalogMapTable.ID?
    let circlePlacements: [CatalogMapCirclePlacement]
    let circleArtwork: [Int: CGImage]
    let searchMatches: [CatalogMapSearchMatch]
    let searchActive: Bool
    let genrePlacements: [CatalogMapGenrePlacement]
    let bookmarks: [MapBookmark]
    let locatedUser: LocatedMapUser?
    let locationFocusBottomInset: CGFloat
    let onViewportChange: (CatalogMapViewport) -> Void
    let onSelect: (CatalogMapTable, Int) -> Void
    let onSelectLocatedUser: () -> Void
    let onLocate: (CGPoint, CatalogMapTable, Int) -> Void
    private let placementsByTable: [CatalogMapTable.ID: [CatalogMapCirclePlacement]]
    private let searchMatchesByTable: [CatalogMapTable.ID: [CatalogMapSearchMatch]]
    private let genresByTable: [CatalogMapTable.ID: [CatalogMapGenrePlacement]]
    private let bookmarksByTable: [CatalogMapTable.ID: [MapBookmark]]

    @State private var camera = MapCamera()
    @State private var hasAppliedInitialCamera = false
    @State private var longPressFeedback = 0
    @State private var didTriggerLongPress = false
    @State private var pendingLongPressUntil = Date.distantPast
    @State private var suppressTapUntil = Date.distantPast
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var transformGestureState = MapTransformGestureState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(
        scene: CatalogMapScene,
        selectedTableID: CatalogMapTable.ID?,
        circlePlacements: [CatalogMapCirclePlacement],
        circleArtwork: [Int: CGImage],
        searchMatches: [CatalogMapSearchMatch],
        searchActive: Bool,
        genrePlacements: [CatalogMapGenrePlacement],
        bookmarks: [MapBookmark],
        locatedUser: LocatedMapUser?,
        locationFocusBottomInset: CGFloat,
        onViewportChange: @escaping (CatalogMapViewport) -> Void,
        onSelect: @escaping (CatalogMapTable, Int) -> Void,
        onSelectLocatedUser: @escaping () -> Void,
        onLocate: @escaping (CGPoint, CatalogMapTable, Int) -> Void
    ) {
        self.scene = scene
        self.selectedTableID = selectedTableID
        self.circlePlacements = circlePlacements
        self.circleArtwork = circleArtwork
        self.searchMatches = searchMatches
        self.searchActive = searchActive
        self.genrePlacements = genrePlacements
        self.bookmarks = bookmarks
        self.locatedUser = locatedUser
        self.locationFocusBottomInset = locationFocusBottomInset
        self.onViewportChange = onViewportChange
        self.onSelect = onSelect
        self.onSelectLocatedUser = onSelectLocatedUser
        self.onLocate = onLocate
        placementsByTable = Dictionary(grouping: circlePlacements, by: \.tableID)
        searchMatchesByTable = Dictionary(grouping: searchMatches, by: \.tableID)
        genresByTable = Dictionary(grouping: genrePlacements, by: \.tableID)
        bookmarksByTable = Dictionary(grouping: bookmarks, by: \.tableID)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = geometry.size
            let effectiveCamera = cameraApplyingActiveGestures(viewportSize: viewportSize)
            let transform = MapCameraMath.transform(
                camera: effectiveCamera,
                geometry: cameraGeometry(viewportSize: viewportSize)
            )
            let visibleRect = visibleMapRect(transform: transform, viewportSize: viewportSize)
            let renderedScale = fitScale(viewportSize: viewportSize) * effectiveCamera.zoom
            let committedTransform = MapCameraMath.transform(
                camera: camera,
                geometry: cameraGeometry(viewportSize: viewportSize)
            )
            let committedViewport = CatalogMapViewport(
                sceneID: scene.id,
                mapRect: visibleMapRect(transform: committedTransform, viewportSize: viewportSize),
                renderedScale: fitScale(viewportSize: viewportSize) * camera.zoom
            )
            Canvas(opaque: true, colorMode: .nonLinear) { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(
                        colorScheme == .dark
                            ? Color(red: 0.055, green: 0.063, blue: 0.071)
                            : Color(white: 0.94)
                    )
                )
                context.concatenate(transform)

                let mapBounds = CGRect(origin: .zero, size: scene.size)
                context.fill(
                    Path(mapBounds),
                    with: .color(
                        colorScheme == .dark
                            ? Color(red: 0.105, green: 0.115, blue: 0.125)
                            : Color.white
                    )
                )
                if let artwork = scene.artwork {
                    context.draw(Image(decorative: artwork.image, scale: 1), in: mapBounds)
                    if colorScheme == .dark {
                        context.drawLayer { layer in
                            layer.blendMode = .difference
                            layer.fill(Path(mapBounds), with: .color(.white))
                        }
                        context.fill(Path(mapBounds), with: .color(.black.opacity(0.12)))
                    }
                }
                context.stroke(
                    Path(mapBounds),
                    with: .color(Color.primary.opacity(colorScheme == .dark ? 0.3 : 0.22)),
                    lineWidth: max(1 / renderedScale, 2)
                )

                drawRoute(bookmarks: bookmarks, in: &context, renderedScale: renderedScale)

                for table in scene.tables where tableRect(table).intersects(visibleRect) {
                    draw(
                        table: table,
                        placements: placementsByTable[table.id] ?? [],
                        searchMatches: searchMatchesByTable[table.id] ?? [],
                        genres: genresByTable[table.id] ?? [],
                        bookmarks: bookmarksByTable[table.id] ?? [],
                        in: &context,
                        renderedScale: renderedScale,
                        usesAuthoredMap: scene.artwork != nil
                    )
                }

                if scene.artwork == nil {
                    drawBlockLabels(in: &context, visibleRect: visibleRect, renderedScale: renderedScale)
                }
                if let locatedUser, locatedUser.sceneID == scene.id {
                    drawLocatedUser(locatedUser, in: &context, renderedScale: renderedScale)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("interactive-map-canvas")
            .accessibilityLabel("Interactive venue map")
            .accessibilityValue(
                accessibilityValue
            )
            .accessibilityHint("Double-tap to inspect a table. Press and hold to set your location.")
            .accessibilityAction(named: Text("Set location at map center")) {
                locate(
                    at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
                    transform: transform
                )
            }
            .contentShape(Rectangle())
            .highPriorityGesture(longPressGesture(transform: transform))
            .simultaneousGesture(panGesture(viewportSize: viewportSize))
            .simultaneousGesture(transformGesture(viewportSize: viewportSize))
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let location = value.location
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if Date.now < pendingLongPressUntil {
                                pendingLongPressUntil = .distantPast
                                locate(at: location, transform: transform)
                                return
                            }
                            guard Date.now >= suppressTapUntil else { return }
                            if isLocatedUser(at: location, transform: transform) {
                                onSelectLocatedUser()
                                return
                            }
                            selectTable(at: location, transform: transform)
                        }
                    }
            )
            .sensoryFeedback(.success, trigger: longPressFeedback)
            .overlay(alignment: .bottomTrailing) {
                compassButton(viewportSize: viewportSize)
                    .padding(.trailing, MapChromeLayout.trailingInset)
                    .padding(.bottom, 16)
            }
            .onChange(of: committedViewport, initial: true) { _, viewport in
                onViewportChange(viewport)
            }
            .onAppear {
                guard !hasAppliedInitialCamera else { return }
                hasAppliedInitialCamera = true
                if let locatedUser, locatedUser.sceneID == scene.id {
                    focus(
                        on: locatedUser,
                        viewportSize: viewportSize,
                        safeAreaBottomInset: geometry.safeAreaInsets.bottom,
                        animated: false
                    )
                } else {
                    camera.zoom = initialZoom
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-rotated-camera") {
                    camera.rotation = .pi / 4
                }
                #endif
            }
            .onChange(of: locatedUser?.placedAt) {
                guard let locatedUser, locatedUser.sceneID == scene.id else { return }
                focus(
                    on: locatedUser,
                    viewportSize: viewportSize,
                    safeAreaBottomInset: geometry.safeAreaInsets.bottom,
                    animated: true
                )
            }
            .onChange(of: locationFocusBottomInset) {
                guard locationFocusBottomInset > 0,
                      let locatedUser,
                      locatedUser.sceneID == scene.id
                else { return }
                focus(
                    on: locatedUser,
                    viewportSize: viewportSize,
                    safeAreaBottomInset: geometry.safeAreaInsets.bottom,
                    animated: true
                )
            }
        }
        .onChange(of: scene.id) {
            camera = MapCamera(zoom: initialZoom)
        }
    }

    private var accessibilityValue: Text {
        if let locatedUser, locatedUser.sceneID == scene.id {
            let heading = locatedUser.headingDegrees.map { Int($0.rounded()) }
            if let heading {
                return Text(accessibilityCameraValue(
                    "Zoom \(camera.zoom) times, user location \(locatedUser.spaceCode), heading \(heading) degrees"
                ))
            }
            return Text(accessibilityCameraValue(
                "Zoom \(camera.zoom) times, user location \(locatedUser.spaceCode)"
            ))
        }
        return Text(accessibilityCameraValue(
            "Zoom \(camera.zoom) times, \(circleArtwork.count) circle images, \(bookmarks.count) route stops"
        ))
    }

    private func accessibilityCameraValue(_ summary: String) -> String {
        #if DEBUG
        let bearing = MapCameraMath.normalizedRotation(camera.rotation) * 180 / .pi
        return summary + String(
            format: ", camera offset %.1f %.1f, bearing %.1f degrees",
            camera.translation.width,
            camera.translation.height,
            bearing
        )
        #else
        return summary
        #endif
    }

    private func locate(at screenPoint: CGPoint, transform: CGAffineTransform) {
        let rawPoint = screenPoint.applying(transform.inverted())
        let mapPoint = CGPoint(
            x: min(max(rawPoint.x, 0), scene.size.width),
            y: min(max(rawPoint.y, 0), scene.size.height)
        )
        guard let table = WhereAmIResolver.nearestTable(to: mapPoint, in: scene) else { return }
        let subspace = WhereAmIResolver.subspace(at: mapPoint, in: table, scene: scene)
        onLocate(mapPoint, table, subspace)
        longPressFeedback += 1
    }

    private func isLocatedUser(at screenPoint: CGPoint, transform: CGAffineTransform) -> Bool {
        guard let locatedUser, locatedUser.sceneID == scene.id else { return false }
        let markerPoint = locatedUser.point.applying(transform)
        return hypot(screenPoint.x - markerPoint.x, screenPoint.y - markerPoint.y) <= 28
    }

    private func panGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                guard !didTriggerLongPress,
                      hypot(value.translation.width, value.translation.height) >= 4
                else {
                    return
                }
                state = value.translation
            }
            .onChanged { value in
                if hypot(value.translation.width, value.translation.height) > 18 {
                    didTriggerLongPress = false
                }
            }
            .onEnded { value in
                let triggeredLongPress = didTriggerLongPress
                didTriggerLongPress = false
                guard !triggeredLongPress,
                      hypot(value.translation.width, value.translation.height) >= 4
                else {
                    return
                }
                let target = MapCameraMath.projectedPan(
                    from: camera,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    geometry: cameraGeometry(viewportSize: viewportSize),
                    tuning: .venue
                )
                withAnimation(.interpolatingSpring(duration: 0.32, bounce: 0.02)) {
                    camera = target
                }
            }
    }

    private func longPressGesture(transform: CGAffineTransform) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                guard case .second(true, let drag) = value else { return }
                didTriggerLongPress = true
                suppressTapUntil = Date.now.addingTimeInterval(3)
                if let drag {
                    pendingLongPressUntil = .distantPast
                    locate(at: drag.location, transform: transform)
                } else {
                    pendingLongPressUntil = Date.now.addingTimeInterval(3)
                }
            }
    }

    private func transformGesture(viewportSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .simultaneously(with: RotateGesture(minimumAngleDelta: .degrees(0.25)))
            .updating($transformGestureState) { value, state, _ in
                if let magnification = value.first {
                    state.magnification = magnification.magnification
                    state.magnificationAnchor = magnification.startLocation
                }
                if let rotation = value.second {
                    state.rotation = rotation.rotation.radians
                    state.rotationAnchor = rotation.startLocation
                }
            }
            .onEnded { value in
                let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                let magnification = value.first?.magnification ?? 1
                let magnificationVelocity = value.first?.velocity ?? 0
                let rotation = value.second?.rotation.radians ?? 0
                let rotationVelocity = value.second?.velocity.radians ?? 0
                let projectedMagnification = MapCameraMath.projectedMagnification(
                    magnification,
                    velocity: magnificationVelocity,
                    tuning: .venue
                )
                let projectedRotation = MapCameraMath.projectedRotation(
                    rotation,
                    velocity: rotationVelocity,
                    tuning: .venue
                )
                let target = MapCameraMath.applyingGesture(
                    to: camera,
                    magnification: projectedMagnification,
                    magnificationAnchor: value.first?.startLocation ?? center,
                    rotation: projectedRotation,
                    rotationAnchor: value.second?.startLocation ?? center,
                    geometry: cameraGeometry(viewportSize: viewportSize),
                    tuning: .venue,
                    allowsRubberBand: false
                )
                withAnimation(.interpolatingSpring(duration: 0.34, bounce: 0.05)) {
                    camera = target
                }
            }
    }

    private func cameraApplyingActiveGestures(viewportSize: CGSize) -> MapCamera {
        MapCameraMath.applyingGesture(
            to: camera,
            pan: dragTranslation,
            magnification: transformGestureState.magnification,
            magnificationAnchor: transformGestureState.magnificationAnchor,
            rotation: transformGestureState.rotation,
            rotationAnchor: transformGestureState.rotationAnchor,
            geometry: cameraGeometry(viewportSize: viewportSize),
            tuning: .venue,
            allowsRubberBand: true
        )
    }

    @ViewBuilder
    private func compassButton(viewportSize: CGSize) -> some View {
        if abs(MapCameraMath.normalizedRotation(camera.rotation)) > .pi / 180 {
            Button {
                let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                let target = MapCameraMath.applyingGesture(
                    to: camera,
                    magnificationAnchor: center,
                    rotation: -camera.rotation,
                    rotationAnchor: center,
                    geometry: cameraGeometry(viewportSize: viewportSize),
                    tuning: .venue,
                    allowsRubberBand: false
                )
                if reduceMotion {
                    camera = target
                } else {
                    withAnimation(.smooth(duration: 0.22)) {
                        camera = target
                    }
                }
            } label: {
                Image(systemName: "location.north.fill")
                    .font(.headline)
                    .rotationEffect(
                        .radians(MapCameraMath.northIndicatorRotation(mapRotation: camera.rotation))
                    )
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset map to north")
            .accessibilityIdentifier("map-compass-button")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func draw(
        table: CatalogMapTable,
        placements: [CatalogMapCirclePlacement],
        searchMatches: [CatalogMapSearchMatch],
        genres: [CatalogMapGenrePlacement],
        bookmarks: [MapBookmark],
        in context: inout GraphicsContext,
        renderedScale: CGFloat,
        usesAuthoredMap: Bool
    ) {
        let rect = tableRect(table)
        let selected = selectedTableID == table.id
        let borderWidth = max(1 / renderedScale, selected ? 2.2 : 1.4)

        if !usesAuthoredMap || selected {
            context.fill(
                Path(rect),
                with: .color(
                    selected
                        ? Color.accentColor.opacity(0.28)
                        : tableColor(table.id.blockID).opacity(searchActive && searchMatches.isEmpty ? 0.24 : 1)
                )
            )
        }

        for genre in genres {
            context.fill(
                Path(subspaceRect(tableRect: rect, orientation: table.orientation, subspace: genre.subspace)),
                with: .color(genreColor(genre.genreID).opacity(0.42))
            )
        }

        for bookmark in bookmarks {
            let bookmarkRect = subspaceRect(
                tableRect: rect,
                orientation: table.orientation,
                subspace: bookmark.subspace
            )
            let color = bookmarkColor(bookmark.color)
            context.fill(Path(bookmarkRect), with: .color(color.opacity(0.62)))
            context.stroke(
                Path(bookmarkRect.insetBy(dx: 1.2, dy: 1.2)),
                with: .color(color),
                lineWidth: max(1.2 / renderedScale, 2)
            )
        }

        for match in searchMatches {
            let matchRect = subspaceRect(tableRect: rect, orientation: table.orientation, subspace: match.subspace)
            context.fill(Path(matchRect), with: .color(Color.yellow.opacity(0.82)))
            context.stroke(
                Path(matchRect.insetBy(dx: 1.5, dy: 1.5)),
                with: .color(Color.orange),
                lineWidth: max(1 / renderedScale, 1.5)
            )
        }

        if renderedScale >= CatalogMapViewport.circleArtworkThreshold {
            for placement in placements {
                guard let image = circleArtwork[placement.circleID] else { continue }
                let target = subspaceRect(
                    tableRect: rect,
                    orientation: table.orientation,
                    subspace: placement.subspace
                )
                let geometry = CatalogCircleArtworkGeometry.fitting(
                    pixelSize: CGSize(width: image.width, height: image.height),
                    in: target.size,
                    orientation: table.orientation
                )
                context.drawLayer { layer in
                    layer.translateBy(x: target.midX, y: target.midY)
                    layer.rotate(by: .radians(geometry.rotation))
                    layer.draw(
                        Image(decorative: image, scale: 1),
                        in: CGRect(
                            x: -geometry.imageSize.width / 2,
                            y: -geometry.imageSize.height / 2,
                            width: geometry.imageSize.width,
                            height: geometry.imageSize.height
                        )
                    )
                }
            }
        }

        if !usesAuthoredMap || selected {
            context.stroke(
                Path(rect),
                with: .color(selected ? Color.accentColor : Color.primary.opacity(0.72)),
                lineWidth: borderWidth
            )
        }

        if !usesAuthoredMap {
            var divider = Path()
            switch table.orientation {
            case .aLeft, .aRight:
                divider.move(to: CGPoint(x: rect.midX, y: rect.minY))
                divider.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            case .aTop, .aBottom:
                divider.move(to: CGPoint(x: rect.minX, y: rect.midY))
                divider.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
            context.stroke(
                divider,
                with: .color(Color.primary.opacity(0.5)),
                lineWidth: max(0.7 / renderedScale, 0.8)
            )
        }

        for bookmark in bookmarks {
            guard let routeOrder = bookmark.routeOrder, renderedScale >= 0.22 else { continue }
            let target = subspaceRect(
                tableRect: rect,
                orientation: table.orientation,
                subspace: bookmark.subspace
            )
            let radius = min(8 / renderedScale, 8)
            let badge = CGRect(
                x: target.midX - radius,
                y: target.midY - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: badge), with: .color(bookmarkColor(bookmark.color)))
            context.stroke(
                Path(ellipseIn: badge),
                with: .color(.white),
                lineWidth: max(1 / renderedScale, 0.7)
            )
            context.draw(
                Text("\(routeOrder + 1)")
                    .font(.system(size: min(10 / renderedScale, 8), weight: .bold, design: .rounded))
                    .foregroundStyle(.white),
                at: CGPoint(x: target.midX, y: target.midY),
                anchor: .center
            )
        }

        guard !usesAuthoredMap, renderedScale >= 0.55 else { return }
        context.draw(
            Text("\(table.blockName)\(table.id.spaceNumber)")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.78)),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
    }

    private func drawRoute(
        bookmarks: [MapBookmark],
        in context: inout GraphicsContext,
        renderedScale: CGFloat
    ) {
        let stops = bookmarks
            .filter { $0.routeOrder != nil }
            .sorted { ($0.routeOrder ?? .max) < ($1.routeOrder ?? .max) }
            .compactMap { bookmark -> CGPoint? in
                guard let table = scene.tableByID[bookmark.tableID] else { return nil }
                let target = subspaceRect(
                    tableRect: tableRect(table),
                    orientation: table.orientation,
                    subspace: bookmark.subspace
                )
                return CGPoint(x: target.midX, y: target.midY)
            }
        guard stops.count > 1 else { return }

        var path = Path()
        path.move(to: stops[0])
        for stop in stops.dropFirst() {
            path.addLine(to: stop)
        }
        context.stroke(
            path,
            with: .color(
                colorScheme == .dark ? .black.opacity(0.8) : .white.opacity(0.92)
            ),
            style: StrokeStyle(
                lineWidth: 6 / renderedScale,
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.stroke(
            path,
            with: .color(Color.accentColor.opacity(0.82)),
            style: StrokeStyle(
                lineWidth: 3 / renderedScale,
                lineCap: .round,
                lineJoin: .round,
                dash: [8 / renderedScale, 5 / renderedScale]
            )
        )
    }

    private func drawLocatedUser(
        _ user: LocatedMapUser,
        in context: inout GraphicsContext,
        renderedScale: CGFloat
    ) {
        let center = user.point
        let puckRadius = 9 / renderedScale
        let haloRadius = 15 / renderedScale

        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - haloRadius,
                y: center.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )),
            with: .color(Color.blue.opacity(0.18))
        )

        if let angle = user.mapHeadingRadians {
            let direction = CGVector(dx: sin(angle), dy: -cos(angle))
            let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
            let tipDistance = 26 / renderedScale
            let baseDistance = 5 / renderedScale
            let halfWidth = 7 / renderedScale
            var pointer = Path()
            pointer.move(to: CGPoint(
                x: center.x + direction.dx * tipDistance,
                y: center.y + direction.dy * tipDistance
            ))
            pointer.addLine(to: CGPoint(
                x: center.x - direction.dx * baseDistance + perpendicular.dx * halfWidth,
                y: center.y - direction.dy * baseDistance + perpendicular.dy * halfWidth
            ))
            pointer.addLine(to: CGPoint(
                x: center.x - direction.dx * baseDistance - perpendicular.dx * halfWidth,
                y: center.y - direction.dy * baseDistance - perpendicular.dy * halfWidth
            ))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(.blue))
            context.stroke(pointer, with: .color(.white), lineWidth: 1.5 / renderedScale)
        }

        let puck = Path(ellipseIn: CGRect(
            x: center.x - puckRadius,
            y: center.y - puckRadius,
            width: puckRadius * 2,
            height: puckRadius * 2
        ))
        context.fill(puck, with: .color(.blue))
        context.stroke(puck, with: .color(.white), lineWidth: 2.5 / renderedScale)
    }

    private func drawBlockLabels(
        in context: inout GraphicsContext,
        visibleRect: CGRect,
        renderedScale: CGFloat
    ) {
        guard renderedScale >= 0.1 else { return }
        let fontSize = min(42, 18 / renderedScale)
        for label in scene.blockLabels where visibleRect.contains(label.position) {
            context.draw(
                Text(label.name)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.02, green: 0.62, blue: 0.36).opacity(0.88)),
                at: label.position,
                anchor: .center
            )
        }
    }

    private func tableColor(_ blockID: Int) -> Color {
        let hue = Double((blockID * 47) % 360) / 360
        return Color(hue: hue, saturation: 0.14, brightness: 0.98)
    }

    private func genreColor(_ genreID: Int) -> Color {
        let hue = Double((genreID * 67) % 360) / 360
        return Color(hue: hue, saturation: 0.58, brightness: 0.92)
    }

    private func bookmarkColor(_ color: BookmarkColor) -> Color {
        switch color {
        case .memoOnly: .gray
        case .orange: Color(red: 1, green: 0.58, blue: 0.29)
        case .magenta: Color(red: 1, green: 0, blue: 1)
        case .yellow: Color(red: 1, green: 0.97, blue: 0)
        case .green: Color(red: 0, green: 0.71, blue: 0.29)
        case .cyan: Color(red: 0, green: 0.71, blue: 1)
        case .purple: Color(red: 0.61, green: 0.32, blue: 0.61)
        case .blue: .blue
        case .lime: .green
        case .red: .red
        }
    }

    private func subspaceRect(
        tableRect: CGRect,
        orientation: CatalogMapTable.Orientation,
        subspace: Int
    ) -> CGRect {
        switch orientation {
        case .aLeft:
            return subspace == 0
                ? CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width / 2, height: tableRect.height)
                : CGRect(x: tableRect.midX, y: tableRect.minY, width: tableRect.width / 2, height: tableRect.height)
        case .aBottom:
            return subspace == 0
                ? CGRect(x: tableRect.minX, y: tableRect.midY, width: tableRect.width, height: tableRect.height / 2)
                : CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width, height: tableRect.height / 2)
        case .aRight:
            return subspace == 0
                ? CGRect(x: tableRect.midX, y: tableRect.minY, width: tableRect.width / 2, height: tableRect.height)
                : CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width / 2, height: tableRect.height)
        case .aTop:
            return subspace == 0
                ? CGRect(x: tableRect.minX, y: tableRect.minY, width: tableRect.width, height: tableRect.height / 2)
                : CGRect(x: tableRect.minX, y: tableRect.midY, width: tableRect.width, height: tableRect.height / 2)
        }
    }

    private func selectTable(at screenPoint: CGPoint, transform: CGAffineTransform) {
        let mapPoint = screenPoint.applying(transform.inverted())
        guard let table = scene.tables.first(where: { tableRect($0).contains(mapPoint) }) else { return }

        let rect = tableRect(table)
        let subspace: Int
        switch table.orientation {
        case .aLeft:
            subspace = mapPoint.x < rect.midX ? 0 : 1
        case .aBottom:
            subspace = mapPoint.y >= rect.midY ? 0 : 1
        case .aRight:
            subspace = mapPoint.x >= rect.midX ? 0 : 1
        case .aTop:
            subspace = mapPoint.y < rect.midY ? 0 : 1
        }
        onSelect(table, subspace)
    }

    private func tableRect(_ table: CatalogMapTable) -> CGRect {
        CGRect(origin: table.origin, size: scene.tableSize)
    }

    private func focus(
        on user: LocatedMapUser,
        viewportSize: CGSize,
        safeAreaBottomInset: CGFloat,
        animated: Bool
    ) {
        let targetZoom = max(camera.zoom, 24)
        let scale = fitScale(viewportSize: viewportSize) * targetZoom
        let offsetX = user.point.x - scene.size.width / 2
        let offsetY = user.point.y - scene.size.height / 2
        let cosine = cos(camera.rotation)
        let sine = sin(camera.rotation)
        let rotatedX = offsetX * cosine - offsetY * sine
        let rotatedY = offsetX * sine + offsetY * cosine
        let requestedTranslation = CGSize(
            width: -rotatedX * scale,
            height: -rotatedY * scale
        )
        let visibleCenter = MapCameraMath.visibleViewportCenter(
            viewportSize: viewportSize,
            bottomInset: locationFocusBottomInset + safeAreaBottomInset
        )
        let viewportOffset = CGSize(
            width: visibleCenter.x - viewportSize.width / 2,
            height: visibleCenter.y - viewportSize.height / 2
        )
        let target = MapCameraMath.constrained(
            MapCamera(
                translation: CGSize(
                    width: requestedTranslation.width + viewportOffset.width,
                    height: requestedTranslation.height + viewportOffset.height
                ),
                zoom: targetZoom,
                rotation: camera.rotation
            ),
            geometry: cameraGeometry(viewportSize: viewportSize),
            tuning: .venue
        )
        let updateCamera = {
            camera = target
        }

        if animated, !reduceMotion {
            withAnimation(.smooth(duration: 0.22)) {
                updateCamera()
            }
        } else {
            updateCamera()
        }
    }

    private func fitScale(viewportSize: CGSize) -> CGFloat {
        min(viewportSize.width / scene.size.width, viewportSize.height / scene.size.height) * 0.92
    }

    private func cameraGeometry(viewportSize: CGSize) -> MapCameraGeometry {
        MapCameraGeometry(
            contentSize: scene.size,
            viewportSize: viewportSize,
            fittedScale: fitScale(viewportSize: viewportSize)
        )
    }

    private var initialZoom: CGFloat {
        min(max(scene.size.width / scene.size.height * 1.35, 1), 4)
    }

    private func visibleMapRect(transform: CGAffineTransform, viewportSize: CGSize) -> CGRect {
        let inverse = transform.inverted()
        let corners = [
            CGPoint.zero,
            CGPoint(x: viewportSize.width, y: 0),
            CGPoint(x: 0, y: viewportSize.height),
            CGPoint(x: viewportSize.width, y: viewportSize.height),
        ].map { $0.applying(inverse) }

        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? scene.size.width
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? scene.size.height
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -scene.tableSize.width, dy: -scene.tableSize.height)
    }

}

private struct CircleMapDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAddress = false
    @State private var copyFeedback = 0

    let selection: MapScreenModel.Selection
    let bookmark: MapBookmark?
    let isMutatingBookmark: Bool
    let isSyncingBookmark: Bool
    let bookmarkError: String?
    let onSelectCircle: (CatalogMapCircle) -> Void
    let onToggleBookmark: () -> Void
    let onSetBookmarkColor: (BookmarkColor) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if selection.isLoading {
                        ProgressView("Loading circles…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if selection.circles.isEmpty {
                        ContentUnavailableView(
                            "No circle assigned",
                            systemImage: "person.slash",
                            description: Text("This physical table has no public circle for the selected day.")
                        )
                    } else {
                        circlePicker
                        selectedCircleDetail
                        bookmarkControls
                    }
                }
                .padding()
            }
            .navigationTitle("Circle details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityIdentifier("map-circle-sheet-close")
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyFeedback)
        .onChange(of: selection.selectedCircleID) {
            copiedAddress = false
        }
        .accessibilityIdentifier("map-circle-sheet")
    }

    private var header: some View {
        Button {
            UIPasteboard.general.string = selection.selectedAddress.canonicalText
            copiedAddress = true
            copyFeedback += 1
        } label: {
            HStack(spacing: 14) {
                Image(systemName: copiedAddress ? "checkmark.circle.fill" : "mappin.and.ellipse")
                    .font(.title2)
                    .foregroundStyle(copiedAddress ? .green : .accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.selectedAddress.spaceCode)
                        .font(.title2.monospaced().weight(.bold))
                        .foregroundStyle(.primary)

                    Text(selection.selectedAddress.canonicalText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(copiedAddress ? "Copied" : "Copy")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(copiedAddress ? .green : .accentColor)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
        }
        .accessibilityLabel("Copy \(selection.selectedAddress.canonicalText)")
        .accessibilityHint("Copies the Comiket-formatted circle address")
        .accessibilityIdentifier("map-circle-address-copy")
    }

    private var circlePicker: some View {
        HStack(spacing: 8) {
            ForEach(selection.circles) { circle in
                Button {
                    onSelectCircle(circle)
                } label: {
                    Text(circle.subspace == 0 ? "a" : "b")
                        .font(.headline.monospaced())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(selection.selectedCircleID == circle.id ? .accentColor : .secondary)
            }
        }
    }

    @ViewBuilder
    private var selectedCircleDetail: some View {
        if let circle = selection.selectedCircle {
            HStack(alignment: .top, spacing: 14) {
                if let data = selection.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 112, height: 150)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityIdentifier("map-selected-circle-artwork")
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 112, height: 150)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(
                        circle.circleName.isEmpty
                            ? String(localized: "Unnamed circle")
                            : circle.circleName
                    )
                        .font(.title3.weight(.bold))
                    if !circle.penName.isEmpty {
                        Text(circle.penName)
                            .foregroundStyle(.secondary)
                    }
                    if let genreName = circle.genreName, !genreName.isEmpty {
                        Label(genreName, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !circle.description.isEmpty {
                        Text(circle.description)
                            .font(.footnote)
                            .lineLimit(5)
                    }
                    if let url = circle.circlemsURL {
                        Link("Open on Circle.ms", destination: url)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var bookmarkControls: some View {
        if selection.selectedCircle?.publicCircleID != nil {
            VStack(alignment: .leading, spacing: 10) {
                Divider()

                HStack {
                    Button(action: onToggleBookmark) {
                        Label(
                            bookmark == nil ? "Add to route" : "Remove from route",
                            systemImage: bookmark == nil ? "star" : "star.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isMutatingBookmark)
                    .accessibilityIdentifier("map-bookmark-button")

                    if isMutatingBookmark || isSyncingBookmark {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if bookmark?.syncState == .pendingUpsert {
                        Label("Pending sync", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if bookmark != nil {
                    Text("Route color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(BookmarkColor.selectableColors) { color in
                            Button {
                                onSetBookmarkColor(color)
                            } label: {
                                Circle()
                                    .fill(bookmarkColor(color))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if bookmark?.color == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Route color \(color.rawValue)")
                            .accessibilityIdentifier("map-bookmark-color-\(color.rawValue)")
                        }
                    }
                }

                if let bookmarkError {
                    Text(bookmarkError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func bookmarkColor(_ color: BookmarkColor) -> Color {
        switch color {
        case .memoOnly: .gray
        case .orange: Color(red: 1, green: 0.58, blue: 0.29)
        case .magenta: Color(red: 1, green: 0, blue: 1)
        case .yellow: Color(red: 1, green: 0.97, blue: 0)
        case .green: Color(red: 0, green: 0.71, blue: 0.29)
        case .cyan: Color(red: 0, green: 0.71, blue: 1)
        case .purple: Color(red: 0.61, green: 0.32, blue: 0.61)
        case .blue: .blue
        case .lime: .green
        case .red: .red
        }
    }
}

#if DEBUG
#Preview {
    MapView(model: .fixture())
}
#endif
