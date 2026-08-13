import Foundation
import ImageIO
import OSLog
import Observation

@MainActor
@Observable
final class MapScreenModel {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "llc.mikunet.cominavi",
        category: "BookmarkSync"
    )
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Scope: Equatable {
        case campus
        case venue
    }

    struct Selection: Identifiable, Equatable {
        var id: CatalogMapTable.ID { table.id }

        let table: CatalogMapTable
        let preferredSubspace: Int
        var circles: [CatalogMapCircle]
        var selectedCircleID: Int?
        var imageDataByCircleID: [Int: Data]
        var isLoading: Bool
        let address: ComiketSpaceAddress

        var selectedCircle: CatalogMapCircle? {
            circles.first(where: { $0.id == selectedCircleID }) ?? circles.first
        }

        var selectedAddress: ComiketSpaceAddress {
            guard circles.count == 2,
                CatalogCirclePairing.sameIdentity(circles[0], circles[1])
            else {
                return address.selecting(subspace: selectedCircle?.subspace ?? preferredSubspace)
            }
            return ComiketSpaceAddress(
                day: address.day,
                hallName: address.hallName,
                blockName: address.blockName,
                spaceNumber: address.spaceNumber,
                subspace: nil,
                isCombinedAB: true
            )
        }
    }

    let days: [UFDSchema.Day]
    var selectedDay: Int
    var selectedMapID: Int
    private(set) var scope: Scope
    private(set) var phase: Phase = .loading
    private(set) var scene: CatalogMapScene?
    private(set) var campusScene: BigSightCampusScene?
    private(set) var visibleCirclePlacements: [CatalogMapCirclePlacement] = []
    private(set) var visibleCircleArtwork: [Int: CGImage] = [:]
    var isSearchPresented = false
    private(set) var searchQuery = ""
    private(set) var searchMatches: [CatalogMapSearchMatch] = []
    private(set) var isSearching = false
    private(set) var showsGenreOverlay = false
    private(set) var genrePlacements: [CatalogMapGenrePlacement] = []
    private(set) var bookmarks: [Int: MapBookmark] = [:]
    private(set) var bookmarkError: String?
    private(set) var sceneError: String?
    private(set) var locatedUser: LocatedMapUser?
    private(set) var destination: MapDestination?
    var selection: Selection?

    @ObservationIgnored private let catalog: any MapCatalog
    @ObservationIgnored private let detailArtworkLoader: (any CircleDetailArtworkLoading)?
    @ObservationIgnored private let userPlanStore: any UserPlanStoring
    @ObservationIgnored private let bookmarkSyncCoordinator: BookmarkSyncCoordinator?
    @ObservationIgnored let eventNumber: Int
    @ObservationIgnored private let artworkCache = NSCache<NSNumber, CGImage>()
    @ObservationIgnored private var sceneCache: [CatalogMapScene.ID: CatalogMapScene] = [:]
    @ObservationIgnored private var sceneTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var genreTask: Task<Void, Never>?
    @ObservationIgnored private var bookmarkTask: Task<Void, Never>?
    @ObservationIgnored private var bookmarkSyncTask: Task<Void, Never>?
    @ObservationIgnored private var hasAttemptedInitialBookmarkSync = false

    var halls: [UFDSchema.DayHall] {
        days.first(where: { $0.dayIndex == selectedDay })?.halls ?? []
    }

    init(
        days: [UFDSchema.Day],
        eventNumber: Int,
        selectedDay: Int? = nil,
        selectedMapID: Int? = nil,
        initialScope: Scope = .campus,
        catalog: any MapCatalog,
        detailArtworkLoader: (any CircleDetailArtworkLoading)? = nil,
        userPlanStore: any UserPlanStoring,
        bookmarkSyncCoordinator: BookmarkSyncCoordinator? = nil
    ) {
        self.days = days
        self.eventNumber = eventNumber
        let initialDay = selectedDay ?? days.first?.dayIndex ?? 1
        self.selectedDay = initialDay
        self.selectedMapID =
            selectedMapID
            ?? days.first(where: { $0.dayIndex == initialDay })?.halls.first?.externalMapId
            ?? 1
        scope = initialScope
        self.catalog = catalog
        self.detailArtworkLoader = detailArtworkLoader
        self.userPlanStore = userPlanStore
        self.bookmarkSyncCoordinator = bookmarkSyncCoordinator
        artworkCache.totalCostLimit = 24 * 1_024 * 1_024
    }

    deinit {
        sceneTask?.cancel()
        selectionTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        genreTask?.cancel()
        bookmarkTask?.cancel()
        bookmarkSyncTask?.cancel()
    }

    func load() {
        sceneTask?.cancel()
        selectionTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        genreTask?.cancel()
        bookmarkTask?.cancel()
        selection = nil
        visibleCirclePlacements = []
        visibleCircleArtwork = [:]
        searchMatches = []
        genrePlacements = []
        bookmarks = [:]
        sceneError = nil
        if locatedUser?.sceneID.day != selectedDay {
            locatedUser = nil
        }
        if destination?.sceneID.day != selectedDay {
            destination = nil
        }
        phase = .loading

        let day = selectedDay
        let mapID = selectedMapID
        let scope = scope
        let halls = halls
        let cachedScenes = sceneCache
        let eventNumber = eventNumber
        sceneTask = Task { [weak self, catalog] in
            do {
                if scope == .campus {
                    var scenes: [Int: CatalogMapScene] = [:]
                    var firstError: Error?
                    for hall in halls {
                        let sceneID = CatalogMapScene.ID(day: day, mapID: hall.externalMapId)
                        if let cachedScene = cachedScenes[sceneID] {
                            scenes[hall.externalMapId] = cachedScene
                            continue
                        }
                        do {
                            scenes[hall.externalMapId] = try await catalog.scene(
                                day: day,
                                mapID: hall.externalMapId
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            firstError = firstError ?? error
                        }
                    }
                    try Task.checkCancellation()
                    guard !scenes.isEmpty else {
                        throw firstError ?? MapScreenError.missingCampusVenues
                    }
                    guard
                        let campus = BigSightCampusLayout.make(
                            eventNumber: eventNumber,
                            day: day,
                            halls: halls,
                            scenes: scenes
                        )
                    else {
                        throw MapScreenError.missingCampusVenues
                    }
                    guard let self, self.selectedDay == day, self.scope == scope else { return }
                    for scene in scenes.values {
                        self.sceneCache[scene.id] = scene
                    }
                    self.campusScene = campus
                    self.phase = .ready
                    return
                }

                let scene = try await catalog.scene(day: day, mapID: mapID)
                try Task.checkCancellation()
                guard let self,
                    self.selectedDay == day,
                    self.selectedMapID == mapID,
                    self.scope == scope
                else {
                    return
                }
                self.sceneCache[scene.id] = scene
                self.scene = scene
                self.phase = .ready
                if self.showsGenreOverlay {
                    self.loadGenrePlacements()
                }
                if !self.searchQuery.isEmpty {
                    self.updateSearchQuery(self.searchQuery)
                }
                self.loadBookmarks()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                    self.selectedDay == day,
                    self.scope == scope,
                    scope == .campus || self.selectedMapID == mapID
                else {
                    return
                }
                if self.campusScene != nil || self.scene != nil {
                    self.phase = .ready
                    self.sceneError = error.localizedDescription
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func select(day: Int) {
        guard selectedDay != day else { return }
        selectedDay = day
        selectedMapID = halls.first?.externalMapId ?? selectedMapID
        load()
    }

    func select(mapID: Int) {
        guard scope != .venue || selectedMapID != mapID else { return }
        scope = .venue
        selectedMapID = mapID
        if let cachedScene = sceneCache[.init(day: selectedDay, mapID: mapID)]
            ?? campusScene?.venues.first(where: { $0.id == mapID })?.scene
        {
            activateVenue(cachedScene)
        } else {
            load()
        }
    }

    func showCampus() {
        guard scope != .campus else { return }
        scope = .campus
        setSearchPresented(false)
        if showsGenreOverlay {
            toggleGenreOverlay()
        }
        selection = nil
        visibleCirclePlacements = []
        visibleCircleArtwork = [:]
        searchMatches = []
        genrePlacements = []
        bookmarks = [:]
        if campusScene != nil {
            phase = .ready
        } else {
            load()
        }
    }

    func whereAmIVenues() async throws -> [WhereAmIVenueOption] {
        let day = selectedDay
        let halls = halls
        var scenes: [Int: CatalogMapScene] = [:]
        var firstError: Error?

        for hall in halls {
            let sceneID = CatalogMapScene.ID(day: day, mapID: hall.externalMapId)
            if let cached = sceneCache[sceneID] {
                scenes[hall.externalMapId] = cached
                continue
            }
            do {
                let loaded = try await catalog.scene(day: day, mapID: hall.externalMapId)
                sceneCache[loaded.id] = loaded
                scenes[hall.externalMapId] = loaded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }

        guard !scenes.isEmpty else {
            throw firstError ?? MapScreenError.missingCampusVenues
        }
        guard
            let campus = BigSightCampusLayout.make(
                eventNumber: eventNumber,
                day: day,
                halls: halls,
                scenes: scenes
            )
        else {
            throw MapScreenError.missingCampusVenues
        }
        guard selectedDay == day else { throw CancellationError() }
        campusScene = campus
        let hallsByMapID = Dictionary(uniqueKeysWithValues: halls.map { ($0.externalMapId, $0) })
        return campus.venues.map { placement in
            let hallName = hallsByMapID[placement.id]?.name ?? placement.kind.displayName
            return WhereAmIVenueOption(
                displayName: WhereAmIResolver.venueDisplayName(for: hallName),
                placement: placement
            )
        }
    }

    func locateUser(_ user: LocatedMapUser) {
        locatedUser = user
        selection = nil
        setSearchPresented(false)

        guard scope != .venue || selectedMapID != user.sceneID.mapID else { return }
        select(mapID: user.sceneID.mapID)
    }

    func show(_ destination: MapDestination) {
        self.destination = destination
        selection = nil
        setSearchPresented(false)
    }

    func clearDestination() {
        destination = nil
    }

    private func activateVenue(_ cachedScene: CatalogMapScene) {
        sceneTask?.cancel()
        selectionTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        genreTask?.cancel()
        bookmarkTask?.cancel()
        selection = nil
        scene = cachedScene
        visibleCirclePlacements = []
        visibleCircleArtwork = [:]
        searchMatches = []
        genrePlacements = []
        bookmarks = [:]
        phase = .ready
        if showsGenreOverlay {
            loadGenrePlacements()
        }
        if !searchQuery.isEmpty {
            updateSearchQuery(searchQuery)
        }
        loadBookmarks()
    }

    @discardableResult
    func locateUser(
        at point: CGPoint,
        nearest table: CatalogMapTable,
        subspace: Int,
        mapID: Int? = nil
    ) -> LocatedMapUser? {
        let targetMapID = mapID ?? selectedMapID
        let placement =
            campusScene?.venues.first { venue in
                venue.id == targetMapID && venue.scene.tableByID[table.id] == table
            } ?? standalonePlacement(mapID: targetMapID, table: table)
        guard let placement
        else {
            return nil
        }

        let hallName =
            halls.first(where: { $0.externalMapId == targetMapID })?.name
            ?? placement.kind.displayName
        let venue = WhereAmIVenueOption(
            displayName: WhereAmIResolver.venueDisplayName(for: hallName),
            placement: placement
        )
        let previous = locatedUser
        let user = WhereAmIResolver.locatedUser(
            at: table,
            in: venue,
            subspace: subspace,
            point: point,
            headingDegrees: previous?.headingDegrees,
            locationReading: previous?.locationReading,
            source: .mapLongPress
        )
        locateUser(user)
        return user
    }

    private func standalonePlacement(
        mapID: Int,
        table: CatalogMapTable
    ) -> BigSightVenuePlacement? {
        guard let scene,
            scene.id == CatalogMapScene.ID(day: selectedDay, mapID: mapID),
            scene.tableByID[table.id] == table,
            let campus = BigSightCampusLayout.make(
                eventNumber: eventNumber,
                day: selectedDay,
                halls: halls,
                scenes: [mapID: scene]
            )
        else { return nil }
        return campus.venues.first
    }

    func select(circle: CatalogMapCircle) {
        guard selection?.circles.contains(where: { $0.id == circle.id }) == true else { return }
        selection?.selectedCircleID = circle.id
    }

    func select(table: CatalogMapTable, preferredSubspace: Int) {
        selectionTask?.cancel()
        selection = Selection(
            table: table,
            preferredSubspace: preferredSubspace,
            circles: [],
            selectedCircleID: nil,
            imageDataByCircleID: [:],
            isLoading: true,
            address: ComiketSpaceAddress(
                day: selectedDay,
                hallName: table.hallName ?? fallbackHallName,
                blockName: table.blockName,
                spaceNumber: table.id.spaceNumber,
                subspace: preferredSubspace
            )
        )

        let day = selectedDay
        selectionTask = Task { [weak self, catalog] in
            do {
                let circles = try await catalog.circles(day: day, tableID: table.id)
                try Task.checkCancellation()
                guard let self, self.selection?.id == table.id else { return }
                let selected =
                    circles.first(where: { $0.subspace == preferredSubspace }) ?? circles.first
                self.selection?.circles = circles
                self.selection?.selectedCircleID = selected?.id
                self.selection?.isLoading = false

                let images = (try? await catalog.circleImages(circleIDs: circles.map(\.id))) ?? [:]
                try Task.checkCancellation()
                guard self.selection?.id == table.id else { return }
                self.selection?.imageDataByCircleID = images

                guard let detailArtworkLoader else { return }
                let bestImages = await withTaskGroup(
                    of: (Int, Data?).self,
                    returning: [Int: Data].self
                ) { group in
                    for circle in circles {
                        let fallback = images[circle.id]
                        group.addTask {
                            let image = await detailArtworkLoader.bestImageData(
                                for: circle,
                                fallback: fallback
                            )
                            return (circle.id, image)
                        }
                    }

                    var loaded: [Int: Data] = [:]
                    for await (circleID, image) in group {
                        if let image {
                            loaded[circleID] = image
                        }
                    }
                    return loaded
                }
                try Task.checkCancellation()
                guard self.selection?.id == table.id else { return }
                self.selection?.imageDataByCircleID.merge(bestImages) { _, best in best }

                let decodedBestImages = await Task.detached(priority: .userInitiated) {
                    bestImages.compactMapValues(Self.decodeImage)
                }.value
                try Task.checkCancellation()
                guard self.selection?.id == table.id else { return }
                let visibleCircleIDs = Set(self.visibleCirclePlacements.map(\.circleID))
                for (circleID, image) in decodedBestImages {
                    self.artworkCache.setObject(
                        image,
                        forKey: NSNumber(value: circleID),
                        cost: image.bytesPerRow * image.height
                    )
                    if visibleCircleIDs.contains(circleID) {
                        self.visibleCircleArtwork[circleID] = image
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.selection?.id == table.id else { return }
                self.selection?.isLoading = false
            }
        }
    }

    private var fallbackHallName: String {
        if let venue = campusScene?.venues.first(where: { $0.id == selectedMapID }) {
            return WhereAmIResolver.canonicalVenueName(for: venue.kind)
        }
        return halls.first(where: { $0.externalMapId == selectedMapID })?.name ?? "会場"
    }

    func setSearchPresented(_ isPresented: Bool) {
        isSearchPresented = isPresented
        if !isPresented {
            updateSearchQuery("")
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedQuery.isEmpty, let scene else {
            isSearching = false
            searchMatches = []
            return
        }

        isSearching = true
        let day = selectedDay
        let mapID = scene.id.mapID
        searchTask = Task { [weak self, catalog] in
            do {
                try await Task.sleep(for: .milliseconds(260))
                let matches = try await catalog.search(
                    day: day, mapID: mapID, query: normalizedQuery)
                try Task.checkCancellation()
                guard let self,
                    self.selectedDay == day,
                    self.selectedMapID == mapID,
                    self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        == normalizedQuery
                else {
                    return
                }
                self.searchMatches = matches
                self.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.searchMatches = []
                self.isSearching = false
            }
        }
    }

    func toggleGenreOverlay() {
        showsGenreOverlay.toggle()
        if showsGenreOverlay {
            loadGenrePlacements()
        } else {
            genreTask?.cancel()
            genrePlacements = []
        }
    }

    func bookmark(for circle: CatalogMapCircle?) -> MapBookmark? {
        guard let publicCircleID = circle?.publicCircleID else { return nil }
        return bookmarks[publicCircleID]
    }

    func toggleBookmark() {
        guard let selection,
            let circle = selection.selectedCircle,
            let publicCircleID = circle.publicCircleID,
            let scene
        else {
            return
        }

        AppTrack.userIntent(
            bookmarks[publicCircleID] == nil ? .favoriteAdded : .favoriteRemoved,
            data: [
                "event_number": eventNumber,
                "public_circle_id": publicCircleID,
                "source": "map",
            ]
        )
        bookmarkTask?.cancel()
        bookmarkError = nil

        if var existing = bookmarks[publicCircleID] {
            let previousBookmarks = bookmarks
            bookmarks[publicCircleID] = nil
            existing.modifiedAt = Date()
            existing.syncState = .pendingDelete
            bookmarkTask = Task { [weak self, userPlanStore] in
                do {
                    try await userPlanStore.upsert(existing)
                    guard let self else { return }
                    self.scheduleBookmarkSync()
                } catch {
                    guard let self else { return }
                    self.bookmarks = previousBookmarks
                    self.bookmarkError = error.localizedDescription
                }
            }
            return
        }

        let bookmark = MapBookmark(
            eventNumber: eventNumber,
            publicCircleID: publicCircleID,
            catalogCircleID: circle.id,
            updateID: circle.updateID,
            day: selectedDay,
            mapID: scene.id.mapID,
            tableID: selection.table.id,
            subspace: circle.subspace,
            color: .orange,
            memo: "",
            modifiedAt: Date(),
            syncState: .pendingUpsert
        )
        let previousBookmarks = bookmarks
        bookmarks[publicCircleID] = bookmark
        persist(bookmark, restoring: previousBookmarks)
    }

    func setBookmarkColor(_ color: BookmarkColor) {
        guard let selection,
            let circle = selection.selectedCircle,
            let publicCircleID = circle.publicCircleID,
            let scene
        else {
            return
        }

        AppTrack.userIntent(
            bookmarks[publicCircleID] == nil ? .favoriteAdded : .favoriteColorChanged,
            data: [
                "event_number": eventNumber,
                "public_circle_id": publicCircleID,
                "color": color.rawValue,
                "source": "map",
            ]
        )
        var bookmark =
            bookmarks[publicCircleID]
            ?? MapBookmark(
                eventNumber: eventNumber,
                publicCircleID: publicCircleID,
                catalogCircleID: circle.id,
                updateID: circle.updateID,
                day: selectedDay,
                mapID: scene.id.mapID,
                tableID: selection.table.id,
                subspace: circle.subspace,
                color: color,
                memo: "",
                modifiedAt: Date(),
                syncState: .pendingUpsert
            )
        bookmark.color = color
        bookmark.modifiedAt = Date()
        bookmark.syncState = .pendingUpsert
        let previousBookmarks = bookmarks
        bookmarks[publicCircleID] = bookmark
        persist(bookmark, restoring: previousBookmarks)
    }

    private func persist(
        _ bookmark: MapBookmark,
        restoring previousBookmarks: [Int: MapBookmark]? = nil
    ) {
        bookmarkTask?.cancel()
        bookmarkError = nil
        bookmarkTask = Task { [weak self, userPlanStore] in
            do {
                try await userPlanStore.upsert(bookmark)
                guard let self else { return }
                self.scheduleBookmarkSync()
            } catch {
                guard let self else { return }
                if let previousBookmarks {
                    self.bookmarks = previousBookmarks
                } else {
                    self.bookmarks[bookmark.publicCircleID] = nil
                }
                self.bookmarkError = error.localizedDescription
            }
        }
    }

    private func loadBookmarks() {
        bookmarkTask?.cancel()
        let day = selectedDay
        let mapID = selectedMapID
        bookmarkTask = Task { [weak self, userPlanStore, eventNumber] in
            do {
                let bookmarks = try await userPlanStore.bookmarks(
                    eventNumber: eventNumber,
                    day: day,
                    mapID: mapID
                )
                try Task.checkCancellation()
                guard let self, self.selectedDay == day, self.selectedMapID == mapID else { return }
                self.bookmarks = Dictionary(
                    uniqueKeysWithValues: bookmarks.map { ($0.publicCircleID, $0) })
                if !self.hasAttemptedInitialBookmarkSync {
                    self.hasAttemptedInitialBookmarkSync = true
                    self.scheduleBookmarkSync(delay: .zero)
                }
            } catch {
                guard let self else { return }
                self.bookmarkError = error.localizedDescription
            }
        }
    }

    private func scheduleBookmarkSync(delay: Duration = .milliseconds(350)) {
        guard let bookmarkSyncCoordinator else { return }
        bookmarkSyncTask?.cancel()
        let eventNumber = eventNumber
        let day = selectedDay
        let mapID = selectedMapID
        bookmarkSyncTask = Task { [weak self, userPlanStore] in
            do {
                if delay != .zero {
                    try await Task.sleep(for: delay)
                }
                try await bookmarkSyncCoordinator.sync()
                try Task.checkCancellation()
                let bookmarks = try await userPlanStore.bookmarks(
                    eventNumber: eventNumber,
                    day: day,
                    mapID: mapID
                )
                try Task.checkCancellation()
                guard let self else { return }
                if self.selectedDay == day, self.selectedMapID == mapID {
                    self.bookmarks = Dictionary(
                        uniqueKeysWithValues: bookmarks.map { ($0.publicCircleID, $0) })
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                Self.logger.error(
                    "Bookmark synchronization failed: \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                    print("Bookmark synchronization failed: \(error)")
                #endif
                self.bookmarkError = error.localizedDescription
            }
        }
    }

    func dismissBookmarkError() {
        bookmarkError = nil
    }

    func dismissSceneError() {
        sceneError = nil
    }

    private func loadGenrePlacements() {
        genreTask?.cancel()
        guard showsGenreOverlay, let scene else { return }
        let day = selectedDay
        let mapID = scene.id.mapID

        genreTask = Task { [weak self, catalog] in
            do {
                let placements = try await catalog.genrePlacements(day: day, mapID: mapID)
                try Task.checkCancellation()
                guard let self,
                    self.showsGenreOverlay,
                    self.selectedDay == day,
                    self.selectedMapID == mapID
                else {
                    return
                }
                self.genrePlacements = placements
            } catch {
                guard let self else { return }
                self.genrePlacements = []
            }
        }
    }

    func updateViewport(_ viewport: CatalogMapViewport) {
        guard viewport.sceneID == scene?.id else { return }
        viewportTask?.cancel()

        guard viewport.wantsCircleArtwork else {
            visibleCirclePlacements = []
            visibleCircleArtwork = [:]
            return
        }

        viewportTask = Task { [weak self, catalog] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let placements = try await catalog.circlePlacements(in: viewport)
                try Task.checkCancellation()
                guard let self, self.scene?.id == viewport.sceneID else { return }

                var artwork: [Int: CGImage] = [:]
                var missingIDs: [Int] = []
                for circleID in Set(placements.map(\.circleID)) {
                    if let cached = self.artworkCache.object(forKey: NSNumber(value: circleID)) {
                        artwork[circleID] = cached
                    } else {
                        missingIDs.append(circleID)
                    }
                }

                if !missingIDs.isEmpty {
                    let imageData = try await catalog.circleImages(circleIDs: missingIDs)
                    let decoded = await Task.detached(priority: .userInitiated) {
                        imageData.compactMapValues(Self.decodeImage)
                    }.value
                    try Task.checkCancellation()

                    for (circleID, image) in decoded {
                        self.artworkCache.setObject(
                            image,
                            forKey: NSNumber(value: circleID),
                            cost: image.bytesPerRow * image.height
                        )
                        artwork[circleID] = image
                    }
                }

                guard self.scene?.id == viewport.sceneID else { return }
                self.visibleCirclePlacements = placements
                self.visibleCircleArtwork = artwork
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.visibleCirclePlacements = []
                self.visibleCircleArtwork = [:]
            }
        }
    }

    nonisolated private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0,
            [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
    }

    #if DEBUG
        static func fixture() -> MapScreenModel {
            MapScreenModel(
                days: [
                    UFDSchema.Day(
                        id: "fixture-1",
                        dayIndex: 1,
                        date: DateComponents(year: 2026, month: 8, day: 15),
                        halls: [
                            UFDSchema.DayHall(
                                id: "fixture-hall",
                                name: "Fixture Hall",
                                mapName: "FIXTURE",
                                externalMapId: 1,
                                externalCorrespondingFloorId: 1,
                                areas: []
                            )
                        ]
                    )
                ],
                eventNumber: 104,
                initialScope: .venue,
                catalog: FixtureMapCatalog(),
                userPlanStore: InMemoryUserPlanStore()
            )
        }

        static func previewCampusFixture() -> MapScreenModel {
            MapScreenModel(
                days: [
                    UFDSchema.Day(
                        id: "campus-fixture-1",
                        dayIndex: 1,
                        date: DateComponents(year: 2026, month: 8, day: 15),
                        halls: [
                            previewHall(id: 101, name: "東123", mapName: "E123"),
                            previewHall(id: 102, name: "東7", mapName: "E7"),
                            previewHall(id: 103, name: "西12", mapName: "W12"),
                            previewHall(id: 104, name: "南12", mapName: "S12"),
                        ]
                    )
                ],
                eventNumber: 108,
                catalog: FixtureMapCatalog(),
                userPlanStore: InMemoryUserPlanStore()
            )
        }

        private static func previewHall(id: Int, name: String, mapName: String) -> UFDSchema.DayHall
        {
            UFDSchema.DayHall(
                id: "campus-fixture-hall-\(id)",
                name: name,
                mapName: mapName,
                externalMapId: id,
                externalCorrespondingFloorId: id,
                areas: []
            )
        }
    #endif
}

private enum MapScreenError: LocalizedError {
    case missingCampusVenues

    var errorDescription: String? {
        String(localized: "This catalog does not contain a recognized Tokyo Big Sight venue map.")
    }
}
