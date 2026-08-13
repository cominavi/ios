import CoreGraphics
import SpriteKit
import XCTest

@testable import ComiNavi

final class UnifiedBigSightMapTests: XCTestCase {
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
    func testGlobalSearchOverlaysEveryVenueAtCampusScope() {
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
    func testGuidedLocationGetsPersistentPuckAndCloseCameraFocus() async throws {
        let campus = makeSingleVenueCampus()
        let venue = try XCTUnwrap(campus.venues.first)
        let table = try XCTUnwrap(venue.scene.tables.first)
        let renderer = UnifiedBigSightScene(campus: campus)
        renderer.reduceMotion = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
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
        XCTAssertGreaterThanOrEqual(renderer.zoomFactor, 50)
        let userOnScreen = renderer.viewPoint(
            forCampus: user.point.applying(venue.transform),
            in: view
        )
        XCTAssertEqual(userOnScreen.x, view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(userOnScreen.y, view.bounds.midY, accuracy: 0.5)
        let markerPoint = try XCTUnwrap(renderer.userMarkerViewPoint(in: view))
        guard case .userLocation = renderer.hit(at: markerPoint, in: view) else {
            return XCTFail("The current-location marker should win map hit testing")
        }

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
            locationFocusBottomInset: 430
        )
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        let userAboveSheet = renderer.viewPoint(
            forCampus: user.point.applying(venue.transform),
            in: view
        )
        XCTAssertEqual(userAboveSheet.x, view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(
            userAboveSheet.y,
            (view.bounds.height - 430) / 2,
            accuracy: 0.5
        )
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
            390 - MapChromeLayout.attributionTrailingInset(showsCompass: false),
            accuracy: 0.5
        )
        XCTAssertLessThan(badge.frame.width, 100)
        XCTAssertLessThan(badge.frame.height, 24)
        XCTAssertEqual(badge.titleLabel?.font.pointSize ?? 0, 8, accuracy: 0.1)
        XCTAssertEqual(badge.configuration?.title, "© OpenStreetMap")
        XCTAssertEqual(badge.menu?.title, "Map data attribution")
        XCTAssertEqual(badge.menu?.children.count, 4)

        host.updateCompass(rotation: .pi / 4)
        host.setNeedsLayout()
        host.layoutIfNeeded()

        XCTAssertFalse(host.compassButton.isHidden)
        XCTAssertEqual(
            badge.frame.maxX,
            host.compassButton.frame.minX - MapChromeLayout.controlSpacing,
            accuracy: 0.5
        )
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
        host.updateCompass(rotation: renderer.cameraRotation)
        XCTAssertTrue(host.compassButton.usesTwoToneNeedle)

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
        host.layoutIfNeeded()
        host.mapView.presentScene(renderer)
        renderer.onCameraChange = { [weak host, weak renderer] in
            guard let host, let renderer else { return }
            host.updateBasemap(camera: renderer.basemapCamera)
        }
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
    }

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
