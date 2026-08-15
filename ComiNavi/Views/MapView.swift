import Combine
import SwiftUI
import UIKit

private enum MapLocationMode: Equatable {
    case manual
    case gps

    var title: LocalizedStringResource {
        switch self {
        case .manual: "Manual Mode"
        case .gps: "GPS Mode"
        }
    }

    var icon: String {
        switch self {
        case .manual: "hand.tap.fill"
        case .gps: "location.fill"
        }
    }
}

private struct GPSLocationTaskID: Equatable {
    let mode: MapLocationMode
    let day: Int
    let sessionID: UUID?
}

private struct GPSLocationSession {
    let id = UUID()
    let startedAt: Date
    var venueDay: Int?
    var venues: [WhereAmIVenueOption] = []
    var hasAcceptedReading = false
}

struct MapView: View {
    private static let currentLocationSheetHeight: CGFloat = 430

    @Environment(\.openURL) private var openURL
    @State private var model: MapScreenModel
    @State private var showsWhereAmI = false
    @State private var showsDestinationPicker = false
    @State private var showsCircleSearch = false
    @State private var showsCurrentLocation = false
    @State private var opensWhereAmIAfterSheet = false
    @State private var locationMode: MapLocationMode = .manual
    @State private var locationService: WhereAmILocationService
    @State private var showsGPSLocationWarning = false
    @State private var isManualCompassEnabled = false
    @State private var gpsSession: GPSLocationSession?
    @State private var locationBeforeManualPicker: LocatedMapUser?
    @State private var isMapLegendExpanded = true
    @State private var visibleMapLayers = BigSightMapLayer.defaultVisible
    @State private var circleSheetDetent: PresentationDetent = .fraction(0.62)
    @Binding private var selectedDay: Int
    private let dataSource: CirclemsDataSource?
    private let eventDaySelector: CatalogEventDayBanner?
    private let sharedLocationInbox: SharedLocationInbox?
    private let sharedPlanStore: SharedPlanStore?
    private let onboardingStore: FeatureOnboardingStore

    private var currentLocationMapBottomInset: CGFloat {
        showsCurrentLocation ? Self.currentLocationSheetHeight : 0
    }

