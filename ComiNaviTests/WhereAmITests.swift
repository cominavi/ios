import CoreGraphics
import XCTest

@testable import ComiNavi

final class WhereAmITests: XCTestCase {
    func testCanonicalComiketAddressIncludesExactHallAndTwoDigitSpace() {
        let address = ComiketSpaceAddress(
            day: 1,
            hallName: "東１",
            blockName: "Ａ",
            spaceNumber: 1,
            subspace: 0
        )

        XCTAssertEqual(address.spaceCode, "Ａ01a")
        XCTAssertEqual(address.canonicalDayText, "1日目")
        XCTAssertEqual(address.venueLocationText, "東1ホール Ａ01a")
        XCTAssertEqual(address.canonicalText, "1日目 東1ホール Ａ01a")
        XCTAssertEqual(address.nearbyText, "1日目 東1ホール Ａ01a付近")
    }

    func testCanonicalComiketAddressDoesNotDuplicateHallSuffix() {
        let address = ComiketSpaceAddress(
            day: 2,
            hallName: "西2ホール",
            blockName: "あ",
            spaceNumber: 12,
            subspace: 1
        )

        XCTAssertEqual(address.canonicalText, "2日目 西2ホール あ12b")
    }

    func testCombinedCircleAddressSupportsTwoLineDayAndVenuePresentation() {
        let address = ComiketSpaceAddress(
            day: 1,
            hallName: "東７",
            blockName: "Ａ",
            spaceNumber: 34,
            subspace: nil,
            isCombinedAB: true
        )

        XCTAssertEqual(address.canonicalDayText, "1日目")
        XCTAssertEqual(address.venueLocationText, "東7ホール Ａ34a+b")
        XCTAssertEqual(address.canonicalText, "1日目 東7ホール Ａ34a+b")
    }

    func testKanaLayoutUsesGojūonColumnsAndVowelOrder() throws {
        let layout = WhereAmICharacterLayout.make(
            availableCharacters: ["よ", "き", "あ", "ゆ", "か", "や"]
        )
        guard case .kana(let columns) = layout.mode else {
            return XCTFail("Expected kana layout")
        }

        XCTAssertEqual(columns.map(\.id), ["あ", "か", "や"])
        XCTAssertEqual(columns[1].cells.map(\.character), ["か", "き", nil, nil, nil])
        XCTAssertEqual(columns[2].cells.map(\.character), ["や", nil, "ゆ", nil, "よ"])
        XCTAssertEqual(layout.orderedCharacters, ["あ", "か", "き", "や", "ゆ", "よ"])
    }

    func testCharacterSearchMatchesHiraganaKatakanaAndRomaji() {
        let characters = ["さ", "し", "す", "つ", "シ", "ツ", "ア"]

        XCTAssertEqual(
            WhereAmICharacterSearch.filter(characters, query: "し"),
            ["し", "シ"]
        )
        XCTAssertEqual(
            WhereAmICharacterSearch.filter(characters, query: "シ"),
            ["し", "シ"]
        )
        XCTAssertEqual(
            WhereAmICharacterSearch.filter(characters, query: "shi"),
            ["し", "シ"]
        )
        XCTAssertEqual(
            WhereAmICharacterSearch.filter(characters, query: "TSU"),
            ["つ", "ツ"]
        )
        XCTAssertEqual(
            WhereAmICharacterSearch.filter(characters, query: "ｔｓｕ"),
            ["つ", "ツ"]
        )
    }

    func testFullWidthAlphabetUsesAlphabeticalOrder() throws {
        let layout = WhereAmICharacterLayout.make(
            availableCharacters: ["Ｃ", "Ａ", "Ｂ"]
        )
        guard case .alphabet(let characters) = layout.mode else {
            return XCTFail("Expected alphabet layout")
        }

        XCTAssertEqual(characters, ["Ａ", "Ｂ", "Ｃ"])
        XCTAssertTrue(layout.usesOnlyLatinAlphabet)
    }

