import CoreGraphics
import XCTest
@testable import ComiNavi

final class BigSightCampusLayoutTests: XCTestCase {
    func testPedestrianWayDecoderPreservesJOSMNodeTopology() throws {
        let data = try XCTUnwrap(
            """
            {
              "type": "FeatureCollection",
              "features": [{
                "type": "Feature",
                "properties": {
                  "osm_id": -10,
                  "kind": "footway",
                  "indoor": true,
                  "covered": false,
                  "node_refs": [-1, -2]
                },
                "geometry": {
                  "type": "LineString",
                  "coordinates": [[139.796, 35.630], [139.797, 35.631]]
                }
              }]
            }
            """.data(using: .utf8)
        )

        let feature = try XCTUnwrap(BigSightPedestrianWayCatalog.decode(data).first)

        XCTAssertEqual(feature.nodeIDs, [-1, -2])
        XCTAssertEqual(feature.points.count, 2)
    }

    func testProjectionKeepsEastRightAndNorthUp() {
        let east = BigSightCampusLayout.project(
            GeographicCoordinate(latitude: 35.6304, longitude: 139.7970)
        )
        let north = BigSightCampusLayout.project(
            GeographicCoordinate(latitude: 35.6314, longitude: 139.7960)
        )

        XCTAssertEqual(east.x, 90.7, accuracy: 1)
        XCTAssertEqual(east.y, 0, accuracy: 0.1)
        XCTAssertEqual(north.x, 0, accuracy: 0.1)
        XCTAssertEqual(north.y, -111.3, accuracy: 1)
    }

    func testGeographicProjectionRoundTripsForBasemapCamera() {
        let coordinate = GeographicCoordinate(latitude: 35.6331039, longitude: 139.7991998)
        let projected = BigSightCampusLayout.project(coordinate)
        let restored = BigSightCampusLayout.coordinate(from: projected)

        XCTAssertEqual(restored.latitude, coordinate.latitude, accuracy: 0.000_000_001)
        XCTAssertEqual(restored.longitude, coordinate.longitude, accuracy: 0.000_000_001)
    }