    @MainActor
    init(
        dataSource: CirclemsDataSource,
        selectedDay: Binding<Int>,
        eventDaySelector: CatalogEventDayBanner? = nil,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox,
        onboardingDefaults: UserDefaults = .standard
    ) {
        let sharedPlanStore = AppData.sharedPlanStore
        let currentUserID = AppData.profileStore.profile?.id
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
            bookmarkSyncCoordinator: dataSource.bookmarkSyncCoordinator,
            primarySharedPlanProvider: SharedPlanPrimaryMapCircleProvider(
                store: sharedPlanStore,
                currentUserID: currentUserID
            )
        )
        _model = State(initialValue: model)
        _locationService = State(initialValue: Self.makeLocationService())
        _selectedDay = selectedDay
        self.dataSource = dataSource
        self.eventDaySelector = eventDaySelector
        self.sharedLocationInbox = sharedLocationInbox
        self.sharedPlanStore = sharedPlanStore
        onboardingStore = FeatureOnboardingStore(defaults: onboardingDefaults)
    }

    @MainActor
    init(
        model: MapScreenModel,
        onboardingDefaults: UserDefaults = .standard
    ) {
        _model = State(initialValue: model)
        _locationService = State(initialValue: Self.makeLocationService())
        _selectedDay = .constant(model.selectedDay)
        dataSource = nil
        eventDaySelector = nil
        sharedLocationInbox = nil
        sharedPlanStore = nil
        onboardingStore = FeatureOnboardingStore(defaults: onboardingDefaults)
    }

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .topLeading) {
            mapContent
                .ignoresSafeArea()

            if locationMode == .manual, isManualCompassEnabled {
                ManualCompassOverlay(headingDegrees: locationService.headingDegrees)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            MapControlPanel(
                model: model,
                eventDaySelector: eventDaySelector,
                visibleMapLayers: $visibleMapLayers,
                onFindCircle: {
                    showsCircleSearch = true
                }
            )
            .padding(.horizontal, 14)
            .safeAreaPadding(.top, 8)

            VStack(alignment: .trailing, spacing: 8) {
                if model.phase == .ready, model.scope == .venue, model.showsGenreOverlay {
                    MapLegendView(
                        genrePlacements: model.genrePlacements,
                        isExpanded: $isMapLegendExpanded
                    )
                }

                MapLocationControls(
                    location: model.locatedUser,
                    destination: model.destination,
                    eventNumber: model.eventNumber,
                    mode: locationMode,
                    isManualCompassEnabled: isManualCompassEnabled,
                    onSelectManualMode: selectManualLocationMode,
                    onSelectGPSMode: requestGPSLocationMode,
                    onToggleManualCompass: {
                        isManualCompassEnabled.toggle()
                    },
                    onFindTable: {
                        showsDestinationPicker = true
                    },
                    onClearDestination: {
                        model.clearDestination()
                    }
                )
            }
            .padding(.trailing, MapChromeLayout.edgeInset)
            .safeAreaPadding(.bottom, MapChromeLayout.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            if requiresLocationPermissionRecovery {
                LocationPermissionRecoveryOverlay(
                    onOpenSettings: {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    },
                    onUseManualMode: {
                        presentManualLocationPicker()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .task {
            if model.scene == nil, model.campusScene == nil {
                model.load()
            }
        }
        .onAppear {
            configureLocationService()
        }
        .onDisappear {
            locationService.stop()
        }
        .onChange(of: locationMode) {
            configureLocationService()
            if locationMode == .manual {
                gpsSession = nil
            }
        }
        .onChange(of: isManualCompassEnabled) {
            configureLocationService()
        }
        .task(
            id: GPSLocationTaskID(
                mode: locationMode,
                day: model.selectedDay,
                sessionID: gpsSession?.id
            )
        ) {
            await loadGPSVenuesIfNeeded()
        }
        .onChange(of: locationService.latestReading, initial: true) {
            updateGPSLocation()
        }
        .onChange(of: locationService.headingDegrees, initial: true) {
            updateGPSLocation()
        }
        .task(id: sharedPlanCircleSignature) {
            model.refreshPrimarySharedPlanCircles()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .sharedPlanPrimaryPlanDidChange)
        ) { _ in
            model.refreshPrimarySharedPlanCircles()
        }
        .task(id: sharedLocationInbox?.pending?.id) {
            await openPendingSharedLocation()
        }
        .onChange(of: selectedDay, initial: true) { _, day in
            if model.selectedDay != day {
                model.select(day: day)
            }
        }
        .onChange(of: model.selectedDay) { _, day in
            gpsSession?.venues = []
            gpsSession?.venueDay = nil
            if selectedDay != day {
                selectedDay = day
            }
        }
        .onChange(of: model.bookmarkError) { _, message in
            guard let message else { return }
            AppToast.showError(
                String(localized: "Could not save circle"),
                subtitle: message
            )
            model.dismissBookmarkError()
        }
        .onChange(of: model.sceneError) { _, message in
            guard let message else { return }
            AppToast.showError(
                String(localized: "Could not update map"),
                subtitle: message
            )
            model.dismissSceneError()
        }
        .alert("GPS works best outdoors", isPresented: $showsGPSLocationWarning) {
            Button("Use GPS Mode") {
                onboardingStore.markCompleted(.gpsLocationModeWarning)
                activateGPSLocationMode()
            }
            .accessibilityIdentifier("gps-location-warning-confirm")

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "GPS locations may be inaccurate inside the venue, but can help you orient yourself outdoors."
            )
        }
        .sheet(item: $model.selection) { selection in
            CircleMapDetailSheet(
                selection: selection,
                bookmarks: model.favoriteBookmarks,
                dataSource: dataSource,
                eventNumber: model.eventNumber,
                mapID: model.selectedMapID,
                onOpenDetail: { circle, shouldExpandSheet in
                    model.select(circle: circle)
                    if shouldExpandSheet {
                        circleSheetDetent = .large
                    } else {
                        circleSheetDetent = .fraction(0.62)
                    }
                }
            )
            .presentationDetents(
                [.fraction(0.62), .large],
                selection: $circleSheetDetent
            )
            .presentationDragIndicator(.visible)
        }
        .onChange(of: model.selection?.id) {
            circleSheetDetent = .fraction(0.62)
        }
        .sheet(
            isPresented: $showsCurrentLocation,
            onDismiss: {
                guard opensWhereAmIAfterSheet else { return }
                opensWhereAmIAfterSheet = false
                presentManualLocationPicker()
            }
        ) {
            if let location = model.locatedUser {
                CurrentLocationSheet(
                    location: location,
                    eventNumber: model.eventNumber
                ) {
                    locationMode = .manual
                    opensWhereAmIAfterSheet = true
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(
            isPresented: $showsWhereAmI,
            onDismiss: {
                defer { locationBeforeManualPicker = nil }
                if let locatedUser = model.locatedUser,
                    locatedUser != locationBeforeManualPicker
                {
                    showsCurrentLocation = true
                }
            }
        ) {
            WhereAmIView(mapModel: model)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsDestinationPicker) {
            DestinationPickerView(mapModel: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsCircleSearch) {
            CircleSearchPickerView(mapModel: model, days: model.days)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @MainActor
    private func openPendingSharedLocation() async {
        guard let sharedLocationInbox,
            let request = sharedLocationInbox.pending,
            request.location.eventNumber == model.eventNumber
        else {
            return
        }

        let location = request.location
        guard model.days.contains(where: { $0.dayIndex == location.sceneID.day }) else {
            sharedLocationInbox.fail(request.id, with: .locationUnavailable)
            return
        }

        if model.selectedDay != location.sceneID.day {
            model.select(day: location.sceneID.day)
        }
        if selectedDay != location.sceneID.day {
            selectedDay = location.sceneID.day
        }

        do {
            let venues = try await model.whereAmIVenues()
            try Task.checkCancellation()
            guard
                let venue = venues.first(where: {
                    $0.placement.scene.id == location.sceneID
                }),
                let table = venue.placement.scene.tableByID[location.tableID]
            else {
                sharedLocationInbox.fail(request.id, with: .locationUnavailable)
                return
            }

            model.show(
                WhereAmIResolver.destination(
                    at: table,
                    in: venue,
                    subspace: location.subspace
                ))
            sharedLocationInbox.acknowledge(request.id)
        } catch is CancellationError {
            return
        } catch {
            sharedLocationInbox.fail(request.id, with: .locationUnavailable)
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
                    bookmarks: Array(model.favoriteBookmarks.values),
                    primarySharedPlanCircles: model.primarySharedPlanCircles,
                    locatedUser: model.locatedUser,
                    destination: model.destination,
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
                        activateManualLocationModeForMapPress()
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
                    searchMatches: model.searchMatches.filter { $0.mapID == scene.id.mapID },
                    searchActive: !model.searchQuery.isEmpty,
                    genrePlacements: model.genrePlacements,
                    bookmarks: Array(model.favoriteBookmarks.values),
                    primarySharedPlanCircles: model.primarySharedPlanCircles,
                    locatedUser: model.locatedUser,
                    locationFocusBottomInset: currentLocationMapBottomInset,
                    onViewportChange: model.updateViewport,
                    onSelect: model.select(table:preferredSubspace:),
                    onSelectLocatedUser: {
                        showsCurrentLocation = true
                    },
                    onLocate: { point, table, subspace in
                        activateManualLocationModeForMapPress()
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
                ContentUnavailableView {
                    LucideLabel("Map unavailable", icon: "map.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button {
                        model.load()
                    } label: {
                        LucideLabel("Try Again", icon: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("map-retry-button")
                }
            } else {
                MapLoadingView(
                    message: model.scope == .campus ? "Loading campus…" : "Loading venue…"
                )
            }

        }
    }

    private var sharedPlanCircleSignature: String {
        guard let sharedPlanStore else { return "" }
        return sharedPlanStore.plans.lazy.filter {
            $0.comiketNo == model.eventNumber && $0.lifecycle == .active
        }.map { plan in
            let circleIDs = plan.circleKeys.lazy.map(\.wcID).sorted().map(String.init)
                .joined(separator: ",")
            return "\(plan.id):\(plan.revision):\(circleIDs)"
        }.sorted().joined(separator: "|")
    }

    private func selectManualLocationMode() {
        presentManualLocationPicker()
    }

    private func presentManualLocationPicker() {
        locationMode = .manual
        locationBeforeManualPicker = model.locatedUser
        showsWhereAmI = true
    }

    private func activateManualLocationModeForMapPress() {
        locationMode = .manual
    }

    private func requestGPSLocationMode() {
        guard locationMode != .gps else { return }
        if onboardingStore.shouldPresent(.gpsLocationModeWarning) {
            showsGPSLocationWarning = true
        } else {
            activateGPSLocationMode()
        }
    }

    private func activateGPSLocationMode() {
        gpsSession = GPSLocationSession(startedAt: .now)
        locationMode = .gps
        updateGPSLocation()
    }

    private var requiresLocationPermissionRecovery: Bool {
        guard locationMode == .gps else { return false }
        return switch locationService.authorizationStatus {
        case .denied, .restricted:
            true
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    private func configureLocationService() {
        switch locationMode {
        case .manual:
            locationService.start(
                locationUpdates: false,
                headingUpdates: isManualCompassEnabled
            )
        case .gps:
            locationService.start(locationUpdates: true, headingUpdates: true)
        }
    }

    @MainActor
    private func loadGPSVenuesIfNeeded() async {
        guard locationMode == .gps, let sessionID = gpsSession?.id else { return }
        let day = model.selectedDay
        gpsSession?.venues = []
        gpsSession?.venueDay = nil
        do {
            let venues = try await model.whereAmIVenues()
            try Task.checkCancellation()
            guard locationMode == .gps,
                model.selectedDay == day,
                gpsSession?.id == sessionID
            else { return }
            gpsSession?.venues = venues
            gpsSession?.venueDay = day
            updateGPSLocation()
            #if DEBUG
                scheduleSimulatedGPSUpdateIfNeeded(
                    sessionID: sessionID,
                    venues: venues
                )
            #endif
        } catch is CancellationError {
            return
        } catch {
            guard locationMode == .gps,
                model.selectedDay == day,
                gpsSession?.id == sessionID
            else { return }
            AppToast.showError(
                String(localized: "Could not update map"),
                subtitle: error.localizedDescription
            )
        }
    }

    private func updateGPSLocation() {
        guard locationMode == .gps,
            var session = gpsSession,
            let reading = locationService.latestReading
        else { return }

        guard session.hasAcceptedReading || reading.isLive() else { return }
        if !session.hasAcceptedReading {
            session.hasAcceptedReading = true
            gpsSession = session
        }

        guard session.venueDay == model.selectedDay,
            let user = WhereAmIResolver.gpsLocatedUser(
                from: reading,
                headingDegrees: locationService.headingDegrees,
                venues: session.venues,
                placedAt: session.startedAt
            )
        else { return }

        guard user.sceneID.day == model.selectedDay else { return }
        model.updateGPSLocatedUser(user)
    }

    @MainActor
    private static func makeLocationService() -> WhereAmILocationService {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-location-denied"
            ) {
                return WhereAmILocationService(
                    simulatedHeading: 72,
                    simulatedAuthorizationStatus: .denied
                )
            }
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

    #if DEBUG
        private func scheduleSimulatedGPSUpdateIfNeeded(
            sessionID: UUID,
            venues: [WhereAmIVenueOption]
        ) {
            guard ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-live-gps-update"
            ),
                let placement = venues.first?.placement,
                let table = placement.scene.tables.last
            else { return }

            let point = CGPoint(
                x: table.origin.x + placement.scene.tableSize.width / 2,
                y: table.origin.y + placement.scene.tableSize.height / 2
            )
            let coordinate = BigSightCampusLayout.coordinate(
                from: point.applying(placement.transform)
            )
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard locationMode == .gps, gpsSession?.id == sessionID else { return }
                locationService.updateSimulation(
                    reading: WhereAmILocationReading(
                        coordinate: coordinate,
                        horizontalAccuracy: 8,
                        timestamp: .now
                    ),
                    headingDegrees: 144
                )
            }
        }
    #endif

}

private struct MapControlPanel: View {
    let model: MapScreenModel
    let eventDaySelector: CatalogEventDayBanner?
    @Binding var visibleMapLayers: Set<BigSightMapLayer>
    let onFindCircle: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectors
            if model.isSearchPresented {
                MapSearchField(model: model, onFindByLocation: onFindCircle)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private var selectors: some View {
        if verticalSizeClass == .compact {
            HStack(alignment: .center, spacing: 8) {
                if let eventDaySelector {
                    eventDaySelector
                }
                MapSelectorBar(model: model, visibleMapLayers: $visibleMapLayers)
            }
        } else {
            if let eventDaySelector {
                eventDaySelector
            }
            MapSelectorBar(model: model, visibleMapLayers: $visibleMapLayers)
        }
    }
}

private struct MapLocationControls: View {
    let location: LocatedMapUser?
    let destination: MapDestination?
    let eventNumber: Int
    let mode: MapLocationMode
    let isManualCompassEnabled: Bool
    let onSelectManualMode: () -> Void
    let onSelectGPSMode: () -> Void
    let onToggleManualCompass: () -> Void
    let onFindTable: () -> Void
    let onClearDestination: () -> Void

    @State private var copiedDestination = false
    @State private var showsLocationModes = false
    @State private var showsDestinationActions = false
    @Environment(\.appHapticFeedback) private var hapticFeedback

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showsLocationModes {
                locationModeMenu
            }

            HStack(spacing: MapChromeLayout.controlSpacing) {
                Button {
                    showsLocationModes.toggle()
                } label: {
                    MapLocationControlIcon(
                        icon: showsLocationModes ? "xmark" : "location.viewfinder",
                        isActive: location != nil || mode == .gps
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    showsLocationModes ? "Close location modes" : whereAmILabel
                )
                .accessibilityValue(Text(mode.title))
                .accessibilityHint("Choose how ComiNavi determines your location")
                .accessibilityIdentifier(
                    location == nil ? "where-am-i-button" : "current-location-button"
                )

                Button {
                    if destination == nil {
                        onFindTable()
                    } else {
                        showsDestinationActions = true
                    }
                } label: {
                    destinationIcon
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destinationLabel)
                .accessibilityHint(destinationHint)
                .accessibilityIdentifier("find-table-button")
                .confirmationDialog(
                    destinationLabel,
                    isPresented: $showsDestinationActions,
                    titleVisibility: .visible
                ) {
                    if let destination {
                        Button {
                            onFindTable()
                        } label: {
                            LucideLabel("Find a Circle", icon: "mappin.and.ellipse")
                        }

                        Divider()

                        Button {
                            copy(destination)
                        } label: {
                            LucideLabel("Copy circle location", icon: "doc.on.doc")
                        }
                        .accessibilityIdentifier("copy-destination-button")

                        Button(role: .destructive) {
                            onClearDestination()
                        } label: {
                            LucideLabel("Clear destination", icon: "xmark")
                        }
                        .accessibilityIdentifier("clear-destination-button")
                    }
                }
            }
        }
        .onChange(of: destination?.selectedAt) {
            copiedDestination = false
        }
    }

    private var locationModeMenu: some View {
        VStack(spacing: 8) {
            MapLocationModeOptionButton(
                mode: .manual,
                isSelected: mode == .manual,
                accessibilityIdentifier: "location-mode-manual"
            ) {
                showsLocationModes = false
                onSelectManualMode()
            }

            MapLocationModeOptionButton(
                mode: .gps,
                isSelected: mode == .gps,
                accessibilityIdentifier: "location-mode-gps"
            ) {
                showsLocationModes = false
                onSelectGPSMode()
            }

            if mode == .manual {
                Button {
                    showsLocationModes = false
                    onToggleManualCompass()
                } label: {
                    HStack(spacing: 10) {
                        LucideLabel(
                            resource:
                                isManualCompassEnabled
                                ? LocalizedStringResource("Hide Compass Overlay")
                                : LocalizedStringResource("Show Compass Overlay"),
                            icon: "safari"
                        )
                        Spacer(minLength: 12)
                        if isManualCompassEnabled {
                            LucideIcon("checkmark")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(isManualCompassEnabled ? .accentColor : .primary)
                .accessibilityAddTraits(isManualCompassEnabled ? .isSelected : [])
                .accessibilityIdentifier("manual-compass-overlay-toggle")
            }
        }
        .padding(8)
        .frame(width: 264)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location Mode")
        .accessibilityIdentifier("location-mode-menu")
    }

    private var whereAmILabel: String {
        location.map { String(localized: "You are near \($0.spaceCode)") }
            ?? String(localized: "Where am I?")
    }

    private var destinationLabel: String {
        destination.map { String(localized: "Table \($0.spaceCode)") }
            ?? String(localized: "Find a Circle")
    }

    private var destinationIcon: some View {
        MapLocationControlIcon(
            icon: copiedDestination ? "checkmark" : "mappin.and.ellipse",
            isActive: destination != nil
        )
    }

    private var destinationHint: String {
        String(localized: "Choose a circle and pin it on the map")
    }

    private func copy(_ destination: MapDestination) {
        let shared = SharedComiketLocation(
            eventNumber: eventNumber,
            sceneID: destination.sceneID,
            tableID: destination.tableID,
            subspace: destination.subspace
        )
        UIPasteboard.general.string =
            shared?.clipboardText(
                locationText: destination.canonicalLocationText
            ) ?? destination.canonicalLocationText
        copiedDestination = true
        hapticFeedback?.play(.copyConfirmation)
    }
}

private struct MapLocationModeOptionButton: View {
    let mode: MapLocationMode
    let isSelected: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LucideLabel(resource: mode.title, icon: mode.icon)
                Spacer(minLength: 12)
                if isSelected {
                    LucideIcon("checkmark")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ManualCompassOverlay: View {
    let headingDegrees: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.blue.opacity(0.34), lineWidth: 8)

            LucideIcon("location.north.fill", size: 104)
                .foregroundStyle(Color.blue.opacity(0.48))
                .rotationEffect(.degrees(headingDegrees ?? 0))
                .opacity(headingDegrees == nil ? 0.18 : 1)
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compass overlay")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("manual-compass-overlay")
    }

    private var accessibilityValue: String {
        guard let headingDegrees else {
            return String(localized: "Waiting for compass heading")
        }
        return "\(Int(headingDegrees.rounded()))°"
    }
}

private struct LocationPermissionRecoveryOverlay: View {
    let onOpenSettings: () -> Void
    let onUseManualMode: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Location Access Is Off")
                        .font(.headline)

                    Text(
                        "Turn on location access in Settings to use GPS Mode, or continue in Manual Mode."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                VStack(spacing: 8) {
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("gps-location-permission-settings")

                    Button("Manual Mode", action: onUseManualMode)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("gps-location-permission-manual")
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("gps-location-permission-recovery")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MapLocationControlIcon: View {
    let icon: String
    let isActive: Bool

    var body: some View {
        LucideIcon(icon, size: 20)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: MapChromeLayout.controlSize, height: MapChromeLayout.controlSize)
            .background(.regularMaterial, in: .circle)
            .overlay {
                Circle()
                    .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
            .contentShape(.circle)
    }
}

private struct MapSelectorBar: View {
    let model: MapScreenModel
    @Binding var visibleMapLayers: Set<BigSightMapLayer>
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    model.showCampus()
                } label: {
                    if model.scope == .campus {
                        LucideLabel("Campus", icon: "checkmark")
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
                            LucideLabel(verbatim: hall.name, icon: "checkmark")
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

            if verticalSizeClass != .compact {
                Spacer(minLength: 0)
            }

            Menu {
                Section("Quick Views") {
                    Button {
                        visibleMapLayers = [.essentials, .assistance, .cosplay]
                    } label: {
                        LucideLabel("Before arrival", icon: "map.fill")
                    }
                    Button {
                        visibleMapLayers = [.gates, .essentials, .assistance]
                    } label: {
                        LucideLabel("Arrival", icon: "figure.walk.arrival")
                    }
                    Button {
                        visibleMapLayers = [.essentials, .assistance, .verticalAccess, .cosplay]
                    } label: {
                        LucideLabel("On-site", icon: "building.2.fill")
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
                            LucideLabel(verbatim: layer.title, icon: layer.systemImage)
                        }
                    }
                }

                Divider()

                Button {
                    visibleMapLayers = BigSightMapLayer.defaultVisible
                } label: {
                    LucideLabel("Show All", icon: "eye")
                }
                Button {
                    visibleMapLayers.removeAll()
                } label: {
                    LucideLabel("Hide Optional Layers", icon: "eye.slash")
                }
            } label: {
                LucideIcon("line.3.horizontal.decrease.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        visibleMapLayers == BigSightMapLayer.defaultVisible
                            ? Color.primary
                            : Color.accentColor
                    )
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map layers")
            .accessibilityValue(
                "\(visibleMapLayers.count) of \(BigSightMapLayer.allCases.count) shown"
            )
            .accessibilityIdentifier("map-layer-button")

            Button {
                model.setSearchPresented(!model.isSearchPresented)
            } label: {
                LucideIcon(model.isSearchPresented ? "xmark" : "magnifyingglass")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isSearchPresented ? "Close map search" : "Search circles")
            .accessibilityIdentifier("map-search-button")

            if model.scope == .venue {
                Button {
                    model.toggleGenreOverlay()
                } label: {
                    LucideIcon("square.3.layers.3d")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.showsGenreOverlay ? Color.accentColor : .primary)
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    model.showsGenreOverlay ? "Hide genre overlay" : "Show genre overlay"
                )
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
    let onFindByLocation: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                LucideIcon("magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    "Circle, creator, or description",
                    text: $text
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.search)
                .accessibilityHint("Search circle names, creators, or descriptions")
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

            Button {
                isFocused = false
                onFindByLocation()
            } label: {
                LucideLabel("Find a circle by table location", icon: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .accessibilityHint("Choose the event day, block letter, and space number")
            .accessibilityIdentifier("map-location-search-button")
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
        LucideLabel(verbatim: title, icon: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 44)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MapCompassNeedle: View {
    var body: some View {
        ZStack {
            MapCompassNeedleHalf(pointsNorth: true)
                .fill(.red)

            MapCompassNeedleHalf(pointsNorth: false)
                .fill(.primary.opacity(0.72))

            Circle()
                .fill(.background)
                .frame(width: 4, height: 4)
        }
        .frame(width: 20, height: 28)
    }
}

private struct MapCompassNeedleHalf: Shape {
    let pointsNorth: Bool

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: pointsNorth ? CGPoint(x: rect.midX, y: rect.minY) : center)
        path.addLine(to: CGPoint(x: rect.midX - 4.5, y: rect.midY))
        path.addLine(to: pointsNorth ? center : CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + 4.5, y: rect.midY))
        path.closeSubpath()
        return path
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
    let primarySharedPlanCircles: [CatalogBookmarkLocation]
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
    private let primarySharedPlanCirclesByTable:
        [CatalogMapTable.ID: [CatalogBookmarkLocation]]

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
        primarySharedPlanCircles: [CatalogBookmarkLocation],
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
        self.primarySharedPlanCircles = primarySharedPlanCircles
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
        primarySharedPlanCirclesByTable = Dictionary(
            grouping: primarySharedPlanCircles,
            by: \.tableID
        )
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

                for table in scene.tables where tableRect(table).intersects(visibleRect) {
                    draw(
                        table: table,
                        placements: placementsByTable[table.id] ?? [],
                        searchMatches: searchMatchesByTable[table.id] ?? [],
                        genres: genresByTable[table.id] ?? [],
                        bookmarks: bookmarksByTable[table.id] ?? [],
                        primarySharedPlanCircles: primarySharedPlanCirclesByTable[table.id] ?? [],
                        in: &context,
                        renderedScale: renderedScale,
                        usesAuthoredMap: scene.artwork != nil
                    )
                }

                if scene.artwork == nil {
                    drawBlockLabels(
                        in: &context, visibleRect: visibleRect, renderedScale: renderedScale)
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
            .accessibilityHint(
                "Double-tap to inspect a table. Press and hold to set your location."
            )
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
                    .padding(.trailing, MapChromeLayout.edgeInset)
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
                    if ProcessInfo.processInfo.arguments.contains(
                        "-cominavi-ui-testing-rotated-camera")
                    {
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
                return Text(
                    accessibilityCameraValue(
                        "Zoom \(camera.zoom) times, user location \(locatedUser.spaceCode), heading \(heading) degrees"
                    ))
            }
            return Text(
                accessibilityCameraValue(
                    "Zoom \(camera.zoom) times, user location \(locatedUser.spaceCode)"
                ))
        }
        return Text(
            accessibilityCameraValue(
                    "Zoom \(camera.zoom) times, \(circleArtwork.count) circle images, \(bookmarks.count) favorites, \(primarySharedPlanCircles.count) primary plan circles"
            ))
    }

    private func accessibilityCameraValue(_ summary: String) -> String {
        #if DEBUG
            let bearing = MapCameraMath.normalizedRotation(camera.rotation) * 180 / .pi
            return summary
                + String(
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
                MapCompassNeedle()
                    .rotationEffect(
                        .radians(MapCameraMath.northIndicatorRotation(mapRotation: camera.rotation))
                    )
                    .frame(width: 30, height: 30)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: .circle)
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
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
        primarySharedPlanCircles: [CatalogBookmarkLocation],
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
                        : tableColor(table.id.blockID).opacity(
                            searchActive && searchMatches.isEmpty ? 0.24 : 1)
                )
            )
        }

        for genre in genres {
            context.fill(
                Path(
                    subspaceRect(
                        tableRect: rect, orientation: table.orientation, subspace: genre.subspace)),
                with: .color(genreColor(genre.genreID).opacity(searchActive ? 0.10 : 0.42))
            )
        }

        for circle in primarySharedPlanCircles {
            let planRect = subspaceRect(
                tableRect: rect,
                orientation: table.orientation,
                subspace: circle.subspace
            )
            context.fill(Path(planRect), with: .color(Color.accentColor.opacity(0.48)))
            context.stroke(
                Path(planRect.insetBy(dx: 1.2, dy: 1.2)),
                with: .color(Color.accentColor),
                lineWidth: max(1.2 / renderedScale, 2)
            )
        }

        for bookmark in bookmarks {
            let bookmarkRect = subspaceRect(
                tableRect: rect,
                orientation: table.orientation,
                subspace: bookmark.subspace
            )
            let color = bookmark.color.swiftUIColor
            context.fill(Path(bookmarkRect), with: .color(color.opacity(0.62)))
            context.stroke(
                Path(bookmarkRect.insetBy(dx: 1.2, dy: 1.2)),
                with: .color(color),
                lineWidth: max(1.2 / renderedScale, 2)
            )
        }

        for match in searchMatches {
            let matchRect = subspaceRect(
                tableRect: rect, orientation: table.orientation, subspace: match.subspace)
            context.fill(Path(matchRect), with: .color(Color.yellow.opacity(0.82)))
            context.stroke(
                Path(matchRect.insetBy(dx: 1.5, dy: 1.5)),
                with: .color(Color.orange),
                lineWidth: max(1 / renderedScale, 1.5)
            )
        }

        if renderedScale >= CatalogMapViewport.circleArtworkThreshold, !searchActive {
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
                    let imageRect = CGRect(
                        x: -geometry.imageSize.width / 2,
                        y: -geometry.imageSize.height / 2,
                        width: geometry.imageSize.width,
                        height: geometry.imageSize.height
                    )
                    layer.draw(
                        Image(decorative: image, scale: 1),
                        in: imageRect
                    )
                    let favoriteColor = bookmarks.first(where: {
                        $0.catalogCircleID == placement.circleID
                    })?.color.swiftUIColor
                    let planColor = primarySharedPlanCircles.contains(where: {
                        $0.catalogCircleID == placement.circleID
                    }) ? Color.accentColor : nil
                    if let markColor = favoriteColor ?? planColor {
                        let mark = CircleFavoriteMarkGeometry.rect(in: geometry.imageSize)
                            .offsetBy(dx: imageRect.minX, dy: imageRect.minY)
                        layer.fill(
                            Path(mark),
                            with: .color(markColor)
                        )
                    }
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

        guard !usesAuthoredMap, renderedScale >= 0.55 else { return }
        context.draw(
            Text("\(table.blockName)\(table.id.spaceNumber)")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.78)),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
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
            Path(
                ellipseIn: CGRect(
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
            pointer.move(
                to: CGPoint(
                    x: center.x + direction.dx * tipDistance,
                    y: center.y + direction.dy * tipDistance
                ))
            pointer.addLine(
                to: CGPoint(
                    x: center.x - direction.dx * baseDistance + perpendicular.dx * halfWidth,
                    y: center.y - direction.dy * baseDistance + perpendicular.dy * halfWidth
                ))
            pointer.addLine(
                to: CGPoint(
                    x: center.x - direction.dx * baseDistance - perpendicular.dx * halfWidth,
                    y: center.y - direction.dy * baseDistance - perpendicular.dy * halfWidth
                ))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(.blue))
            context.stroke(pointer, with: .color(.white), lineWidth: 1.5 / renderedScale)
        }

        let puck = Path(
            ellipseIn: CGRect(
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

    private func subspaceRect(
        tableRect: CGRect,
        orientation: CatalogMapTable.Orientation,
        subspace: Int
    ) -> CGRect {
        switch orientation {
        case .aLeft:
            return subspace == 0
                ? CGRect(
                    x: tableRect.minX, y: tableRect.minY, width: tableRect.width / 2,
                    height: tableRect.height
                )
                : CGRect(
                    x: tableRect.midX, y: tableRect.minY, width: tableRect.width / 2,
                    height: tableRect.height
                )
        case .aBottom:
            return subspace == 0
                ? CGRect(
                    x: tableRect.minX, y: tableRect.midY, width: tableRect.width,
                    height: tableRect.height / 2
                )
                : CGRect(
                    x: tableRect.minX, y: tableRect.minY, width: tableRect.width,
                    height: tableRect.height / 2
                )
        case .aRight:
            return subspace == 0
                ? CGRect(
                    x: tableRect.midX, y: tableRect.minY, width: tableRect.width / 2,
                    height: tableRect.height
                )
                : CGRect(
                    x: tableRect.minX, y: tableRect.minY, width: tableRect.width / 2,
                    height: tableRect.height
                )
        case .aTop:
            return subspace == 0
                ? CGRect(
                    x: tableRect.minX, y: tableRect.minY, width: tableRect.width,
                    height: tableRect.height / 2
                )
                : CGRect(
                    x: tableRect.minX, y: tableRect.midY, width: tableRect.width,
                    height: tableRect.height / 2
                )
        }
    }

    private func selectTable(at screenPoint: CGPoint, transform: CGAffineTransform) {
        let mapPoint = screenPoint.applying(transform.inverted())
        guard let table = scene.tables.first(where: { tableRect($0).contains(mapPoint) }) else {
            return
        }

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
    @Environment(\.appHapticFeedback) private var hapticFeedback
    @State private var copiedAddress = false

    let selection: MapScreenModel.Selection
    let bookmarks: [Int: MapBookmark]
    let dataSource: CirclemsDataSource?
    let eventNumber: Int
    let mapID: Int
    let onOpenDetail: (CatalogMapCircle, Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selection.isLoading {
                        ProgressView("Loading circles…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if selection.circles.isEmpty {
                        LucideContentUnavailableView(
                            "No circle assigned",
                            icon: "person.slash",
                            description: Text(
                                "This physical table has no public circle for the selected day.")
                        )
                    } else {
                        circleSummaries
                        locationCard
                    }
                }
                .padding()
            }
            .navigationTitle("Circle details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        LucideLabel("Close", icon: "xmark")
                    }
                    .accessibilityIdentifier("map-circle-sheet-close")
                }
            }
        }
        .onChange(of: selection.selectedCircleID) {
            copiedAddress = false
        }
        .accessibilityIdentifier("map-circle-sheet")
    }

    private var locationCard: some View {
        Button {
            let shared = SharedComiketLocation(
                eventNumber: eventNumber,
                sceneID: .init(day: selection.selectedAddress.day, mapID: mapID),
                tableID: selection.table.id,
                subspace: selection.selectedAddress.subspace
            )
            UIPasteboard.general.string =
                shared?.clipboardText(
                    locationText: selection.selectedAddress.canonicalText
                ) ?? selection.selectedAddress.canonicalText
            copiedAddress = true
            hapticFeedback?.play(.copyConfirmation)
        } label: {
            HStack(spacing: 14) {
                LucideIcon(copiedAddress ? "checkmark.circle.fill" : "mappin.and.ellipse")
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
        .accessibilityHint("Copies the venue-aware circle address and a ComiNavi link")
        .accessibilityIdentifier("map-circle-address-copy")
    }

    private var circleSummaries: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(circleGroups.indices, id: \.self) { index in
                let circles = circleGroups[index]
                let circle = circles[0]
                CircleMapSummaryCard(
                    circles: circles,
                    imageData: selection.imageDataByCircleID[circle.id],
                    dataSource: dataSource,
                    locationLabel: circles.count == 2
                        ? selection.selectedAddress.spaceCode
                        : selection.selectedAddress
                            .selecting(subspace: circle.subspace)
                            .spaceCode,
                    favoriteColor: circles.lazy.compactMap { member in
                        member.publicCircleID.flatMap { bookmarks[$0]?.color }
                    }.first,
                    onOpenDetail: {
                        onOpenDetail(circle, circles.count != 2)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map-circle-ab-summary")
    }

    private var circleGroups: [[CatalogMapCircle]] {
        guard selection.circles.count == 2,
            CatalogCirclePairing.sameIdentity(selection.circles[0], selection.circles[1])
        else { return selection.circles.map { [$0] } }
        return [selection.circles]
    }

}

private struct CircleMapSummaryCard: View {
    let circles: [CatalogMapCircle]
    let imageData: Data?
    let dataSource: CirclemsDataSource?
    let locationLabel: String
    let favoriteColor: BookmarkColor?
    let onOpenDetail: () -> Void

    @State private var catalogCircles: [CirclemsDataSchema.ComiketCircleWC] = []
    @State private var isOpeningDetail = false
    @State private var showsDetail = false
    @State private var didAutomaticallyOpenCombinedDetail = false

    var body: some View {
        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 0) {
                if !isCombinedAB {
                    Text(circle.subspace == 0 ? "A" : "B")
                        .font(.headline.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                artwork
                    .overlay(alignment: .topTrailing) {
                        Group {
                            if isOpeningDetail {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                LucideIcon("arrow.up.right")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: .circle)
                        .padding(6)
                        .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, isCombinedAB ? 10 : 0)

                VStack(alignment: .leading, spacing: 7) {
                    Text(displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(locationLabel)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !circle.penName.isEmpty {
                        Text(circle.penName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .background(
                Color(uiColor: .secondarySystemBackground)
            )
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        Color(uiColor: .separator).opacity(0.3),
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $showsDetail) {
            if !catalogCircles.isEmpty, let dataSource {
                CircleDetailView(circles: catalogCircles, dataSource: dataSource)
            }
        }
        .accessibilityLabel("Open \(displayName) details")
        .accessibilityHint("Opens the full circle detail page")
        .accessibilityIdentifier(
            "map-circle-artwork-\(isCombinedAB ? "a+b" : (circle.subspace == 0 ? "a" : "b"))"
        )
        .task {
            guard isCombinedAB, !didAutomaticallyOpenCombinedDetail else { return }
            didAutomaticallyOpenCombinedDetail = true
            openDetails()
        }
    }

    private func openDetails() {
        onOpenDetail()
        guard let dataSource else { return }

        if !catalogCircles.isEmpty {
            showsDetail = true
            return
        }
        guard !isOpeningDetail else { return }
        isOpeningDetail = true

        Task { @MainActor in
            let loaded = await withTaskGroup(
                of: CirclemsDataSchema.ComiketCircleWC?.self,
                returning: [CirclemsDataSchema.ComiketCircleWC].self
            ) { group in
                for member in circles {
                    group.addTask { [dataSource] in
                        await dataSource.getCircle(circleID: member.id)
                    }
                }
                var result: [CirclemsDataSchema.ComiketCircleWC] = []
                for await member in group {
                    if let member { result.append(member) }
                }
                return result.sorted { ($0.spaceNoSub ?? 0) < ($1.spaceNoSub ?? 0) }
            }
            catalogCircles = loaded
            isOpeningDetail = false
            showsDetail = !loaded.isEmpty
        }
    }

    private var artwork: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .aspectRatio(180 / 256, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemFill))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
        }
        .overlay {
            CircleFavoriteMark(color: favoriteColor)
        }
    }

    private var displayName: String {
        circle.circleName.isEmpty ? String(localized: "Unnamed circle") : circle.circleName
    }

    private var circle: CatalogMapCircle { circles[0] }
    private var isCombinedAB: Bool { circles.count == 2 }
}

#if DEBUG
    #Preview {
        MapView(model: .fixture())
    }
#endif
