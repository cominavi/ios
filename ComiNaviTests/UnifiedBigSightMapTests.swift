import CoreGraphics
import SpriteKit
import XCTest

@testable import ComiNavi

final class UnifiedBigSightMapTests: XCTestCase {
    @MainActor
    func testPrimarySharedPlanCircleOverlayRendersWithoutFavorite() throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let planCircle = CatalogBookmarkLocation(
            publicCircleID: 100,
            catalogCircleID: 7,
            updateID: 70,
            day: 1,
            mapID: venue.id,
            tableID: table.id,
            subspace: 0
        )

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            primarySharedPlanCircles: [planCircle],
            locatedUser: nil
        )

        XCTAssertTrue(renderer.isPersistentOverlayVisible)
        XCTAssertEqual(renderer.persistentOverlayShapeCount, 1)
    }

    @MainActor
    func testSelectionFavoriteAndSearchOverlaysStayVisibleAtOverviewZoom() throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let bookmark = MapBookmark(
            eventNumber: 108,
            publicCircleID: 100,
            catalogCircleID: 7,
            updateID: 70,
            day: 1,
            mapID: venue.id,
            tableID: table.id,
            subspace: 0,
            color: .orange,
            memo: "",
            modifiedAt: .now,
            syncState: .synced
        )

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: table.id,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [
                CatalogMapSearchMatch(
                    id: 7,
                    mapID: venue.id,
                    tableID: table.id,
                    subspace: 0,
                    circleName: "一年戦争",
                    penName: "武田"
                )
            ],
            searchActive: true,
            genrePlacements: [],
            bookmarks: [bookmark],
            locatedUser: nil
        )

        XCTAssertLessThan(renderer.zoomFactor, 9)
        XCTAssertTrue(renderer.isPersistentOverlayVisible)
        XCTAssertGreaterThanOrEqual(renderer.persistentOverlayShapeCount, 3)
        XCTAssertEqual(renderer.baseMapAlpha, 0.18, accuracy: 0.001)
        XCTAssertTrue(renderer.areMapIconsHiddenForSearch)
    }

    @MainActor
    func testSearchAndFavoritesOverlayEveryVenueRegardlessOfSelectedVenue() {
        let tableID = CatalogMapTable.ID(blockID: 1, spaceNumber: 1)
        let firstScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "First Hall",
            size: CGSize(width: 400, height: 400),
            tableSize: CGSize(width: 40, height: 40),
            tables: [
                CatalogMapTable(
                    id: tableID,
                    blockName: "A",
                    origin: CGPoint(x: 100, y: 100),
                    orientation: .aLeft
                )
            ]
        )
        let secondScene = CatalogMapScene(
            id: .init(day: 1, mapID: 2),
            name: "Second Hall",
            size: CGSize(width: 400, height: 400),
            tableSize: CGSize(width: 40, height: 40),
            tables: [
                CatalogMapTable(
                    id: tableID,
                    blockName: "A",
                    origin: CGPoint(x: 100, y: 100),
                    orientation: .aLeft
                )
            ]
        )
        let firstVenue = BigSightVenuePlacement(
            kind: .east123,
            scene: firstScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: CGPoint(x: -30, y: 0),
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let secondVenue = BigSightVenuePlacement(
            kind: .west,
            scene: secondScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: CGPoint(x: 30, y: 0),
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: [firstVenue.id, secondVenue.id]),
            venues: [firstVenue, secondVenue],
            connections: [],
            bounds: firstVenue.bounds.union(secondVenue.bounds).insetBy(dx: -20, dy: -20)
        )
        let renderer = UnifiedBigSightScene(campus: campus)

        renderer.update(
            campus: campus,
            scope: .campus,
            selectedMapID: firstVenue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [
                CatalogMapSearchMatch(
                    id: 7,
                    mapID: firstVenue.id,
                    tableID: tableID,
                    subspace: 0,
                    circleName: "First Circle",
                    penName: "Creator"
                ),
                CatalogMapSearchMatch(
                    id: 8,
                    mapID: secondVenue.id,
                    tableID: tableID,
                    subspace: 1,
                    circleName: "Second Circle",
                    penName: "Creator"
                ),
            ],
            searchActive: true,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil
        )

        XCTAssertEqual(renderer.persistentOverlayShapeCount, 2)
        XCTAssertTrue(renderer.areMapIconsHiddenForSearch)

        let bookmarks = [
            MapBookmark(
                eventNumber: 108,
                publicCircleID: 100,
                catalogCircleID: 7,
                updateID: 70,
                day: 1,
                mapID: firstVenue.id,
                tableID: tableID,
                subspace: 0,
                color: .orange,
                memo: "",
                modifiedAt: .now,
                syncState: .synced
            ),
            MapBookmark(
                eventNumber: 108,
                publicCircleID: 200,
                catalogCircleID: 8,
                updateID: 80,
                day: 1,
                mapID: secondVenue.id,
                tableID: tableID,
                subspace: 1,
                color: .magenta,
                memo: "",
                modifiedAt: .now,
                syncState: .synced
            ),
        ]

        for selectedVenue in [firstVenue, secondVenue] {
            renderer.update(
                campus: campus,
                scope: .venue,
                selectedMapID: selectedVenue.id,
                selectedTableID: nil,
                circlePlacements: [],
                circleArtwork: [:],
                searchMatches: [],
                searchActive: false,
                genrePlacements: [],
                bookmarks: bookmarks,
                locatedUser: nil
            )

            XCTAssertEqual(
                renderer.persistentOverlayShapeCount,
                2,
                "Changing the venue shortcut must not filter favorites from other venues."
            )
        }
    }

    func testAllComiNaviBigSightSVGsCompileAsImageAssets() {
        for icon in BigSightMapIcon.allCases {
            guard let assetName = icon.assetName else { continue }
            XCTAssertNotNil(UIImage(named: assetName), "Missing vector asset \(assetName)")
        }
    }

    func testMapIconAccentsPreserveVenueTransitAndSafetySemantics() {
        XCTAssertEqual(BigSightMapIcon.eastHalls.accent, .red)
        XCTAssertEqual(BigSightMapIcon.westHalls.accent, .blue)
        XCTAssertEqual(BigSightMapIcon.southHalls.accent, .green)
        XCTAssertEqual(BigSightMapIcon.train.accent, .amber)
        XCTAssertEqual(BigSightMapIcon.aed.accent, .red)
        XCTAssertEqual(BigSightMapIcon.firstAidRoom.accent, .green)
        XCTAssertEqual(BigSightMapIcon.restroom.accent, .ink)
    }

    func testTransitIconsUseOriginalYellowCircularBackdrop() {
        XCTAssertEqual(BigSightMapIcon.bus.backdrop, .transitYellowCircle)
        XCTAssertEqual(BigSightMapIcon.taxi.backdrop, .transitYellowCircle)
        XCTAssertEqual(BigSightMapIcon.train.backdrop, .transitYellowCircle)
        XCTAssertEqual(BigSightMapIcon.waterBus.backdrop, .transitYellowCircle)

        XCTAssertEqual(BigSightMapIcon.restroom.backdrop, .standard)
        XCTAssertEqual(BigSightMapIcon.information.backdrop, .standard)
    }

    func testVenueIconsUseBilingualBadgesWithoutSourceArtworkAssets() throws {
        let east = try XCTUnwrap(BigSightMapIcon.eastHalls.venueBadge)
        let west = try XCTUnwrap(BigSightMapIcon.westHalls.venueBadge)
        let south = try XCTUnwrap(BigSightMapIcon.southHalls.venueBadge)

        XCTAssertEqual(east.japanese, "東")
        XCTAssertEqual(east.english, "EAST")
        XCTAssertEqual(
            east.color, .init(red: 216.0 / 255.0, green: 11.0 / 255.0, blue: 42.0 / 255.0))

        XCTAssertEqual(west.japanese, "西")
        XCTAssertEqual(west.english, "WEST")
        XCTAssertEqual(west.color, .init(red: 0, green: 85.0 / 255.0, blue: 157.0 / 255.0))

        XCTAssertEqual(south.japanese, "南")
        XCTAssertEqual(south.english, "SOUTH")
        XCTAssertEqual(south.color, .init(red: 0, green: 169.0 / 255.0, blue: 58.0 / 255.0))

        XCTAssertEqual(BigSightMapIcon.eastHalls.backdrop, .venueBilingualBadge)
        XCTAssertEqual(BigSightMapIcon.westHalls.backdrop, .venueBilingualBadge)
        XCTAssertEqual(BigSightMapIcon.southHalls.backdrop, .venueBilingualBadge)
        XCTAssertNil(BigSightMapIcon.eastHalls.assetName)
        XCTAssertNil(BigSightMapIcon.westHalls.assetName)
        XCTAssertNil(BigSightMapIcon.southHalls.assetName)
    }

    func testNonHallMapIconsUseCompactMarkerMetrics() {
        XCTAssertEqual(UnifiedMapMarkerMetrics.venueIconSize, 32)
        XCTAssertEqual(UnifiedMapMarkerMetrics.facilityIconSize(for: .information), 18)
        XCTAssertEqual(UnifiedMapMarkerMetrics.facilityIconSize(for: .conferenceTower), 22)
        XCTAssertEqual(
            UnifiedMapMarkerMetrics.backingSize(
                for: .eastHalls,
                iconSize: UnifiedMapMarkerMetrics.venueIconSize
            ),
            42
        )
        XCTAssertEqual(
            UnifiedMapMarkerMetrics.backingSize(
                for: .information,
                iconSize: UnifiedMapMarkerMetrics.facilityIconSize(for: .information)
            ),
            24
        )
        XCTAssertEqual(
            UnifiedMapMarkerMetrics.backingSize(
                for: .conferenceTower,
                iconSize: UnifiedMapMarkerMetrics.facilityIconSize(for: .conferenceTower)
            ),
            28
        )
    }

    @MainActor
    func testNonHallMapMarkersRenderCompactBackingBounds() throws {
        let baseCampus = makeSingleVenueCampus()
        let facilities = [
            BigSightFacilityLocation(
                id: "information",
                name: "Information",
                kind: .information,
                coordinate: BigSightCampusLayout.eastBuilding,
                minimumZoom: 0
            ),
            BigSightFacilityLocation(
                id: "conference-tower",
                name: "Conference Tower",
                kind: .conferenceTower,
                coordinate: BigSightCampusLayout.eastBuilding,
                minimumZoom: 0
            ),
        ]
        let campus = BigSightCampusScene(
            id: baseCampus.id,
            venues: baseCampus.venues,
            connections: baseCampus.connections,
            facilities: facilities,
            bounds: baseCampus.bounds
        )
        let renderer = UnifiedBigSightScene(campus: campus)

        func backingBounds(for icon: BigSightMapIcon) throws -> CGSize {
            let backing = try XCTUnwrap(
                renderer.childNode(
                    withName: "//map-marker-backdrop-\(icon.rawValue)"
                ) as? SKShapeNode
            )
            return try XCTUnwrap(backing.path).boundingBoxOfPath.size
        }

        XCTAssertEqual(try backingBounds(for: .eastHalls), CGSize(width: 42, height: 42))
        XCTAssertEqual(try backingBounds(for: .information), CGSize(width: 24, height: 24))
        XCTAssertEqual(
            try backingBounds(for: .conferenceTower),
            CGSize(width: 28, height: 28)
        )
    }

    func testCampusSceneProjectionRoundTrips() {
        let campusPoint = CGPoint(x: 173.25, y: -84.5)
        let scenePoint = UnifiedMapProjection.scenePoint(fromCampus: campusPoint)

        XCTAssertEqual(scenePoint.x, 173.25, accuracy: 0.000_1)
        XCTAssertEqual(scenePoint.y, 84.5, accuracy: 0.000_1)
        XCTAssertEqual(UnifiedMapProjection.campusPoint(fromScene: scenePoint), campusPoint)
    }

    func testCampusBoundaryAllowsOneHundredAdditionalMetersNorth() throws {
        let hall = UFDSchema.DayHall(
            id: "east-123",
            name: "東123",
            mapName: "E123",
            externalMapId: 1,
            externalCorrespondingFloorId: 1,
            areas: []
        )
        let scene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "E123",
            size: CGSize(width: 4_680, height: 1_680),
            tableSize: CGSize(width: 40, height: 40),
            tables: []
        )
        let campus = try XCTUnwrap(
            BigSightCampusLayout.make(
                eventNumber: 104,
                day: 1,
                halls: [hall],
                scenes: [1: scene]
            )
        )

        var occupiedBounds = try XCTUnwrap(campus.venues.first).bounds
        for point in campus.connections.flatMap(\.points) {
            occupiedBounds = occupiedBounds.union(
                CGRect(x: point.x, y: point.y, width: 1, height: 1)
            )
        }
        for point in campus.openStreetMapFeatures.flatMap(\.points) {
            occupiedBounds = occupiedBounds.union(
                CGRect(x: point.x, y: point.y, width: 1, height: 1)
            )
        }
        for facility in campus.facilities {
            occupiedBounds = occupiedBounds.union(
                CGRect(x: facility.center.x, y: facility.center.y, width: 1, height: 1)
            )
        }
        let standardBounds = occupiedBounds.insetBy(
            dx: -BigSightCampusLayout.mapBoundaryPaddingMeters,
            dy: -BigSightCampusLayout.mapBoundaryPaddingMeters
        )

        XCTAssertEqual(campus.bounds.minX, standardBounds.minX, accuracy: 0.001)
        XCTAssertEqual(campus.bounds.maxX, standardBounds.maxX, accuracy: 0.001)
        XCTAssertEqual(campus.bounds.maxY, standardBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(
            campus.bounds.minY,
            standardBounds.minY - BigSightCampusLayout.additionalNorthBoundaryMeters,
            accuracy: 0.001
        )
    }

    @MainActor
    func testCampusLongPressResolvesNearestTableFromAisleWithoutSelectedVenue() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let localPoint = CGPoint(x: 190, y: 165)
        let campusPoint = localPoint.applying(venue.transform)
        let renderer = UnifiedBigSightScene(campus: campus)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(40))
        let viewPoint = renderer.viewPoint(forCampus: campusPoint, in: view)

        let locationHit = try XCTUnwrap(renderer.locationHit(at: viewPoint, in: view))
        XCTAssertEqual(locationHit.mapID, venue.id)
        XCTAssertEqual(locationHit.table, table)
        XCTAssertEqual(locationHit.localPoint.x, localPoint.x, accuracy: 0.01)
        XCTAssertEqual(locationHit.localPoint.y, localPoint.y, accuracy: 0.01)
    }

    @MainActor
    func testOpenStreetMapFeaturesRenderAboveVenueArtwork() throws {
        let hall = UFDSchema.DayHall(
            id: "east-123",
            name: "東123",
            mapName: "E123",
            externalMapId: 1,
            externalCorrespondingFloorId: 1,
            areas: []
        )
        let scene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "E123",
            size: CGSize(width: 4_680, height: 1_680),
            tableSize: CGSize(width: 40, height: 40),
            tables: []
        )
        let campus = try XCTUnwrap(
            BigSightCampusLayout.make(
                eventNumber: 104,
                day: 1,
                halls: [hall],
                scenes: [1: scene]
            ))

        XCTAssertEqual(
            UnifiedBigSightScene(campus: campus).openStreetMapFeatureNodeCount,
            campus.openStreetMapFeatures.count
        )
    }

    func testBasemapZoomTracksSpriteKitMetersPerPoint() {
        let oneMeter = UnifiedBasemapCamera.zoomLevel(
            metersPerPoint: 1,
            latitude: BigSightCampusLayout.eastBuilding.latitude
        )
        let halfMeter = UnifiedBasemapCamera.zoomLevel(
            metersPerPoint: 0.5,
            latitude: BigSightCampusLayout.eastBuilding.latitude
        )

        XCTAssertEqual(halfMeter, oneMeter + 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(oneMeter, 15)
        XCTAssertLessThan(oneMeter, 17)
    }

    @MainActor
    func testDarkAppearanceUsesBundledStyleAndDarkChrome() throws {
        let host = UnifiedMapHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            appearance: .light
        )
        XCTAssertEqual(
            host.basemapView.styleURL?.absoluteString, "https://americanamap.org/style.json")

        host.updateAppearance(.dark)

        XCTAssertEqual(host.basemapView.styleURL?.lastPathComponent, "AmericanaDark.json")
        XCTAssertTrue(host.basemapView.styleURL?.isFileURL == true)
        XCTAssertLessThan(luminance(host.backgroundColor), 0.1)
    }

    func testDarkPalettePreservesContrastForMapGeometry() {
        let palette = UnifiedMapAppearance.dark.palette

        XCTAssertLessThan(luminance(palette.mapBackground), 0.1)
        XCTAssertGreaterThan(luminance(palette.primaryText), 0.75)
        XCTAssertLessThan(luminance(palette.chromeBackground), 0.15)
        XCTAssertGreaterThan(luminance(palette.iconBackground), 0.85)
        XCTAssertGreaterThan(
            abs(luminance(palette.floorStroke) - luminance(palette.floor)),
            0.15
        )
    }

    @MainActor
    func testDarkAppearanceAdaptsAuthoredVenueArtwork() throws {
        let image = try XCTUnwrap(makeImage(width: 240, height: 160))
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Test Hall",
            size: CGSize(width: 240, height: 160),
            tableSize: CGSize(width: 40, height: 40),
            tables: [],
            artwork: CatalogMapArtwork(
                name: "TestArtwork",
                pixelSize: CGSize(width: 240, height: 160),
                image: image
            )
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: .zero,
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )

        XCTAssertEqual(UnifiedBigSightScene(campus: campus).darkArtworkNodeCount, 0)
        XCTAssertEqual(
            UnifiedBigSightScene(campus: campus, appearance: .dark).darkArtworkNodeCount,
            1
        )
    }

    @MainActor
    func testAppearanceChangePreservesCameraRegistration() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.layoutIfNeeded()
        host.mapView.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(40))

        renderer.zoom(by: 2.4, around: CGPoint(x: 104, y: 612), in: host.mapView)
        renderer.rotate(by: .pi / 7, around: CGPoint(x: 104, y: 612), in: host.mapView)
        host.updateBasemap(camera: renderer.basemapCamera)
        let cameraBeforeChange = renderer.basemapCamera

        host.updateAppearance(.dark)
        renderer.updateAppearance(.dark)
        host.updateBasemap(camera: renderer.basemapCamera)

        XCTAssertEqual(renderer.basemapCamera, cameraBeforeChange)
        let center = renderer.cameraCampusCenter
        let sample = CGPoint(
            x: center.x + renderer.cameraMetersPerPoint * 120,
            y: center.y + renderer.cameraMetersPerPoint * 70
        )
        let residual = host.alignmentResidual(at: sample, renderer: renderer)
        XCTAssertLessThan(abs(residual.dx), 0.75)
        XCTAssertLessThan(abs(residual.dy), 0.75)
    }

    func testVenueProjectionMatchesPlacementTransform() {
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 7),
            name: "Test Hall",
            size: CGSize(width: 1_000, height: 600),
            tableSize: CGSize(width: 40, height: 40),
            tables: []
        )
        let venue = BigSightVenuePlacement(
            kind: .east7,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: CGPoint(x: 280, y: -130),
            rotation: .pi / 5,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let localPoint = CGPoint(x: 360, y: 220)
        let expected = UnifiedMapProjection.scenePoint(
            fromCampus: localPoint.applying(venue.transform)
        )
        let projected = localPoint.applying(UnifiedMapProjection.sceneTransform(for: venue))

        XCTAssertEqual(projected.x, expected.x, accuracy: 0.000_1)
        XCTAssertEqual(projected.y, expected.y, accuracy: 0.000_1)
    }

    @MainActor
    func testStaticGeometryBatchesTablesByBlock() {
        var tables: [CatalogMapTable] = []
        tables.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let table = CatalogMapTable(
                id: .init(blockID: index / 100, spaceNumber: index % 100),
                blockName: "B\(index / 100)",
                origin: CGPoint(x: (index % 50) * 42, y: (index / 50) * 42),
                orientation: .aLeft
            )
            tables.append(table)
        }
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Dense Hall",
            size: CGSize(width: 2_200, height: 900),
            tableSize: CGSize(width: 40, height: 40),
            tables: tables
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: .zero,
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )

        let renderer = UnifiedBigSightScene(campus: campus)

        XCTAssertEqual(catalogScene.tables.count, 1_000)
        XCTAssertLessThan(renderer.staticShapeNodeCount, 40)
    }

    @MainActor
    func testCircleArtworkUsesDecodedRatioAndComposesTableWithVenueRotation() async throws {
        let table = CatalogMapTable(
            id: .init(blockID: 1, spaceNumber: 1),
            blockName: "A",
            origin: CGPoint(x: 80, y: 80),
            orientation: .aBottom
        )
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Test Hall",
            size: CGSize(width: 240, height: 240),
            tableSize: CGSize(width: 40, height: 40),
            tables: [table]
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: .zero,
            rotation: .pi / 6,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint,
            verticalMetersPerMapPoint: 0.052
        )
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )
        let renderer = UnifiedBigSightScene(campus: campus)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        renderer.zoom(by: 100, around: CGPoint(x: 195, y: 422), in: view)

        let image = try XCTUnwrap(makeImage(width: 180, height: 256))
        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: 1,
            selectedTableID: nil,
            circlePlacements: [
                CatalogMapCirclePlacement(circleID: 7, tableID: table.id, subspace: 0)
            ],
            circleArtwork: [7: image],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil
        )

        let sprite = try XCTUnwrap(renderer.circleArtworkNodes.first)
        let expected = CatalogCircleArtworkGeometry.fitting(
            pixelSize: CGSize(width: 180, height: 256),
            in: CGSize(width: 40, height: 20),
            orientation: .aBottom
        )
        XCTAssertEqual(
            sprite.size.width, expected.imageSize.width * venue.metersPerMapPoint,
            accuracy: 0.000_001)
        XCTAssertEqual(
            sprite.size.height,
            expected.imageSize.height * venue.verticalMetersPerMapPoint,
            accuracy: 0.000_001
        )
        XCTAssertEqual(sprite.zRotation, -venue.rotation - expected.rotation, accuracy: 0.000_001)
    }

    @MainActor
    func testVisibleGuidedLocationKeepsTheExistingCamera() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil
        )
        renderer.didFinishUpdate()
        let cameraBeforeLocation = renderer.basemapCamera
        let centerBeforeLocation = renderer.cameraCampusCenter
        let scaleBeforeLocation = renderer.cameraMetersPerPoint
        let rotationBeforeLocation = renderer.cameraRotation
        let user = WhereAmIResolver.locatedUser(
            at: table,
            in: WhereAmIVenueOption(displayName: "Test Hall", placement: venue),
            subspace: nil,
            point: CGPoint(
                x: venue.scene.size.width / 2,
                y: venue.scene.size.height / 2
            ),
            headingDegrees: 72,
            locationReading: nil,
            placedAt: Date(timeIntervalSince1970: 100)
        )

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: user,
            locationFocusBottomInset: 0
        )
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        XCTAssertEqual(renderer.userMarkerCount, 1)
        XCTAssertEqual(renderer.userHeadingIndicatorCount, 1)
        XCTAssertEqual(renderer.basemapCamera, cameraBeforeLocation)
        XCTAssertEqual(renderer.cameraCampusCenter.x, centerBeforeLocation.x, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraCampusCenter.y, centerBeforeLocation.y, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraMetersPerPoint, scaleBeforeLocation, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraRotation, rotationBeforeLocation, accuracy: 0.000_001)
        let markerPoint = try XCTUnwrap(renderer.userMarkerViewPoint(in: view))
        guard case .userLocation = renderer.hit(at: markerPoint, in: view) else {
            return XCTFail("The current-location marker should win map hit testing")
        }
    }

    @MainActor
    func testOffscreenLocationOnlyZoomsOutAndPreservesRotation() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil
        )
        renderer.didFinishUpdate()

        let bottomInset: CGFloat = 430
        let visibleCenter = MapCameraMath.visibleViewportCenter(
            viewportSize: view.bounds.size,
            bottomInset: bottomInset
        )
        renderer.rotate(by: .pi / 5, around: visibleCenter, in: view)
        renderer.zoom(by: 8, around: visibleCenter, in: view)
        let user = WhereAmIResolver.locatedUser(
            at: table,
            in: WhereAmIVenueOption(displayName: "Test Hall", placement: venue),
            subspace: nil,
            point: CGPoint(
                x: venue.scene.size.width / 2,
                y: venue.scene.size.height / 2
            ),
            headingDegrees: 72,
            locationReading: nil,
            placedAt: Date(timeIntervalSince1970: 100)
        )
        let campusPoint = user.point.applying(venue.transform)
        let markerPadding = MapCameraMath.locationMarkerViewportPadding
        let safeRect = CGRect(
            x: markerPadding,
            y: markerPadding,
            width: view.bounds.width - markerPadding * 2,
            height: view.bounds.height - bottomInset - markerPadding * 2
        )
        for _ in 0..<6
        where safeRect.contains(renderer.viewPoint(forCampus: campusPoint, in: view)) {
            renderer.pan(by: CGPoint(x: 120, y: 120), in: view)
        }
        let locationBeforeFocus = renderer.viewPoint(forCampus: campusPoint, in: view)
        XCTAssertFalse(safeRect.contains(locationBeforeFocus))

        let anchoredScenePointBefore = renderer.convertPoint(fromView: visibleCenter)
        let scaleBeforeFocus = renderer.cameraMetersPerPoint
        let rotationBeforeFocus = renderer.cameraRotation

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: user,
            locationFocusBottomInset: bottomInset
        )
        renderer.didFinishUpdate()

        let locationAfterFocus = renderer.viewPoint(forCampus: campusPoint, in: view)
        let anchoredScenePointAfter = renderer.convertPoint(fromView: visibleCenter)
        XCTAssertTrue(safeRect.insetBy(dx: -0.5, dy: -0.5).contains(locationAfterFocus))
        XCTAssertGreaterThan(renderer.cameraMetersPerPoint, scaleBeforeFocus)
        XCTAssertEqual(renderer.cameraRotation, rotationBeforeFocus, accuracy: 0.000_001)
        XCTAssertEqual(
            anchoredScenePointAfter.x,
            anchoredScenePointBefore.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            anchoredScenePointAfter.y,
            anchoredScenePointBefore.y,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(hypot(
            locationAfterFocus.x - visibleCenter.x,
            locationAfterFocus.y - visibleCenter.y
        ), 1)
    }

    @MainActor
    func testSamePlacementHeadingUpdateRedrawsArrowWithoutRefocusingCamera() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let venueOption = WhereAmIVenueOption(displayName: "Test Hall", placement: venue)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        let placedAt = Date(timeIntervalSince1970: 100)
        let point = CGPoint(
            x: venue.scene.size.width / 2,
            y: venue.scene.size.height / 2
        )
        let initialUser = WhereAmIResolver.locatedUser(
            at: table,
            in: venueOption,
            subspace: 0,
            point: point,
            headingDegrees: 72,
            locationReading: nil,
            source: .gps,
            placedAt: placedAt
        )

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: initialUser
        )
        renderer.didFinishUpdate()

        let initialArrowRotation = try XCTUnwrap(renderer.userHeadingIndicatorRotation)
        let initialOverlayRebuildCount = renderer.dynamicOverlayRebuildCount
        let focusedCamera = renderer.basemapCamera
        let focusedCenter = renderer.cameraCampusCenter
        let focusedScale = renderer.cameraMetersPerPoint
        let focusedRotation = renderer.cameraRotation
        let updatedUser = WhereAmIResolver.locatedUser(
            at: table,
            in: venueOption,
            subspace: 0,
            point: point,
            headingDegrees: 144,
            locationReading: nil,
            source: .gps,
            placedAt: placedAt
        )

        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: updatedUser
        )

        let updatedArrowRotation = try XCTUnwrap(renderer.userHeadingIndicatorRotation)
        XCTAssertEqual(initialArrowRotation, -CGFloat(72 * Double.pi / 180), accuracy: 0.000_001)
        XCTAssertEqual(updatedArrowRotation, -CGFloat(144 * Double.pi / 180), accuracy: 0.000_001)
        XCTAssertNotEqual(updatedArrowRotation, initialArrowRotation)
        XCTAssertEqual(renderer.dynamicOverlayRebuildCount, initialOverlayRebuildCount)
        XCTAssertEqual(renderer.basemapCamera, focusedCamera)
        XCTAssertEqual(renderer.cameraCampusCenter.x, focusedCenter.x, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraCampusCenter.y, focusedCenter.y, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraMetersPerPoint, focusedScale, accuracy: 0.000_001)
        XCTAssertEqual(renderer.cameraRotation, focusedRotation, accuracy: 0.000_001)
    }

    @MainActor
    func testZoomKeepsGestureOriginOverSameWorldPoint() async throws {
        let campus = makeSingleVenueCampus()
        let renderer = UnifiedBigSightScene(campus: campus)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        controller.view = view
        let window = UIWindow(frame: view.bounds)
        window.rootViewController = controller
        window.isHidden = false
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        // Keep the origin inside the fitted content so edge clamping is not
        // expected to override the anchor-preserving camera adjustment.
        let gestureOrigin = CGPoint(x: 160, y: 500)
        let before = renderer.convertPoint(fromView: gestureOrigin)

        renderer.zoom(by: 2.3, around: gestureOrigin, in: view)
        try await Task.sleep(for: .milliseconds(30))

        let after = renderer.convertPoint(fromView: gestureOrigin)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        window.isHidden = true
    }

    @MainActor
    func testEdgeCircleCanBeCenteredAtDetailAndMaximumZoom() async throws {
        let baseCampus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(baseCampus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let campus = BigSightCampusScene(
            id: baseCampus.id,
            venues: baseCampus.venues,
            connections: [],
            bounds: venue.bounds
        )
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        let destination = MapDestination(
            sceneID: venue.scene.id,
            tableID: table.id,
            blockName: table.blockName,
            subspace: 0,
            venueDisplayName: "Test Hall",
            canonicalVenueName: "Test Hall",
            point: table.origin,
            selectedAt: Date(timeIntervalSince1970: 500)
        )
        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: table.id,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil,
            destination: destination
        )
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let campusPoint = table.origin.applying(venue.transform)
        var onScreen = renderer.viewPoint(forCampus: campusPoint, in: view)
        XCTAssertEqual(onScreen.x, center.x, accuracy: 0.5)
        XCTAssertEqual(onScreen.y, center.y, accuracy: 0.5)

        renderer.zoom(by: 100, around: center, in: view)
        renderer.didFinishUpdate()
        onScreen = renderer.viewPoint(forCampus: campusPoint, in: view)
        XCTAssertEqual(onScreen.x, center.x, accuracy: 0.5)
        XCTAssertEqual(onScreen.y, center.y, accuracy: 0.5)
    }

    @MainActor
    func testPositiveRotationGestureTurnsMapClockwise() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        controller.view = view
        let window = UIWindow(frame: view.bounds)
        window.rootViewController = controller
        window.isHidden = false
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        let pivot = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let center = renderer.cameraCampusCenter
        let eastControlPoint = CGPoint(
            x: center.x + renderer.cameraMetersPerPoint * 100,
            y: center.y
        )
        let before = renderer.viewPoint(forCampus: eastControlPoint, in: view)

        renderer.rotate(by: .pi / 4, around: pivot, in: view)

        let after = renderer.viewPoint(forCampus: eastControlPoint, in: view)
        XCTAssertLessThan(after.x, before.x)
        XCTAssertGreaterThan(after.y, before.y)
        window.isHidden = true
    }

    @MainActor
    func testInitialLayoutSynchronizesBasemapWithoutGesture() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
        let host = UnifiedMapHostView(frame: .zero)
        host.mapView.presentScene(renderer)

        // Match SwiftUI's lifecycle: the representable is created at zero size,
        // receives its initial camera, and is laid out only afterward.
        host.updateBasemap(camera: renderer.basemapCamera)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let expected = renderer.basemapCamera
        XCTAssertEqual(
            host.basemapView.centerCoordinate.latitude,
            expected.coordinate.latitude,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            host.basemapView.centerCoordinate.longitude,
            expected.coordinate.longitude,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(host.basemapView.zoomLevel, expected.zoomLevel, accuracy: 0.001)
        XCTAssertGreaterThan(host.basemapView.zoomLevel, 10)
    }

    @MainActor
    func testAttributionBadgeIsCompactAndClearsTrailingMapControls() throws {
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let badge = try XCTUnwrap(
            host.subviews
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "map-data-attribution-button" }
        )

        XCTAssertEqual(
            badge.frame.maxX,
            host.compassButton.frame.minX - MapChromeLayout.controlSpacing,
            accuracy: 0.5
        )
        XCTAssertLessThan(badge.frame.width, 100)
        XCTAssertLessThan(badge.frame.height, 24)
        XCTAssertEqual(badge.titleLabel?.font.pointSize ?? 0, 8, accuracy: 0.1)
        XCTAssertEqual(badge.configuration?.title, "© OpenStreetMap")
        XCTAssertEqual(badge.menu?.title, "Map data attribution")
        XCTAssertEqual(badge.menu?.children.count, 4)

        XCTAssertFalse(host.compassButton.isHidden)
        XCTAssertEqual(
            host.compassButton.frame.maxY,
            844 - MapChromeLayout.edgeInset,
            accuracy: 0.5
        )
    }

    @MainActor
    func testCompassIndicatorPointsTowardRenderedNorth() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = UnifiedBigSightMapView.Coordinator()
        var publishedRotation: CGFloat?
        coordinator.connect(host: host, renderer: renderer)
        coordinator.updateCallbacks(
            onSelectVenue: { _ in },
            onShowCampus: {},
            onSelectTable: { _, _ in },
            onSelectLocatedUser: {},
            onCameraRotationChange: { publishedRotation = $0 },
            onLocate: { _, _, _, _ in }
        )
        let controller = UIViewController()
        controller.view = host
        let window = UIWindow(frame: host.bounds)
        window.rootViewController = controller
        window.isHidden = false
        host.setNeedsLayout()
        host.layoutIfNeeded()
        host.mapView.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        let pivot = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        renderer.rotate(by: .pi / 4, around: pivot, in: host.mapView)
        renderer.onCameraChange?()
        XCTAssertTrue(host.compassButton.usesTwoToneNeedle)
        XCTAssertEqual(publishedRotation, renderer.cameraRotation)

        let center = renderer.cameraCampusCenter
        let north = CGPoint(
            x: center.x,
            y: center.y - renderer.cameraMetersPerPoint * 100
        )
        let centerOnScreen = renderer.viewPoint(forCampus: center, in: host.mapView)
        let northOnScreen = renderer.viewPoint(forCampus: north, in: host.mapView)
        let renderedNorth = CGVector(
            dx: northOnScreen.x - centerOnScreen.x,
            dy: northOnScreen.y - centerOnScreen.y
        )
        let indicatorNorth = host.compassButton.indicatedNorthVector

        XCTAssertEqual(
            atan2(indicatorNorth.dy, indicatorNorth.dx),
            atan2(renderedNorth.dy, renderedNorth.dx),
            accuracy: 0.000_1
        )
        window.isHidden = true
    }

    @MainActor
    func testCompassCyclesNorthGridNorthAndReturnsFreeRotationToNorth() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGridAlignedCampus())
        renderer.reduceMotion = true
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = UnifiedBigSightMapView.Coordinator()
        coordinator.connect(host: host, renderer: renderer)
        let controller = UIViewController()
        controller.view = host
        let window = UIWindow(frame: host.bounds)
        window.rootViewController = controller
        window.isHidden = false
        host.mapView.presentScene(renderer)
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(host.compassButton.isHidden)
        XCTAssertEqual(
            host.compassButton.accessibilityLabel,
            String(localized: "Align map to venue grid")
        )

        host.compassButton.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(
            renderer.cameraRotation,
            renderer.gridAlignedCameraRotation,
            accuracy: 0.000_001
        )
        XCTAssertTrue(host.compassButton.isGridAligned)
        XCTAssertEqual(
            host.compassButton.accessibilityValue,
            String(localized: "Grid aligned")
        )

        host.compassButton.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(renderer.cameraRotation, 0, accuracy: 0.000_001)
        XCTAssertFalse(host.compassButton.isGridAligned)

        renderer.rotate(
            by: .pi / 5,
            around: CGPoint(x: host.bounds.midX, y: host.bounds.midY),
            in: host.mapView
        )
        renderer.onCameraChange?()
        host.compassButton.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(renderer.cameraRotation, 0, accuracy: 0.000_001)

        withExtendedLifetime(coordinator) {}
        window.isHidden = true
    }

    func testMarkerOpacityFadesAtBothZoomBoundaries() {
        XCTAssertEqual(
            UnifiedMapLevelOfDetail.opacity(at: 2, minimumZoom: 2, maximumZoom: 10),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            UnifiedMapLevelOfDetail.opacity(at: 2.5, minimumZoom: 2, maximumZoom: 10),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            UnifiedMapLevelOfDetail.opacity(at: 5, minimumZoom: 2, maximumZoom: 10),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            UnifiedMapLevelOfDetail.opacity(at: 9.5, minimumZoom: 2, maximumZoom: 10),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            UnifiedMapLevelOfDetail.opacity(at: 10, minimumZoom: 2, maximumZoom: 10),
            0,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testRendererAppliesMarkerFadeDuringZoom() async throws {
        let renderer = UnifiedBigSightScene(campus: makeSingleVenueCampus())
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.zoom(
            by: 11.5,
            around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )
        renderer.didFinishUpdate()

        XCTAssertEqual(renderer.zoomFactor, 11.5, accuracy: 0.001)
        XCTAssertEqual(renderer.venueMarkerOpacities.first ?? -1, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testExteriorFacilityRemainsVisibleAtMaximumDetailZoom() async throws {
        let baseCampus = makeGeographicCampus()
        let venue = try XCTUnwrap(baseCampus.venues.first)
        let indoorPoint = venue.center
        let exteriorPoint = CGPoint(
            x: venue.bounds.maxX + 20,
            y: venue.bounds.midY
        )
        let indoorFacility = BigSightFacilityLocation(
            id: "indoor-information",
            name: "Indoor Information",
            kind: .information,
            coordinate: BigSightCampusLayout.coordinate(from: indoorPoint),
            minimumZoom: 0,
            maximumZoom: 24
        )
        let taxiStand = BigSightFacilityLocation(
            id: "taxi-stand",
            name: "Taxi Stand",
            kind: .taxi,
            coordinate: BigSightCampusLayout.coordinate(from: exteriorPoint),
            minimumZoom: 0,
            maximumZoom: 24
        )
        let campus = BigSightCampusScene(
            id: baseCampus.id,
            venues: baseCampus.venues,
            connections: [],
            facilities: [indoorFacility, taxiStand],
            bounds: baseCampus.bounds.union(
                CGRect(x: exteriorPoint.x - 10, y: exteriorPoint.y - 10, width: 20, height: 20)
            )
        )
        let renderer = UnifiedBigSightScene(campus: campus)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.zoom(
            by: 40,
            around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )
        renderer.didFinishUpdate()

        XCTAssertGreaterThan(renderer.zoomFactor, 24)
        XCTAssertFalse(renderer.isFacilityMarkerVisible(id: indoorFacility.id))
        XCTAssertTrue(renderer.isFacilityMarkerVisible(id: taxiStand.id))
    }

    @MainActor
    func testDestinationMarkerRemainsVisibleOnUnifiedCampusMap() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let destination = WhereAmIResolver.destination(
            at: table,
            in: WhereAmIVenueOption(displayName: "Test Hall", placement: venue),
            selectedAt: Date(timeIntervalSince1970: 300)
        )
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.update(
            campus: campus,
            scope: .campus,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [],
            bookmarks: [],
            locatedUser: nil,
            destination: destination
        )

        XCTAssertEqual(renderer.destinationMarkerCount, 1)
        XCTAssertTrue(
            renderer.accessibilitySummary.contains("destination \(destination.spaceCode)"))
    }

    @MainActor
    func testGenreOverlayIsVisibleAtVenueFitScale() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.requestVenue(venue.id)
        renderer.update(
            campus: campus,
            scope: .venue,
            selectedMapID: venue.id,
            selectedTableID: nil,
            circlePlacements: [],
            circleArtwork: [:],
            searchMatches: [],
            searchActive: false,
            genrePlacements: [
                CatalogMapGenrePlacement(
                    tableID: table.id,
                    subspace: 0,
                    genreID: 1,
                    genreName: "Test Genre"
                )
            ],
            bookmarks: [],
            locatedUser: nil
        )
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        XCTAssertLessThan(renderer.zoomFactor, 9)
        XCTAssertEqual(renderer.genreOverlayNodeCount, 1)
        XCTAssertTrue(renderer.isGenreOverlayVisible)
    }

    @MainActor
    func testTappingAnAlreadyOpenVenueNeverRequestsFitAgain() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.requestVenue(venue.id)
        try await Task.sleep(for: .milliseconds(30))
        let hit = renderer.hit(
            at: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )

        if case .venue = hit {
            XCTFail("An open venue must not turn a detail-level tap into a fit-to-venue action.")
        }
    }

    @MainActor
    func testMapMarkersAndLabelsRemainLevelWhileCameraRotates() async throws {
        let campus = makeSingleVenueCampus()
        let renderer = UnifiedBigSightScene(campus: campus)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))

        renderer.rotate(
            by: .pi / 3,
            around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )
        renderer.didFinishUpdate()

        XCTAssertTrue(
            renderer.venueMarkerRotations.allSatisfy {
                abs($0 - renderer.cameraRotation) < 0.000_001
            })
        XCTAssertTrue(
            renderer.blockLabelRotations.allSatisfy {
                abs($0 - renderer.cameraRotation) < 0.000_001
            })
        let screenRightVectors = renderer.venueMarkerScreenRightVectors(in: view)
        XCTAssertFalse(screenRightVectors.isEmpty)
        for vector in screenRightVectors {
            XCTAssertGreaterThan(vector.dx, 0)
            XCTAssertEqual(vector.dy, 0, accuracy: 0.000_1)
        }
    }

    @MainActor
    func testMapLibreAndSpriteKitCameraProjectionsStayRegistered() async throws {
        let campus = makeGeographicCampus()
        let renderer = UnifiedBigSightScene(campus: campus)
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.layoutIfNeeded()
        host.mapView.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(40))

        assertVisibleCameraAlignment(host: host, renderer: renderer)

        let gestureOrigin = CGPoint(x: 137, y: 511)
        renderer.zoom(by: 2.4, around: gestureOrigin, in: host.mapView)
        renderer.rotate(by: .pi / 5, around: gestureOrigin, in: host.mapView)
        host.updateBasemap(camera: renderer.basemapCamera)

        assertVisibleCameraAlignment(host: host, renderer: renderer)

        renderer.zoom(by: 80, around: gestureOrigin, in: host.mapView)
        renderer.rotate(by: -.pi / 2, around: gestureOrigin, in: host.mapView)
        host.updateBasemap(camera: renderer.basemapCamera)

        XCTAssertGreaterThan(renderer.basemapCamera.zoomLevel, 22)
        assertVisibleCameraAlignment(host: host, renderer: renderer)
    }

    @MainActor
    func testAnimatedCameraKeepsBasemapRegisteredOnEverySample() async throws {
        let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = UnifiedBigSightMapView.Coordinator()
        host.layoutIfNeeded()
        coordinator.connect(host: host, renderer: renderer)
        host.mapView.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(40))
        host.updateBasemap(camera: renderer.basemapCamera)

        renderer.animatedZoom(
            by: 3.2,
            around: CGPoint(x: 112, y: 596),
            in: host.mapView
        )

        var worstResidual: CGFloat = 0
        for _ in 0..<36 {
            try await Task.sleep(for: .milliseconds(8))
            let center = renderer.cameraCampusCenter
            let radius = renderer.cameraMetersPerPoint * 120
            let samples = [
                CGPoint(x: center.x + radius, y: center.y),
                CGPoint(x: center.x, y: center.y + radius),
            ]
            for sample in samples {
                let residual = host.alignmentResidual(at: sample, renderer: renderer)
                worstResidual = max(worstResidual, abs(residual.dx), abs(residual.dy))
            }
        }

        XCTAssertLessThan(
            worstResidual,
            0.75,
            "MapLibre used a stale camera during SpriteKit interpolation"
        )
        withExtendedLifetime(coordinator) {}
    }

    #if DEBUG
        @MainActor
        func testPurePanPublishesAndAlignsEverySampleWhileInitializingRotationOnlyOnce() {
            let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
            let host = UnifiedMapHostView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            let coordinator = UnifiedBigSightMapView.Coordinator()
            var rotationPublicationCount = 0

            host.layoutIfNeeded()
            host.mapView.presentScene(renderer)
            host.mapView.isPaused = true
            renderer.didFinishUpdate()
            coordinator.connect(host: host, renderer: renderer)
            coordinator.updateCallbacks(
                onSelectVenue: { _ in },
                onShowCampus: {},
                onSelectTable: { _, _ in },
                onSelectLocatedUser: {},
                onCameraRotationChange: { _ in rotationPublicationCount += 1 },
                onLocate: { _, _, _, _ in }
            )
            renderer.resetDebugCameraWorkCounts()
            host.resetDebugCameraUpdateCounts()

            let samples = [
                CGPoint(x: 18, y: 7),
                CGPoint(x: -11, y: 13),
                CGPoint(x: 9, y: -16),
                CGPoint(x: -14, y: -6),
            ]
            for (index, translation) in samples.enumerated() {
                renderer.pan(by: translation, in: host.mapView)
                renderer.didFinishUpdate()

                let expectedPublicationCount = index + 1
                XCTAssertEqual(
                    renderer.debugCameraPublicationCount,
                    expectedPublicationCount
                )
                XCTAssertEqual(host.debugBasemapUpdateCount, expectedPublicationCount)
                XCTAssertEqual(renderer.debugLevelOfDetailApplicationCount, 0)
                XCTAssertEqual(rotationPublicationCount, 1)
                XCTAssertEqual(host.debugCompassUpdateCount, 0)
                assertCurrentBasemapAlignment(host: host, renderer: renderer)
            }

            withExtendedLifetime(coordinator) {}
        }

        @MainActor
        func testZoomAndRotationSamplesRunOnlyTheirRequiredCameraWork() {
            let renderer = UnifiedBigSightScene(campus: makeGeographicCampus())
            let host = UnifiedMapHostView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            let coordinator = UnifiedBigSightMapView.Coordinator()
            var rotationPublicationCount = 0

            host.layoutIfNeeded()
            host.mapView.presentScene(renderer)
            host.mapView.isPaused = true
            renderer.didFinishUpdate()
            coordinator.connect(host: host, renderer: renderer)
            coordinator.updateCallbacks(
                onSelectVenue: { _ in },
                onShowCampus: {},
                onSelectTable: { _, _ in },
                onSelectLocatedUser: {},
                onCameraRotationChange: { _ in rotationPublicationCount += 1 },
                onLocate: { _, _, _, _ in }
            )

            renderer.pan(by: CGPoint(x: 12, y: -8), in: host.mapView)
            renderer.didFinishUpdate()
            XCTAssertEqual(rotationPublicationCount, 1)

            renderer.resetDebugCameraWorkCounts()
            host.resetDebugCameraUpdateCounts()
            rotationPublicationCount = 0

            let pivot = CGPoint(x: host.mapView.bounds.midX, y: host.mapView.bounds.midY)
            renderer.zoom(by: 2, around: pivot, in: host.mapView)
            renderer.didFinishUpdate()

            XCTAssertEqual(renderer.debugCameraPublicationCount, 1)
            XCTAssertEqual(renderer.debugLevelOfDetailApplicationCount, 1)
            XCTAssertEqual(host.debugBasemapUpdateCount, 1)
            XCTAssertEqual(host.debugCompassUpdateCount, 0)
            XCTAssertEqual(rotationPublicationCount, 0)
            assertCurrentBasemapAlignment(host: host, renderer: renderer)

            renderer.resetDebugCameraWorkCounts()
            host.resetDebugCameraUpdateCounts()
            renderer.rotate(by: .pi / 7, around: pivot, in: host.mapView)
            renderer.didFinishUpdate()

            XCTAssertEqual(renderer.debugCameraPublicationCount, 1)
            XCTAssertEqual(renderer.debugLevelOfDetailApplicationCount, 1)
            XCTAssertEqual(host.debugBasemapUpdateCount, 1)
            XCTAssertEqual(host.debugCompassUpdateCount, 1)
            XCTAssertEqual(rotationPublicationCount, 1)
            assertCurrentBasemapAlignment(host: host, renderer: renderer)

            renderer.resetDebugCameraWorkCounts()
            renderer.updateVisibleMapLayers([.gates])
            XCTAssertEqual(renderer.debugCameraPublicationCount, 0)
            XCTAssertEqual(renderer.debugLevelOfDetailApplicationCount, 1)

            withExtendedLifetime(coordinator) {}
        }

        @MainActor
        func testGridAlignmentTargetChangeUpdatesCompassWithoutPublishingCameraRotation() {
            let initialCampus = makeGridAlignedCampus()
            let renderer = UnifiedBigSightScene(campus: initialCampus)
            let host = UnifiedMapHostView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            let coordinator = UnifiedBigSightMapView.Coordinator()
            var rotationPublicationCount = 0

            host.layoutIfNeeded()
            host.mapView.presentScene(renderer)
            host.mapView.isPaused = true
            renderer.didFinishUpdate()
            coordinator.connect(host: host, renderer: renderer)
            coordinator.updateCallbacks(
                onSelectVenue: { _ in },
                onShowCampus: {},
                onSelectTable: { _, _ in },
                onSelectLocatedUser: {},
                onCameraRotationChange: { _ in rotationPublicationCount += 1 },
                onLocate: { _, _, _, _ in }
            )

            renderer.pan(by: CGPoint(x: 12, y: -8), in: host.mapView)
            renderer.didFinishUpdate()
            XCTAssertEqual(rotationPublicationCount, 1)
            rotationPublicationCount = 0

            let source = initialCampus.venues[0]
            let rotatedVenue = BigSightVenuePlacement(
                kind: source.kind,
                scene: source.scene,
                coordinate: source.coordinate,
                center: source.center,
                rotation: source.scene.layoutRotation,
                metersPerMapPoint: source.metersPerMapPoint
            )
            let updatedCampus = BigSightCampusScene(
                id: .init(day: 2, mapIDs: [rotatedVenue.id]),
                venues: [rotatedVenue],
                connections: initialCampus.connections,
                bounds: rotatedVenue.bounds.insetBy(dx: -70, dy: -70)
            )
            let initialRotation = renderer.cameraRotation
            let initialGridRotation = renderer.gridAlignedCameraRotation
            renderer.update(
                campus: updatedCampus,
                scope: .campus,
                selectedMapID: rotatedVenue.id,
                selectedTableID: nil,
                circlePlacements: [],
                circleArtwork: [:],
                searchMatches: [],
                searchActive: false,
                genrePlacements: [],
                bookmarks: [],
                locatedUser: nil
            )
            XCTAssertEqual(renderer.cameraRotation, initialRotation, accuracy: 0.000_001)
            XCTAssertNotEqual(renderer.gridAlignedCameraRotation, initialGridRotation)

            renderer.resetDebugCameraWorkCounts()
            host.resetDebugCameraUpdateCounts()
            renderer.onCameraChange?()

            XCTAssertEqual(host.debugBasemapUpdateCount, 1)
            XCTAssertEqual(host.debugCompassUpdateCount, 1)
            XCTAssertEqual(rotationPublicationCount, 0)
            XCTAssertTrue(host.compassButton.isGridAligned)

            withExtendedLifetime(coordinator) {}
        }
    #endif

    @MainActor
    func testC104VenueAndDaySelectionRetainUnifiedCampusScene() async throws {
        let configuration = try await DemoCatalogSource().configuration(for: DemoCatalogSource.c104)
        let dataSource = CirclemsDataSource(configuration: configuration)
        for _ in 0..<300 {
            if dataSource.readiness == .ready { break }
            if case .error(let message) = dataSource.readiness {
                XCTFail("C104 demo catalog failed to open: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(dataSource.readiness, .ready)

        let model = MapScreenModel(
            days: dataSource.comiket.days,
            eventNumber: dataSource.comiket.number,
            catalog: dataSource.mapCatalog,
            userPlanStore: dataSource.userPlanStore
        )
        model.load()
        try await waitUntilReady(model)
        let campus = try XCTUnwrap(model.campusScene)
        XCTAssertEqual(model.cachedSceneDays, [1])
        XCTAssertEqual(model.retainedSceneDays, [1])
        let venue = try XCTUnwrap(campus.venues.first)
        XCTAssertGreaterThan(venue.scene.tables.count, 1_000)
        XCTAssertEqual(campus.venues.count, 4)
        let east123 = try XCTUnwrap(campus.venues.first { $0.kind == .east123 })
        XCTAssertEqual(
            Set(east123.scene.tables.compactMap(\.hallName)),
            Set(["東１", "東２", "東３"])
        )
        for venue in campus.venues {
            let artwork = try XCTUnwrap(venue.scene.artwork)
            let filename =
                switch venue.kind {
                case .east123: "E123"
                case .east456: "E456"
                case .east7: "E7"
                case .west: "W12"
                case .south: "S12"
                }
            XCTAssertEqual(artwork.pixelSize, venue.scene.size)
            XCTAssertEqual(artwork.image.width, Int(venue.scene.size.width))
            XCTAssertEqual(artwork.image.height, Int(venue.scene.size.height))
            XCTAssertEqual(artwork.name, "LWMP1\(filename)")
        }
        XCTAssertEqual(
            campus.venues.first { $0.kind == .east456 }?.scene.layoutRotation,
            .pi
        )

        let campusVenue = try XCTUnwrap(campus.venues.first)
        let campusTable = try XCTUnwrap(campusVenue.scene.tables.first)
        let campusLocation = model.locateUser(
            at: CGPoint(
                x: campusTable.origin.x + campusVenue.scene.tableSize.width / 2,
                y: campusTable.origin.y + campusVenue.scene.tableSize.height / 2
            ),
            nearest: campusTable,
            subspace: 1,
            mapID: campusVenue.id
        )
        XCTAssertNotNil(
            campusLocation, "Campus long press should create a location before venue selection")
        model.showCampus()

        let renderer = UnifiedBigSightScene(campus: campus)
        XCTAssertEqual(renderer.authoredMapNodeCount, campus.venues.count)
        XCTAssertEqual(renderer.darkArtworkNodeCount, 0)
        XCTAssertEqual(renderer.generatedBlockLabelCount, 0)
        XCTAssertEqual(renderer.venueMarkerCount, campus.venues.count)
        XCTAssertEqual(renderer.facilityMarkerCount, campus.facilities.count)

        let darkRenderer = UnifiedBigSightScene(campus: campus, appearance: .dark)
        XCTAssertEqual(darkRenderer.darkArtworkNodeCount, campus.venues.count)

        let dayTwoScene = try await dataSource.mapCatalog.scene(day: 2, mapID: 1)
        XCTAssertEqual(dayTwoScene.artwork?.name, "LWMP2E123")
        XCTAssertEqual(dayTwoScene.artwork?.pixelSize, dayTwoScene.size)

        model.select(mapID: venue.id)

        XCTAssertEqual(model.scope, .venue)
        XCTAssertEqual(model.scene, venue.scene)
        XCTAssertEqual(model.campusScene, campus)
        XCTAssertEqual(model.phase, .ready)

        model.showCampus()

        XCTAssertEqual(model.scope, .campus)
        XCTAssertEqual(model.campusScene, campus)
        XCTAssertEqual(model.phase, .ready)

        model.select(day: 2)

        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(
            model.campusScene,
            campus,
            "The current map should remain visible while the next day loads"
        )

        try await waitUntilReady(model)
        XCTAssertEqual(model.campusScene?.id.day, 2)
        XCTAssertEqual(model.cachedSceneDays, [2])
        XCTAssertEqual(model.retainedSceneDays, [2])

        let dayTwoCampus = try XCTUnwrap(model.campusScene)
        model.select(day: 1)

        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(
            model.campusScene,
            dayTwoCampus,
            "Switching back should keep the day-two map visible until day one is activated"
        )

        try await waitUntilReady(model)
        XCTAssertEqual(model.campusScene?.id.day, 1)
        XCTAssertEqual(model.cachedSceneDays, [1])
        XCTAssertEqual(model.retainedSceneDays, [1])
    }

    @MainActor
    func testCancelledArtworkBatchStopsDecodingSupersededImages() async throws {
        let image = try XCTUnwrap(makeImage(width: 1, height: 1))
        let counter = MapArtworkDecodeCounter(image: image)
        let imageData = Dictionary(
            uniqueKeysWithValues: (0..<200).map { index -> (Int, Data) in
                (index, Data([UInt8(index & 0xFF)]))
            }
        )
        let task = Task {
            try await MapScreenModel.decodeImages(imageData) { data in
                counter.decode(data)
            }
        }

        try await waitUntil { counter.count >= 3 }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A superseded artwork batch should be cancelled")
        } catch is CancellationError {}
        XCTAssertLessThan(counter.count, imageData.count)
    }

    @MainActor
    func testSceneCacheRetainsOnlyTheSelectedDay() async throws {
        let model = makeTwoDayMapModel()

        model.load()
        try await waitUntilReady(model)
        XCTAssertEqual(model.cachedSceneDays, [1])
        XCTAssertEqual(model.retainedSceneDays, [1])

        model.select(day: 2)
        XCTAssertTrue(model.cachedSceneDays.isEmpty)
        XCTAssertEqual(
            model.retainedSceneDays,
            [1],
            "Only the visible transition scene should retain the previous day while loading"
        )
        try await waitUntilReady(model)
        XCTAssertEqual(model.cachedSceneDays, [2])
        XCTAssertEqual(model.retainedSceneDays, [2])
    }

    @MainActor
    func testVenueDaySwitchCannotReuseThePreviousDayCampus() async throws {
        let model = makeTwoDayMapModel()

        model.load()
        try await waitUntilReady(model)
        model.select(mapID: 101)
        XCTAssertEqual(model.scene?.id.day, 1)

        model.select(day: 2)
        try await waitUntilReady(model)
        XCTAssertEqual(model.scene?.id.day, 2)
        XCTAssertEqual(model.retainedSceneDays, [2])

        model.showCampus()
        try await waitUntilReady(model)
        XCTAssertEqual(model.campusScene?.id.day, 2)
        XCTAssertEqual(model.retainedSceneDays, [2])
    }

    @MainActor
    func testFailedDaySwitchDoesNotExposeThePreviousDayAsReady() async throws {
        for initialScope in [MapScreenModel.Scope.campus, .venue] {
            let model = makeTwoDayMapModel(
                initialScope: initialScope,
                catalog: FailingDayMapCatalog(failingDay: 2)
            )
            model.load()
            try await waitUntilReady(model)

            model.select(day: 2)
            try await waitUntil { model.phase != .loading }

            guard case .failed = model.phase else {
                XCTFail("A failed day switch must not make the previous day interactive")
                continue
            }
            XCTAssertTrue(model.retainedSceneDays.isEmpty)
        }
    }

    @MainActor
    func testFailedSameDayVenueSwitchExposesRetryAndRetriesTheRequestedVenue() async throws {
        let catalog = SelectivelyFailingMapCatalog(failingMapIDs: [102])
        let model = makeTwoDayMapModel(initialScope: .venue, catalog: catalog)
        model.load()
        try await waitUntilReady(model)

        model.select(mapID: 102)
        try await waitUntil { model.phase != .loading }

        guard case .failed = model.phase else {
            return XCTFail("The requested venue failure should remain visible")
        }
        XCTAssertNil(model.scene)
        XCTAssertNil(model.campusScene)
        let initialRequestCount = await catalog.requestCount(day: 1, mapID: 102)
        XCTAssertEqual(initialRequestCount, 1)

        model.load()
        try await waitUntil { model.phase != .loading }
        let retriedRequestCount = await catalog.requestCount(day: 1, mapID: 102)
        XCTAssertEqual(retriedRequestCount, 2)
    }

    @MainActor
    func testFailedSameDayCampusSwitchExposesRetryAndRetriesCampusLoading() async throws {
        let catalog = SelectivelyFailingMapCatalog(failingMapIDs: [101, 102, 103, 104])
        let model = makeTwoDayMapModel(
            initialScope: .venue,
            selectedMapID: 1,
            catalog: catalog
        )
        model.load()
        try await waitUntilReady(model)

        model.showCampus()
        try await waitUntil { model.phase != .loading }

        guard case .failed = model.phase else {
            return XCTFail("The campus failure should replace the standalone venue")
        }
        XCTAssertNil(model.scene)
        XCTAssertNil(model.campusScene)
        let initialRequestCount = await catalog.requestCount(day: 1, mapID: 101)
        XCTAssertEqual(initialRequestCount, 1)

        model.load()
        try await waitUntil { model.phase != .loading }
        let retriedRequestCount = await catalog.requestCount(day: 1, mapID: 101)
        XCTAssertEqual(retriedRequestCount, 2)
    }

    @MainActor
    func testWhereAmIVenuesCannotReinsertAPreviousDayScene() async throws {
        let catalog = PausableMapCatalog()
        let model = makeTwoDayMapModel(initialScope: .venue, catalog: catalog)
        model.load()
        try await waitUntilReady(model)
        await catalog.pauseNextScene(day: 1, mapID: 102)

        let venues = Task { try await model.whereAmIVenues() }
        await catalog.waitUntilSceneIsPaused()
        model.select(day: 2)
        await catalog.resumePausedScene()

        do {
            _ = try await venues.value
            XCTFail("A previous-day venue lookup should be cancelled")
        } catch is CancellationError {}
        try await waitUntilReady(model)
        XCTAssertEqual(model.retainedSceneDays, [2])
    }

    @MainActor
    func testDaySwitchStopsLoadingRemainingSupersededCampusHalls() async throws {
        let catalog = PausableMapCatalog()
        let model = makeTwoDayMapModel(catalog: catalog)
        await catalog.pauseNextScene(day: 1, mapID: 101)

        model.load()
        await catalog.waitUntilSceneIsPaused()
        model.select(day: 2)
        await catalog.resumePausedScene()

        try await waitUntilReady(model)
        let requestedOldDayMapIDs = await catalog.requestedMapIDs(day: 1)
        XCTAssertEqual(
            requestedOldDayMapIDs,
            [101],
            "Cancelling a campus load should prevent the remaining old-day halls from loading"
        )
        XCTAssertEqual(model.campusScene?.id.day, 2)
        XCTAssertEqual(model.retainedSceneDays, [2])
    }

    @MainActor
    func testGlobalSearchStaysActiveAcrossCampusAndVenueScopes() async throws {
        let model = MapScreenModel.previewCampusFixture()
        model.load()
        try await waitUntilReady(model)

        model.setSearchPresented(true)
        model.updateSearchQuery("Fixture")
        try await waitUntil { !model.isSearching && !model.searchMatches.isEmpty }
        let matches = model.searchMatches

        model.select(mapID: 101)

        XCTAssertEqual(model.scope, .venue)
        XCTAssertTrue(model.isSearchPresented)
        XCTAssertEqual(model.searchQuery, "Fixture")
        XCTAssertEqual(model.searchMatches, matches)

        model.showCampus()

        XCTAssertEqual(model.scope, .campus)
        XCTAssertTrue(model.isSearchPresented)
        XCTAssertEqual(model.searchQuery, "Fixture")
        XCTAssertEqual(model.searchMatches, matches)
    }

    @MainActor
    func testMapLongPressDropsPreviousSensorMetadata() async throws {
        let model = MapScreenModel.previewCampusFixture()
        model.load()
        try await waitUntilReady(model)
        let venue = try XCTUnwrap(model.campusScene?.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let reading = WhereAmILocationReading(
            coordinate: venue.coordinate,
            horizontalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let sensorUser = WhereAmIResolver.locatedUser(
            at: table,
            in: WhereAmIVenueOption(displayName: venue.kind.displayName, placement: venue),
            subspace: 0,
            headingDegrees: 88,
            locationReading: reading,
            source: .gps,
            placedAt: Date(timeIntervalSince1970: 200)
        )
        model.locateUser(sensorUser)
        let exactPoint = CGPoint(x: table.origin.x + 3, y: table.origin.y + 5)

        let manualUser = try XCTUnwrap(
            model.locateUser(
                at: exactPoint,
                nearest: table,
                subspace: 1,
                mapID: venue.id
            )
        )

        XCTAssertEqual(manualUser.source, .mapLongPress)
        XCTAssertEqual(manualUser.point, exactPoint)
        XCTAssertNil(manualUser.headingDegrees)
        XCTAssertNil(manualUser.locationReading)
    }

    @MainActor
    func testLiveGPSRefreshPreservesActiveMapSearch() async throws {
        let model = MapScreenModel.previewCampusFixture()
        model.load()
        try await waitUntilReady(model)
        let venue = try XCTUnwrap(model.campusScene?.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let venueOption = WhereAmIVenueOption(
            displayName: venue.kind.displayName,
            placement: venue
        )
        let placedAt = Date(timeIntervalSince1970: 200)
        let initialUser = WhereAmIResolver.locatedUser(
            at: table,
            in: venueOption,
            subspace: 0,
            headingDegrees: 45,
            locationReading: nil,
            source: .gps,
            placedAt: placedAt
        )
        model.updateGPSLocatedUser(initialUser)
        model.setSearchPresented(true)

        let updatedUser = WhereAmIResolver.locatedUser(
            at: table,
            in: venueOption,
            subspace: 0,
            headingDegrees: 135,
            locationReading: nil,
            source: .gps,
            placedAt: placedAt
        )
        model.updateGPSLocatedUser(updatedUser)

        XCTAssertTrue(model.isSearchPresented)
        XCTAssertEqual(model.locatedUser, updatedUser)
    }

    @MainActor
    func testVenueShortcutKeepsEveryFavoriteForTheSelectedDayLoaded() async throws {
        let store = InMemoryUserPlanStore()
        let tableID = CatalogMapTable.ID(blockID: 1, spaceNumber: 1)
        try await store.upsert([
            MapBookmark(
                eventNumber: 108,
                publicCircleID: 100,
                catalogCircleID: 7,
                updateID: 70,
                day: 1,
                mapID: 101,
                tableID: tableID,
                subspace: 0,
                color: .orange,
                memo: "",
                modifiedAt: .now,
                syncState: .synced
            ),
            MapBookmark(
                eventNumber: 108,
                publicCircleID: 200,
                catalogCircleID: 8,
                updateID: 80,
                day: 1,
                mapID: 102,
                tableID: tableID,
                subspace: 1,
                color: .magenta,
                memo: "",
                modifiedAt: .now,
                syncState: .synced
            ),
        ])
        let model = MapScreenModel.previewCampusFixture(userPlanStore: store)

        model.load()
        try await waitUntilReady(model)
        try await waitUntil { model.favoriteBookmarks.count == 2 }

        model.select(mapID: 101)
        XCTAssertEqual(model.favoriteBookmarks.count, 2)

        model.select(mapID: 102)
        XCTAssertEqual(model.favoriteBookmarks.count, 2)

        model.showCampus()
        XCTAssertEqual(model.favoriteBookmarks.count, 2)
    }

    @MainActor
    func testFavoriteChangesOutsideMapRefreshImmediately() async throws {
        let store = InMemoryUserPlanStore()
        let model = MapScreenModel.previewCampusFixture(userPlanStore: store)
        let tableID = CatalogMapTable.ID(blockID: 1, spaceNumber: 1)
        var bookmark = MapBookmark(
            eventNumber: 108,
            publicCircleID: 100,
            catalogCircleID: 7,
            updateID: 70,
            day: 1,
            mapID: 101,
            tableID: tableID,
            subspace: 0,
            color: .orange,
            memo: "",
            modifiedAt: .now,
            syncState: .synced
        )

        model.load()
        try await waitUntilReady(model)
        XCTAssertTrue(model.favoriteBookmarks.isEmpty)

        try await store.upsert(bookmark)
        try await waitUntil {
            model.favoriteBookmarks[bookmark.publicCircleID]?.color == .orange
        }

        bookmark.color = .magenta
        bookmark.modifiedAt = .now
        try await store.upsert(bookmark)
        try await waitUntil {
            model.favoriteBookmarks[bookmark.publicCircleID]?.color == .magenta
        }

        bookmark.syncState = .pendingDelete
        bookmark.modifiedAt = .now
        try await store.upsert(bookmark)
        try await waitUntil {
            model.favoriteBookmarks[bookmark.publicCircleID] == nil
        }
    }

    @MainActor
    func testGlobalSearchRespondsWithinInteractiveBudget() async throws {
        let model = MapScreenModel.previewCampusFixture()
        model.load()
        try await waitUntilReady(model)

        let clock = ContinuousClock()
        let startedAt = clock.now
        model.updateSearchQuery("Fixture")
        try await waitUntil(timeout: .milliseconds(250)) {
            !model.isSearching && !model.searchMatches.isEmpty
        }

        XCTAssertLessThan(clock.now - startedAt, .milliseconds(250))
    }

    @MainActor
    func testSelectingSecondCircleTargetsBookmarkAction() async throws {
        let model = MapScreenModel.fixture()
        model.load()
        try await waitUntilReady(model)

        let scene = try XCTUnwrap(model.scene)
        let table = try XCTUnwrap(scene.tables.first)
        model.select(table: table, preferredSubspace: 0)
        try await waitUntil { model.selection?.isLoading == false }

        let circles = try XCTUnwrap(model.selection?.circles)
        let circleA = try XCTUnwrap(circles.first { $0.subspace == 0 })
        let circleB = try XCTUnwrap(circles.first { $0.subspace == 1 })
        XCTAssertEqual(model.selection?.selectedCircleID, circleA.id)

        model.select(circle: circleB)
        model.toggleBookmark()

        XCTAssertEqual(model.selection?.selectedCircleID, circleB.id)
        let bookmark = try XCTUnwrap(model.bookmark(for: circleB))
        XCTAssertEqual(bookmark.catalogCircleID, circleB.id)
        XCTAssertEqual(bookmark.subspace, circleB.subspace)
        XCTAssertNil(model.bookmark(for: circleA))
    }

    @MainActor
    func testMapLoadsPrimarySharedPlanCircleWithoutFavorite() async throws {
        let suiteName = "MapPrimarySharedPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let userID = "map-user"
        let planID = "11111111-1111-4111-8111-111111111111"
        let publicCircleID = 9_902
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(
            SharedPlan(
                id: planID,
                name: "Map Plan",
                comiketNo: 104,
                ownership: .owned,
                role: .owner,
                lifecycle: .active,
                revision: 1,
                circleKeys: [
                    try XCTUnwrap(SharedPlanCircleKey(comiketNo: 104, wcID: publicCircleID))
                ],
                createdAt: .now,
                updatedAt: .now
            ),
            write: nil
        )
        SharedPlanPrimaryPlanPreference(defaults: defaults).setPlanID(
            planID,
            userID: userID,
            comiketNo: 104
        )
        let store = SharedPlanStore(
            persistence: persistence,
            actorUserID: { userID }
        )
        let provider = SharedPlanPrimaryMapCircleProvider(
            store: store,
            currentUserID: userID,
            defaults: defaults
        )
        let model = MapScreenModel.fixture(primarySharedPlanProvider: provider)

        model.load()
        try await waitUntilReady(model)
        try await waitUntil { model.primarySharedPlanCircles.count == 1 }

        XCTAssertTrue(model.favoriteBookmarks.isEmpty)
        XCTAssertEqual(model.primarySharedPlanCircles.first?.publicCircleID, publicCircleID)
    }

    @MainActor
    private func makeTwoDayMapModel(
        initialScope: MapScreenModel.Scope = .campus,
        selectedMapID: Int? = nil,
        catalog: any MapCatalog = FixtureMapCatalog()
    ) -> MapScreenModel {
        func hall(id: Int, name: String, mapName: String) -> UFDSchema.DayHall {
            UFDSchema.DayHall(
                id: "two-day-hall-\(id)",
                name: name,
                mapName: mapName,
                externalMapId: id,
                externalCorrespondingFloorId: 1,
                areas: []
            )
        }
        let halls = [
            hall(id: 101, name: "東123", mapName: "E123"),
            hall(id: 102, name: "東7", mapName: "E7"),
            hall(id: 103, name: "西12", mapName: "W12"),
            hall(id: 104, name: "南12", mapName: "S12"),
        ]
        return MapScreenModel(
            days: [1, 2].map { day in
                UFDSchema.Day(
                    id: "two-day-fixture-\(day)",
                    dayIndex: day,
                    date: DateComponents(year: 2026, month: 8, day: 14 + day),
                    halls: halls
                )
            },
            eventNumber: 108,
            selectedMapID: selectedMapID,
            initialScope: initialScope,
            catalog: catalog,
            userPlanStore: InMemoryUserPlanStore()
        )
    }

    @MainActor
    private func waitUntilReady(
        _ model: MapScreenModel,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while model.phase == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func makeSingleVenueCampus() -> BigSightCampusScene {
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Test Hall",
            size: CGSize(width: 35_000, height: 70_000),
            tableSize: CGSize(width: 40, height: 40),
            tables: [
                CatalogMapTable(
                    id: .init(blockID: 1, spaceNumber: 1),
                    blockName: "A",
                    origin: CGPoint(x: 100, y: 100),
                    orientation: .aLeft
                )
            ]
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: .zero,
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        return BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )
    }

    private func luminance(_ color: UIColor?) -> CGFloat {
        guard let color else { return 0 }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    private func makeGeographicCampus() -> BigSightCampusScene {
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "East 1–3",
            size: CGSize(width: 4_680, height: 1_680),
            tableSize: CGSize(width: 40, height: 40),
            tables: []
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: BigSightCampusLayout.project(BigSightCampusLayout.eastBuilding),
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        return BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: CGRect(x: -240, y: -240, width: 480, height: 480)
        )
    }

    private func makeGridAlignedCampus() -> BigSightCampusScene {
        let base = makeGeographicCampus()
        let source = base.venues[0]
        let venue = BigSightVenuePlacement(
            kind: .west,
            scene: source.scene,
            coordinate: source.coordinate,
            center: source.center,
            rotation: CGFloat(146.97977914964463 * .pi / 180),
            metersPerMapPoint: source.metersPerMapPoint
        )
        return BigSightCampusScene(
            id: base.id,
            venues: [venue],
            connections: base.connections,
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @MainActor
    private func assertVisibleCameraAlignment(
        host: UnifiedMapHostView,
        renderer: UnifiedBigSightScene,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let center = renderer.cameraCampusCenter
        // Exercise a cross spanning 200 screen points around the camera. These
        // are the locations a person can actually compare at any zoom level.
        let radius = renderer.cameraMetersPerPoint * 100
        let samples = [
            center,
            CGPoint(x: center.x - radius, y: center.y),
            CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x, y: center.y - radius),
            CGPoint(x: center.x, y: center.y + radius),
        ]
        assertCameraAlignment(
            samples: samples,
            host: host,
            renderer: renderer,
            file: file,
            line: line
        )
    }

    #if DEBUG
        @MainActor
        private func assertCurrentBasemapAlignment(
            host: UnifiedMapHostView,
            renderer: UnifiedBigSightScene,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let center = renderer.cameraCampusCenter
            let radius = renderer.cameraMetersPerPoint * 100
            let samples = [
                center,
                CGPoint(x: center.x - radius, y: center.y),
                CGPoint(x: center.x + radius, y: center.y),
                CGPoint(x: center.x, y: center.y - radius),
                CGPoint(x: center.x, y: center.y + radius),
            ]
            for sample in samples {
                let residual = host.alignmentResidual(at: sample, renderer: renderer)
                XCTAssertEqual(residual.dx, 0, accuracy: 0.35, file: file, line: line)
                XCTAssertEqual(residual.dy, 0, accuracy: 0.35, file: file, line: line)
            }
        }
    #endif

    @MainActor
    private func assertCameraAlignment(
        samples: [CGPoint],
        host: UnifiedMapHostView,
        renderer: UnifiedBigSightScene,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        host.updateBasemap(camera: renderer.basemapCamera)
        XCTAssertEqual(
            host.basemapView.zoomLevel,
            renderer.basemapCamera.zoomLevel,
            accuracy: 0.001,
            "MapLibre clamped the requested unified zoom",
            file: file,
            line: line
        )
        for sample in samples {
            let residual = host.alignmentResidual(at: sample, renderer: renderer)
            XCTAssertEqual(residual.dx, 0, accuracy: 0.35, file: file, line: line)
            XCTAssertEqual(residual.dy, 0, accuracy: 0.35, file: file, line: line)
        }
    }
}

private struct FailingDayMapCatalog: MapCatalog {
    private let base = FixtureMapCatalog()
    let failingDay: Int

    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene {
        guard day != failingDay else { throw MapCatalogError.missingMap(mapID) }
        return try await base.scene(day: day, mapID: mapID)
    }

    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle] {
        try await base.circles(day: day, tableID: tableID)
    }

    func circlePlacements(in viewport: CatalogMapViewport) async throws
        -> [CatalogMapCirclePlacement]
    {
        try await base.circlePlacements(in: viewport)
    }

    func circleImages(circleIDs: [Int]) async throws -> [Int: Data] {
        try await base.circleImages(circleIDs: circleIDs)
    }

    func search(day: Int, query: String) async throws -> [CatalogMapSearchMatch] {
        try await base.search(day: day, query: query)
    }

    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement] {
        try await base.genrePlacements(day: day, mapID: mapID)
    }

    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(updateIDs: updateIDs)
    }

    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(publicCircleIDs: publicCircleIDs)
    }
}

private actor SelectivelyFailingMapCatalog: MapCatalog {
    private let base = FixtureMapCatalog()
    private let failingMapIDs: Set<Int>
    private var sceneRequestCounts: [CatalogMapScene.ID: Int] = [:]

    init(failingMapIDs: Set<Int>) {
        self.failingMapIDs = failingMapIDs
    }

    func requestCount(day: Int, mapID: Int) -> Int {
        sceneRequestCounts[.init(day: day, mapID: mapID), default: 0]
    }

    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene {
        sceneRequestCounts[.init(day: day, mapID: mapID), default: 0] += 1
        guard !failingMapIDs.contains(mapID) else {
            throw MapCatalogError.missingMap(mapID)
        }
        return try await base.scene(day: day, mapID: mapID)
    }

    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle] {
        try await base.circles(day: day, tableID: tableID)
    }

    func circlePlacements(in viewport: CatalogMapViewport) async throws
        -> [CatalogMapCirclePlacement]
    {
        try await base.circlePlacements(in: viewport)
    }

    func circleImages(circleIDs: [Int]) async throws -> [Int: Data] {
        try await base.circleImages(circleIDs: circleIDs)
    }

    func search(day: Int, query: String) async throws -> [CatalogMapSearchMatch] {
        try await base.search(day: day, query: query)
    }

    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement] {
        try await base.genrePlacements(day: day, mapID: mapID)
    }

    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(updateIDs: updateIDs)
    }

    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(publicCircleIDs: publicCircleIDs)
    }
}