    func testCaseNoticeIsLimitedToLatinAlphabetLayouts() {
        let numericLayout = WhereAmICharacterLayout.make(
            availableCharacters: ["1", "2", "3"]
        )

        XCTAssertFalse(numericLayout.usesOnlyLatinAlphabet)
    }

    func testNearestVenueUsesGeographicAnchorsButRejectsDistantReadings() throws {
        let east = venue(
            id: 1,
            name: "East 1–3",
            kind: .east123,
            coordinate: BigSightCampusLayout.eastBuilding
        )
        let west = venue(
            id: 2,
            name: "West 1–2",
            kind: .west,
            coordinate: BigSightCampusLayout.westBuilding
        )
        let nearby = WhereAmILocationReading(
            coordinate: GeographicCoordinate(latitude: 35.6318, longitude: 139.7978),
            horizontalAccuracy: 18,
            timestamp: .now
        )
        let distant = WhereAmILocationReading(
            coordinate: GeographicCoordinate(latitude: 35.6762, longitude: 139.6503),
            horizontalAccuracy: 20,
            timestamp: .now
        )

        XCTAssertEqual(
            WhereAmIResolver.nearestVenue(to: nearby, venues: [west, east])?.id, east.id)
        XCTAssertNil(WhereAmIResolver.nearestVenue(to: distant, venues: [west, east]))
    }