    func testC108VenuesUseTheirRealGeographicOrdering() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東7", mapName: "E7"),
            hall(id: 3, name: "西12", mapName: "W12"),
            hall(id: 4, name: "南12", mapName: "S12"),
        ], eventNumber: 108))
        let venues = Dictionary(uniqueKeysWithValues: campus.venues.map { ($0.kind, $0) })

        XCTAssertEqual(campus.venues.count, 4)
        XCTAssertGreaterThan(try XCTUnwrap(venues[.east7]).center.x, try XCTUnwrap(venues[.east123]).center.x)
        XCTAssertLessThan(try XCTUnwrap(venues[.east7]).center.y, try XCTUnwrap(venues[.east123]).center.y)
        XCTAssertGreaterThan(try XCTUnwrap(venues[.south]).center.y, try XCTUnwrap(venues[.west]).center.y)
        XCTAssertTrue(campus.venues.allSatisfy { campus.bounds.contains($0.bounds) })
    }

    func testC104EastRowsAreSeparatedWithinOneBuilding() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東456", mapName: "E456"),
            hall(id: 3, name: "東7", mapName: "E7"),
            hall(id: 4, name: "西12", mapName: "W12"),
        ]))
        let east123 = try XCTUnwrap(campus.venues.first { $0.kind == .east123 })
        let east456 = try XCTUnwrap(campus.venues.first { $0.kind == .east456 })

        XCTAssertEqual(
            hypot(east123.center.x - east456.center.x, east123.center.y - east456.center.y),
            151.394,
            accuracy: 0.1
        )
        XCTAssertTrue(campus.connections.contains { $0.id == "east-galleria" })
    }

    func testC104VenueCalibrationMatchesSavedAlignment() throws {
        let east123Hall = hall(id: 1, name: "東123", mapName: "E123")
        let east456Hall = hall(id: 2, name: "東456", mapName: "E456")
        let east7Hall = hall(id: 3, name: "東7", mapName: "E7")
        let westHall = hall(id: 4, name: "西12", mapName: "W12")
        let halls = [east123Hall, east456Hall, east7Hall, westHall]
        let campus = try XCTUnwrap(BigSightCampusLayout.make(
            eventNumber: 104,
            day: 1,
            halls: halls,
            scenes: [
                1: scene(for: east123Hall),
                2: scene(for: east456Hall, layoutRotation: .pi),
                3: scene(for: east7Hall),
                4: scene(for: westHall),
            ]
        ))
        let venues = Dictionary(uniqueKeysWithValues: campus.venues.map { ($0.kind, $0) })
        let expected: [BigSightVenuePlacement.Kind: (
            latitude: Double,
            longitude: Double,
            width: CGFloat,
            height: CGFloat,
            rotationDegrees: CGFloat
        )] = [
            .east123: (
                35.631057820055005,
                139.79794721575166,
                275.8224542031329,
                99.01318868830411,
                146.462
            ),
            .east456: (
                35.63237082511334,
                139.7975145453659,
                271.05487926318995,
                97.30175153037587,
                -33.53800000000001
            ),
            .east7: (
                35.633471367816355,
                139.7994204284449,
                113.01855361967942,
                122.28236949014496,
                -33.40707083299674
            ),
            .west: (
                35.62877144202331,
                139.79501092499783,
                205.27930023717607,
                145.97639127976964,
                146.97977914964463
            ),
        ]

        for (kind, alignment) in expected {
            let venue = try XCTUnwrap(venues[kind])
            XCTAssertEqual(venue.coordinate.latitude, alignment.latitude, accuracy: 0.000_000_000_001)
            XCTAssertEqual(venue.coordinate.longitude, alignment.longitude, accuracy: 0.000_000_000_001)
            XCTAssertEqual(
                venue.scene.size.width * venue.metersPerMapPoint,
                alignment.width,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                venue.scene.size.height * venue.verticalMetersPerMapPoint,
                alignment.height,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                venue.rotation * 180 / .pi,
                alignment.rotationDegrees,
                accuracy: 0.000_001
            )
        }
    }

    func testC108VenueCalibrationMatchesSavedAlignment() throws {
        let east123Hall = hall(id: 1, name: "東123", mapName: "E123")
        let east7Hall = hall(id: 2, name: "東7", mapName: "E7")
        let westHall = hall(id: 3, name: "西12", mapName: "W12")
        let southHall = hall(id: 4, name: "南12", mapName: "S12")
        let halls = [east123Hall, east7Hall, westHall, southHall]
        let campus = try XCTUnwrap(BigSightCampusLayout.make(
            eventNumber: 108,
            day: 1,
            halls: halls,
            scenes: Dictionary(uniqueKeysWithValues: halls.map { hall in
                (hall.externalMapId, scene(for: hall, eventNumber: 108))
            })
        ))
        let venues = Dictionary(uniqueKeysWithValues: campus.venues.map { ($0.kind, $0) })
        let expected: [BigSightVenuePlacement.Kind: (
            latitude: Double,
            longitude: Double,
            width: CGFloat,
            height: CGFloat,
            rotationDegrees: CGFloat
        )] = [
            .east123: (
                35.631057820055005,
                139.79794721575166,
                275.8224542031329,
                103.72809983536543,
                146.462
            ),
            .east7: (
                35.633471367816355,
                139.7994204284449,
                113.01855361967942,
                122.28236949014496,
                -33.40707083299674
            ),
            .west: (
                35.62877144202331,
                139.79501092499783,
                205.27930023717607,
                152.81943451220806,
                146.97977914964463
            ),
            .south: (
                35.62700699450169,
                139.7956005438195,
                164.32035141970715,
                90.11116045596845,
                56.39305764784899
            ),
        ]

        for (kind, alignment) in expected {
            let venue = try XCTUnwrap(venues[kind])
            XCTAssertEqual(venue.coordinate.latitude, alignment.latitude, accuracy: 0.000_000_000_001)
            XCTAssertEqual(venue.coordinate.longitude, alignment.longitude, accuracy: 0.000_000_000_001)
            XCTAssertEqual(
                venue.scene.size.width * venue.metersPerMapPoint,
                alignment.width,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                venue.scene.size.height * venue.verticalMetersPerMapPoint,
                alignment.height,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                venue.rotation * 180 / .pi,
                alignment.rotationDegrees,
                accuracy: 0.000_001
            )
        }
    }

    func testAuthoredImageRotationIsComposedWithBuildingRotation() throws {
        let east456Hall = hall(id: 2, name: "東456", mapName: "E456")
        let unrotatedCampus = try XCTUnwrap(BigSightCampusLayout.make(
            eventNumber: 104,
            day: 1,
            halls: [east456Hall],
            scenes: [2: scene(for: east456Hall)]
        ))
        let rotatedCampus = try XCTUnwrap(BigSightCampusLayout.make(
            eventNumber: 104,
            day: 1,
            halls: [east456Hall],
            scenes: [2: scene(for: east456Hall, layoutRotation: .pi)]
        ))
        let unrotated = try XCTUnwrap(unrotatedCampus.venues.first)
        let rotated = try XCTUnwrap(rotatedCampus.venues.first)

        XCTAssertEqual(
            normalizedAngle(rotated.rotation - unrotated.rotation),
            .pi,
            accuracy: 0.000_001
        )
    }

    func testConnectionGraphUsesNamedCampusPathsAndCalculatedDistances() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東7", mapName: "E7"),
            hall(id: 3, name: "西12", mapName: "W12"),
            hall(id: 4, name: "南12", mapName: "S12"),
        ]))

        XCTAssertEqual(
            Set(campus.connections.map(\.id)),
            [
                "east-link-space",
                "east-entrance-concourse",
                "entrance-west-atrium",
                "entrance-south-concourse",
            ]
        )
        XCTAssertTrue(campus.connections.allSatisfy { $0.distanceMeters > 100 })
        XCTAssertEqual(BigSightCampusLayout.metersPerMapPoint, 0.045, accuracy: 0.000_001)
    }

    func testCampusIncludesExactOpenStreetMapConnectingBridgeBoundary() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "西12", mapName: "W12"),
        ]))
        let bridge = try XCTUnwrap(campus.openStreetMapFeatures.first)

        XCTAssertEqual(bridge.id, 154_080_996)
        XCTAssertEqual(bridge.kind, .connectingBridge)
        XCTAssertEqual(bridge.coordinates.count, 6)
        let firstCoordinate = try XCTUnwrap(bridge.coordinates.first)
        XCTAssertEqual(firstCoordinate.latitude, 35.6312555, accuracy: 0.000_000_1)
        XCTAssertEqual(firstCoordinate.longitude, 139.7962873, accuracy: 0.000_000_1)
        XCTAssertTrue(bridge.points.allSatisfy(campus.bounds.contains))
    }

    func testCampusUsesCuratedOpenStreetMapPedestrianNetwork() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "西12", mapName: "W12"),
        ]))
        let pedestrianWays = campus.openStreetMapFeatures.filter {
            $0.kind == .footway || $0.kind == .steps
        }

        XCTAssertEqual(pedestrianWays.count, 47)
        XCTAssertEqual(pedestrianWays.filter { $0.kind == .footway }.count, 28)
        XCTAssertEqual(pedestrianWays.filter { $0.kind == .steps }.count, 19)
        XCTAssertEqual(Set(pedestrianWays.map(\.id)).count, pedestrianWays.count)
        XCTAssertTrue(pedestrianWays.contains { $0.id == 385_355_910 })
        XCTAssertTrue(pedestrianWays.contains { $0.id == 385_355_911 })
        XCTAssertFalse(pedestrianWays.contains { $0.id == 1_123_373_666 })
        XCTAssertTrue(pedestrianWays.allSatisfy { feature in
            feature.points.count >= 2 && feature.points.allSatisfy(campus.bounds.contains)
        })
    }

    func testCampusFacilitiesUseUniqueRealCoordinatesAndExpandBounds() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "西12", mapName: "W12"),
        ]))

        XCTAssertEqual(campus.facilities.count, 59)
        XCTAssertEqual(Set(campus.facilities.map(\.id)).count, campus.facilities.count)
        XCTAssertTrue(campus.facilities.allSatisfy { campus.bounds.contains($0.center) })
        XCTAssertEqual(
            campus.facilities.first { $0.id == "tokyo-big-sight-station" }?.kind.icon,
            .train
        )
        XCTAssertEqual(
            campus.facilities.first { $0.id == "general-information" }?.kind.icon,
            .information
        )
        XCTAssertNotNil(campus.facilities.first { $0.id == "kokusai-tenjijo-station" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "lawson-kokusai-station" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "big-sight-atm" })
        XCTAssertFalse(campus.facilities.contains { $0.id.hasPrefix("c108-") })
    }

    func testC108AddsEventScopedOperationsAndCorrectClosureGroundTruth() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東7", mapName: "E7"),
            hall(id: 3, name: "西12", mapName: "W12"),
            hall(id: 4, name: "南12", mapName: "S12"),
        ], eventNumber: 108))

        XCTAssertEqual(campus.facilities.count, 82)
        XCTAssertEqual(campus.operationalRoutes.count, 5)
        let closedHalls = try XCTUnwrap(campus.facilities.first { $0.id == "c108-east456-closed" })
        XCTAssertTrue(closedHalls.detail?.contains("2026") == true)
        XCTAssertNil(campus.facilities.first { $0.id == "c108-east123-closed" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-east-entry" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-afternoon-entry" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-qr-exchange-station" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-east-international" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-cosplay-east8" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-east-waiting-restroom" })
        XCTAssertNotNil(campus.facilities.first { $0.id == "c108-west-waiting-restroom" })
        XCTAssertNotNil(campus.operationalRoutes.first { $0.id == "c108-rinkai-east-arrival" })
        XCTAssertTrue(campus.operationalRoutes.allSatisfy { $0.layer == .crowdFlow })
    }

    func testC108ContextCoversEveryRequestedBehaviorAndFacilityClass() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東7", mapName: "E7"),
            hall(id: 3, name: "西12", mapName: "W12"),
            hall(id: 4, name: "南12", mapName: "S12"),
        ], eventNumber: 108))

        let coveredLayers = Set(campus.facilities.compactMap(\.layer))
            .union(campus.operationalRoutes.map(\.layer))
        XCTAssertEqual(coveredLayers, Set(BigSightMapLayer.allCases))
        XCTAssertEqual(Set(campus.facilities.map(\.id)).count, campus.facilities.count)
        XCTAssertEqual(Set(campus.operationalRoutes.map(\.id)).count, campus.operationalRoutes.count)
        XCTAssertTrue(campus.facilities.allSatisfy { campus.bounds.contains($0.center) })
        XCTAssertTrue(campus.operationalRoutes.allSatisfy { route in
            route.points.count >= 2 && route.points.allSatisfy(campus.bounds.contains)
        })

        let requiredKinds: [BigSightFacilityLocation.Kind] = [
            .restroom,
            .convenienceStore,
            .food,
            .atm,
            .train,
            .information,
            .internationalDesk,
            .firstAid,
            .entryGate,
            .waitingArea,
            .ticketExchange,
            .elevator,
            .escalator,
            .stairs,
            .cosplayArea,
            .cosplayChanging,
            .closedArea,
        ]
        for kind in requiredKinds {
            XCTAssertTrue(
                campus.facilities.contains { $0.kind == kind },
                "Missing required C108 facility class: \(kind)"
            )
        }

        let requiredIDs: Set<String> = [
            "kokusai-tenjijo-station",
            "lawson-kokusai-station",
            "big-sight-atm",
            "east1-restroom-outer",
            "east1-restroom-galleria",
            "west-atrium-restroom",
            "south-concourse-restroom",
            "east7-restroom",
            "east8-restroom",
            "c108-east-waiting-restroom",
            "c108-west-waiting-restroom",
            "c108-east-entry",
            "c108-west-south-entry",
            "c108-afternoon-entry",
            "c108-qr-exchange-station",
            "c108-qr-exchange-entrance",
            "c108-cosplay-early-tft",
            "c108-west-information",
            "c108-west-international",
            "c108-east-international",
            "c108-conference-first-aid",
            "c108-west-first-aid",
            "c108-south-first-aid",
            "c108-cosplay-east8",
            "c108-cosplay-east7-outdoor",
            "c108-cosplay-garden",
            "c108-cosplay-rooftop",
            "c108-cosplay-changing-women",
            "c108-cosplay-changing-men",
            "c108-east456-closed",
            "east1-elevator-west",
            "east1-escalator-west",
            "east1-elevator-east",
            "east1-escalator-east",
            "east1-stairs-east",
        ]
        let actualIDs = Set(campus.facilities.map(\.id))
        XCTAssertTrue(requiredIDs.isSubset(of: actualIDs), "Missing IDs: \(requiredIDs.subtracting(actualIDs))")
        XCTAssertNil(campus.facilities.first { $0.id == "c108-east123-closed" })

        XCTAssertGreaterThanOrEqual(campus.facilities.filter { $0.kind == .restroom }.count, 19)
        XCTAssertGreaterThanOrEqual(campus.facilities.filter { $0.kind == .convenienceStore }.count, 11)
        XCTAssertGreaterThanOrEqual(campus.facilities.filter { $0.kind == .atm }.count, 5)
        XCTAssertGreaterThanOrEqual(campus.facilities.filter { $0.kind == .train }.count, 2)
        XCTAssertTrue(campus.facilities.filter { $0.kind == .firstAid }.allSatisfy {
            $0.detail?.localizedCaseInsensitiveContains("ambulance") == true
        })

        XCTAssertEqual(
            Set(campus.operationalRoutes.map(\.id)),
            [
                "c108-rinkai-arrival",
                "c108-rinkai-east-arrival",
                "c108-yurikamome-arrival",
                "c108-east-entry-flow",
                "c108-east-galleria-flow",
            ]
        )
    }

    func testTaxiStandRemainsOutsideCalibratedVenueFootprints() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "東7", mapName: "E7"),
            hall(id: 3, name: "西12", mapName: "W12"),
            hall(id: 4, name: "南12", mapName: "S12"),
        ], eventNumber: 108))
        let taxiStand = try XCTUnwrap(
            campus.facilities.first { $0.id == "taxi-stand" }
        )

        XCTAssertFalse(
            campus.venues.contains { $0.contains(campusPoint: taxiStand.center) }
        )
    }

    func testEastHallOneVerticalAccessFollowsCalibratedVenueArtwork() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
        ], eventNumber: 108))
        let venue = try XCTUnwrap(campus.venues.first)
        let accessIDs: Set<String> = [
            "east1-elevator-west",
            "east1-escalator-west",
            "east1-elevator-east",
            "east1-escalator-east",
            "east1-stairs-east",
        ]
        let access = campus.facilities.filter { accessIDs.contains($0.id) }

        XCTAssertEqual(access.count, accessIDs.count)
        XCTAssertTrue(access.allSatisfy { venue.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.center) })
        XCTAssertTrue(access.allSatisfy { $0.layer == .verticalAccess })
        XCTAssertTrue(access.allSatisfy {
            $0.detail?.localizedCaseInsensitiveContains("staff") == true
                || $0.detail?.localizedCaseInsensitiveContains("direction") == true
        })

        let expectedNormalizedPositions: [String: CGPoint] = [
            "east1-elevator-west": CGPoint(x: 0.675, y: 0.970),
            "east1-escalator-west": CGPoint(x: 0.705, y: 0.970),
            "east1-elevator-east": CGPoint(x: 0.945, y: 0.960),
            "east1-escalator-east": CGPoint(x: 0.970, y: 0.960),
            "east1-stairs-east": CGPoint(x: 0.982, y: 0.500),
        ]
        let inverseVenueTransform = venue.transform.inverted()
        for facility in access {
            let local = facility.center.applying(inverseVenueTransform)
            let normalized = CGPoint(
                x: local.x / venue.scene.size.width,
                y: local.y / venue.scene.size.height
            )
            let expected = try XCTUnwrap(expectedNormalizedPositions[facility.id])
            XCTAssertEqual(normalized.x, expected.x, accuracy: 0.000_001)
            XCTAssertEqual(normalized.y, expected.y, accuracy: 0.000_001)
        }
    }

    @MainActor
    func testLayerVisibilityHidesOperationalMarkersWithoutHidingPermanentLandmarks() throws {
        let campus = try XCTUnwrap(makeCampus([
            hall(id: 1, name: "東123", mapName: "E123"),
            hall(id: 2, name: "西12", mapName: "W12"),
        ], eventNumber: 108))
        let renderer = UnifiedBigSightScene(campus: campus)

        XCTAssertEqual(renderer.operationalRouteCount, 5)
        XCTAssertTrue(renderer.isOperationalRouteVisible(id: "c108-rinkai-arrival"))
        XCTAssertTrue(renderer.isFacilityMarkerVisible(id: "c108-east-entry"))
        XCTAssertTrue(renderer.isFacilityMarkerVisible(id: "conference-tower"))

        renderer.updateVisibleMapLayers([])

        XCTAssertFalse(renderer.isFacilityMarkerVisible(id: "c108-east-entry"))
        XCTAssertFalse(renderer.isOperationalRouteVisible(id: "c108-rinkai-arrival"))
        XCTAssertTrue(renderer.isFacilityMarkerVisible(id: "conference-tower"))

        renderer.updateVisibleMapLayers([.gates])

        XCTAssertTrue(renderer.isFacilityMarkerVisible(id: "c108-east-entry"))
        XCTAssertFalse(renderer.isOperationalRouteVisible(id: "c108-rinkai-arrival"))

        renderer.updateVisibleMapLayers([.crowdFlow])

        XCTAssertTrue(renderer.isOperationalRouteVisible(id: "c108-rinkai-arrival"))
    }

    func testEveryVenueKindUsesItsComiNaviHallIcon() {
        XCTAssertEqual(BigSightVenuePlacement.Kind.east123.icon, .eastHalls)
        XCTAssertEqual(BigSightVenuePlacement.Kind.east456.icon, .eastHalls)
        XCTAssertEqual(BigSightVenuePlacement.Kind.east7.icon, .eastHalls)
        XCTAssertEqual(BigSightVenuePlacement.Kind.west.icon, .westHalls)
        XCTAssertEqual(BigSightVenuePlacement.Kind.south.icon, .southHalls)
    }

    private func makeCampus(
        _ halls: [UFDSchema.DayHall],
        eventNumber: Int = 104
    ) -> BigSightCampusScene? {
        BigSightCampusLayout.make(
            eventNumber: eventNumber,
            day: 1,
            halls: halls,
            scenes: Dictionary(uniqueKeysWithValues: halls.map { hall in
                (hall.externalMapId, scene(for: hall, eventNumber: eventNumber))
            })
        )
    }

    private func scene(
        for hall: UFDSchema.DayHall,
        eventNumber: Int = 104,
        layoutRotation: CGFloat = 0
    ) -> CatalogMapScene {
        CatalogMapScene(
            id: .init(day: 1, mapID: hall.externalMapId),
            name: hall.mapName,
            size: sceneSize(for: hall.mapName, eventNumber: eventNumber),
            tableSize: CGSize(width: 40, height: 40),
            tables: [
                CatalogMapTable(
                    id: .init(blockID: hall.externalMapId, spaceNumber: 1),
                    blockName: hall.name,
                    origin: CGPoint(x: 80, y: 80),
                    orientation: .aTop
                ),
            ],
            layoutRotation: layoutRotation
        )
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        let normalized = (angle.truncatingRemainder(dividingBy: twoPi) + twoPi)
            .truncatingRemainder(dividingBy: twoPi)
        return normalized > .pi ? twoPi - normalized : normalized
    }

    private func hall(id: Int, name: String, mapName: String) -> UFDSchema.DayHall {
        UFDSchema.DayHall(
            id: "hall-\(id)",
            name: name,
            mapName: mapName,
            externalMapId: id,
            externalCorrespondingFloorId: id,
            areas: []
        )
    }

    private func sceneSize(for mapName: String, eventNumber: Int) -> CGSize {
        switch mapName {
        case "E123": CGSize(width: 4_680, height: eventNumber == 108 ? 1_760 : 1_680)
        case "E456": CGSize(width: 4_680, height: 1_680)
        case "E7": CGSize(width: 2_440, height: 2_640)
        case "W12": CGSize(width: 3_600, height: eventNumber == 108 ? 2_680 : 2_560)
        case "S12": CGSize(width: 2_480, height: 1_360)
        default: CGSize(width: 2_000, height: 2_000)
        }
    }
}