private actor PausableMapCatalog: MapCatalog {
    private let base = FixtureMapCatalog()
    private var pauseTarget: (day: Int, mapID: Int)?
    private var isScenePaused = false
    private var sceneContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var sceneRequests: [(day: Int, mapID: Int)] = []

    func pauseNextScene(day: Int, mapID: Int) {
        pauseTarget = (day, mapID)
    }

    func waitUntilSceneIsPaused() async {
        guard !isScenePaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resumePausedScene() {
        sceneContinuation?.resume()
        sceneContinuation = nil
    }

    func requestedMapIDs(day: Int) -> [Int] {
        sceneRequests.compactMap { request in
            request.day == day ? request.mapID : nil
        }
    }

    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene {
        sceneRequests.append((day, mapID))
        if pauseTarget?.day == day, pauseTarget?.mapID == mapID {
            pauseTarget = nil
            isScenePaused = true
            pauseWaiters.forEach { $0.resume() }
            pauseWaiters.removeAll()
            await withCheckedContinuation { continuation in
                sceneContinuation = continuation
            }
            isScenePaused = false
        }
        return try await base.scene(day: day, mapID: mapID)
    }

    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle] {
        try await base.circles(day: day, tableID: tableID)
    }

    func circlePlacements(in viewport: CatalogMapViewport) async throws
        -> [CatalogMapCirclePlacement]
    {
        try await base.circlePlacements(in: viewport)
    }

    func circleImages(circleIDs: [Int]) async throws -> [Int: Data] {
        try await base.circleImages(circleIDs: circleIDs)
    }

    func search(day: Int, query: String) async throws -> [CatalogMapSearchMatch] {
        try await base.search(day: day, query: query)
    }

    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement] {
        try await base.genrePlacements(day: day, mapID: mapID)
    }

    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(updateIDs: updateIDs)
    }

    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        try await base.bookmarkLocations(publicCircleIDs: publicCircleIDs)
    }
}

private final class MapArtworkDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let image: CGImage
    private var decodedCount = 0

    init(image: CGImage) {
        self.image = image
    }

    var count: Int {
        lock.withLock { decodedCount }
    }

    func decode(_ data: Data) -> CGImage? {
        lock.withLock { decodedCount += 1 }
        Thread.sleep(forTimeInterval: 0.002)
        return image
    }
}