    func testTableResolutionAndLocatedUserPreserveHeadingAndGPSReading() throws {
        let venue = venue(
            id: 4,
            name: "West 1–2",
            kind: .west,
            coordinate: BigSightCampusLayout.westBuilding,
            rotation: -.pi / 4
        )
        let table = try XCTUnwrap(
            WhereAmIResolver.table(blockName: "あ", number: 12, in: venue.placement.scene)
        )
        let reading = WhereAmILocationReading(
            coordinate: BigSightCampusLayout.westBuilding,
            horizontalAccuracy: 24,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let user = WhereAmIResolver.locatedUser(
            at: table,
            in: venue,
            subspace: 1,
            headingDegrees: 90,
            locationReading: reading,
            placedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(user.point, CGPoint(x: 120, y: 220))
        XCTAssertEqual(user.headingDegrees, 90)
        XCTAssertEqual(try XCTUnwrap(user.mapHeadingRadians), .pi * 3 / 4, accuracy: 0.000_001)
        XCTAssertEqual(user.locationReading, reading)
        XCTAssertEqual(user.spaceCode, "あ12b")
        XCTAssertEqual(user.canonicalLocationText, "1日目 西ホール あ12b付近")
        XCTAssertEqual(user.source, .guidedLocator)
    }

    func testGuidedLocationOmitsSideWhenItWasNotAsked() throws {
        let venue = venue(
            id: 1,
            name: "East 1–3",
            kind: .east123,
            coordinate: BigSightCampusLayout.eastBuilding
        )
        let table = try XCTUnwrap(
            WhereAmIResolver.table(blockName: "あ", number: 12, in: venue.placement.scene)
        )
        let user = WhereAmIResolver.locatedUser(
            at: table,
            in: venue,
            subspace: nil,
            headingDegrees: nil,
            locationReading: nil
        )

        XCTAssertEqual(user.spaceCode, "あ12")
        XCTAssertEqual(user.canonicalLocationText, "1日目 東1–3ホール あ12付近")
    }

    func testDestinationUsesTheSameCanonicalTableAddressWithoutInventingASide() throws {
        let venue = venue(
            id: 1,
            name: "East 1–3",
            kind: .east123,
            coordinate: BigSightCampusLayout.eastBuilding
        )
        let table = try XCTUnwrap(
            WhereAmIResolver.table(blockName: "あ", number: 12, in: venue.placement.scene)
        )

        let destination = WhereAmIResolver.destination(
            at: table,
            in: venue,
            selectedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(destination.sceneID, venue.placement.scene.id)
        XCTAssertEqual(destination.point, CGPoint(x: 120, y: 220))
        XCTAssertEqual(destination.spaceCode, "あ12")
        XCTAssertEqual(destination.canonicalLocationText, "1日目 東1–3ホール あ12")
    }

    func testSharedDestinationPreservesSideAndUsesThatHalfOfTheTable() throws {
        let venue = venue(
            id: 1,
            name: "East 1–3",
            kind: .east123,
            coordinate: BigSightCampusLayout.eastBuilding
        )
        let table = try XCTUnwrap(
            WhereAmIResolver.table(blockName: "あ", number: 12, in: venue.placement.scene)
        )

        let destination = WhereAmIResolver.destination(
            at: table,
            in: venue,
            subspace: 1,
            selectedAt: Date(timeIntervalSince1970: 301)
        )

        XCTAssertEqual(destination.subspace, 1)
        XCTAssertEqual(destination.point, CGPoint(x: 130, y: 220))
        XCTAssertEqual(destination.spaceCode, "あ12b")
        XCTAssertEqual(destination.canonicalLocationText, "1日目 東1–3ホール あ12b")
    }

    func testMapPointResolvesNearestTableAndOrientationAwareSubspace() throws {
        let venue = venue(
            id: 1,
            name: "East 1–3",
            kind: .east123,
            coordinate: BigSightCampusLayout.eastBuilding
        )
        let scene = venue.placement.scene
        let table = try XCTUnwrap(
            WhereAmIResolver.nearestTable(to: CGPoint(x: 80, y: 220), in: scene))

        XCTAssertEqual(table.id.spaceNumber, 12)
        XCTAssertEqual(
            WhereAmIResolver.subspace(at: CGPoint(x: 105, y: 220), in: table, scene: scene),
            0
        )
        XCTAssertEqual(
            WhereAmIResolver.subspace(at: CGPoint(x: 135, y: 220), in: table, scene: scene),
            1
        )
    }

    func testLocationFreshnessExpiresAfterFifteenSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reading = WhereAmILocationReading(
            coordinate: BigSightCampusLayout.entrancePlaza,
            horizontalAccuracy: 30,
            timestamp: now.addingTimeInterval(-10)
        )

        XCTAssertTrue(reading.isLive(at: now))
        XCTAssertFalse(reading.isLive(at: now.addingTimeInterval(6)))
    }

    func testVenueNamesAreReadableAcrossCatalogGenerations() {
        XCTAssertEqual(WhereAmIResolver.venueDisplayName(for: "東123"), "East 1–3")
        XCTAssertEqual(WhereAmIResolver.venueDisplayName(for: "東456"), "East 4–6")
        XCTAssertEqual(WhereAmIResolver.venueDisplayName(for: "東78"), "East 7–8")
        XCTAssertEqual(WhereAmIResolver.venueDisplayName(for: "西12"), "West 1–2")
    }

    private func venue(
        id: Int,
        name: String,
        kind: BigSightVenuePlacement.Kind,
        coordinate: GeographicCoordinate,
        rotation: CGFloat = 0
    ) -> WhereAmIVenueOption {
        let scene = CatalogMapScene(
            id: .init(day: 1, mapID: id),
            name: name,
            size: CGSize(width: 400, height: 400),
            tableSize: CGSize(width: 40, height: 40),
            tables: [
                CatalogMapTable(
                    id: .init(blockID: 1, spaceNumber: 12),
                    blockName: "あ",
                    origin: CGPoint(x: 100, y: 200),
                    orientation: .aLeft
                )
            ]
        )
        return WhereAmIVenueOption(
            displayName: name,
            placement: BigSightVenuePlacement(
                kind: kind,
                scene: scene,
                coordinate: coordinate,
                center: .zero,
                rotation: rotation,
                metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
            )
        )
    }
}
