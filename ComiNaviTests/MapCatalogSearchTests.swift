import Foundation
import GRDB
import XCTest
@testable import ComiNavi

@MainActor
final class MapCatalogSearchTests: XCTestCase {
    private let oppositeScriptQueries = [
        "あいすここなすてっかー",
        "かたかな作家",
        "ブルーアーカイブ",
    ]

    func testSQLiteFallbackSearchesEveryVenueForDayAndNormalizesKana() async throws {
        let database = try makeCatalogDatabase()
        let catalog = SQLiteMapCatalog(
            mainDatabase: database,
            imageDatabase: database
        )
        let exploreModel = ExploreModel(circles: [makeExploreCircle()], selectedDay: 1)
        await exploreModel.load()

        for query in oppositeScriptQueries {
            let mapMatches = try await catalog.search(day: 1, query: query)
            XCTAssertEqual(mapMatches.map(\.id), [1, 3], "Map fallback failed for \(query)")
            XCTAssertEqual(mapMatches.map(\.mapID), [1, 2])

            exploreModel.searchQuery = query
            await exploreModel.waitForSearch()
            XCTAssertEqual(
                exploreModel.visibleCircles.map(\.id),
                [1],
                "Explore failed for \(query)"
            )
        }

        let otherDayMatches = try await catalog.search(day: 2, query: oppositeScriptQueries[0])
        XCTAssertEqual(otherDayMatches.map(\.id), [4])
        XCTAssertEqual(otherDayMatches.map(\.mapID), [2])
    }

    func testIndexedSearchesEveryVenueForDayAndNormalizesKana() async throws {
        let database = try makeCatalogDatabase()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-catalog-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = try MapCatalogIndex(
            sourceDatabase: database,
            cacheDatabasePath: directory.appendingPathComponent("index.sqlite").path,
            catalogDigest: "kana-search-fixture"
        )
        let catalog = SQLiteMapCatalog(
            mainDatabase: database,
            imageDatabase: database,
            index: index
        )

        for query in oppositeScriptQueries {
            let matches = try await catalog.search(day: 1, query: query)
            XCTAssertEqual(matches.map(\.id), [1, 3], "Map index failed for \(query)")
            XCTAssertEqual(matches.map(\.mapID), [1, 2])
            XCTAssertEqual(matches.first?.circleName, "アイスココナステッカー")
            XCTAssertEqual(matches.first?.penName, "カタカナ作家")
        }

        let otherDayMatches = try await catalog.search(day: 2, query: oppositeScriptQueries[0])
        XCTAssertEqual(otherDayMatches.map(\.id), [4])
        XCTAssertEqual(otherDayMatches.map(\.mapID), [2])
    }

    func testIndexedSearchHandlesShortQueriesWithoutScanningSourceCatalog() async throws {
        let database = try makeCatalogDatabase()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-catalog-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = try MapCatalogIndex(
            sourceDatabase: database,
            cacheDatabasePath: directory.appendingPathComponent("index.sqlite").path,
            catalogDigest: "short-query-fixture"
        )
        let catalog = SQLiteMapCatalog(
            mainDatabase: database,
            imageDatabase: database,
            index: index
        )

        _ = try await catalog.search(day: 1, query: oppositeScriptQueries[0])
        try await database.write { database in
            try database.drop(table: "ComiketCircleWC")
        }

        let matches = try await catalog.search(day: 1, query: "アイ")
        XCTAssertEqual(matches.map(\.id), [1, 3])
        XCTAssertEqual(matches.map(\.mapID), [1, 2])
        let percentMatches = try await catalog.search(day: 1, query: "%")
        let underscoreMatches = try await catalog.search(day: 1, query: "_")
        XCTAssertTrue(percentMatches.isEmpty)
        XCTAssertTrue(underscoreMatches.isEmpty)
    }

    func testBookmarkLocationsRetainExactHallWithinCombinedMap() async throws {
        let database = try makeBookmarkLocationDatabase()
        let catalog = SQLiteMapCatalog(mainDatabase: database, imageDatabase: database)

        let updateLocations = try await catalog.bookmarkLocations(updateIDs: [101, 102])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: updateLocations.map { ($0.updateID, $0.hallName) })[101]!,
            "東１"
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: updateLocations.map { ($0.updateID, $0.hallName) })[102]!,
            "東2"
        )

        let publicLocations = try await catalog.bookmarkLocations(publicCircleIDs: [1001, 1002])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: publicLocations.map {
                ($0.publicCircleID, $0.hallName)
            })[1001]!,
            "東１"
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: publicLocations.map {
                ($0.publicCircleID, $0.hallName)
            })[1002]!,
            "東2"
        )
        XCTAssertEqual(
            publicLocations.sorted { $0.publicCircleID < $1.publicCircleID }
                .map { ComiketSpaceAddress.canonicalHallName($0.hallName ?? "") },
            ["東1ホール", "東2ホール"]
        )

        let broadMapEvent = makeCombinedMapEvent()
        let eastOne = try XCTUnwrap(publicLocations.first { $0.publicCircleID == 1001 })
        XCTAssertEqual(eastOne.resolvedHallName(in: broadMapEvent), "東１")

        let legacyLocation = CatalogBookmarkLocation(
            publicCircleID: 1003,
            catalogCircleID: 3,
            updateID: 103,
            day: 1,
            mapID: 101,
            tableID: .init(blockID: 3, spaceNumber: 3),
            subspace: 0,
            hallName: nil
        )
        XCTAssertEqual(legacyLocation.resolvedHallName(in: broadMapEvent), "東123")
    }

    private func makeCatalogDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { database in
            try database.create(table: "ComiketCircleWC") { table in
                table.column("id", .integer).primaryKey()
                table.column("day", .integer).notNull()
                table.column("blockId", .integer).notNull()
                table.column("spaceNo", .integer).notNull()
                table.column("spaceNoSub", .integer).notNull()
                table.column("circleName", .text)
                table.column("circleKana", .text)
                table.column("penName", .text)
                table.column("description", .text)
            }
            try database.create(table: "ComiketLayoutWC") { table in
                table.column("blockId", .integer).notNull()
                table.column("spaceNo", .integer).notNull()
                table.column("mapId", .integer).notNull()
                table.column("xpos2", .integer).notNull()
                table.column("ypos2", .integer).notNull()
            }
            try database.create(table: "ComiketInfoWC") { table in
                table.column("map2SizeW", .integer).notNull()
                table.column("map2SizeH", .integer).notNull()
            }
            try database.execute(
                sql: "INSERT INTO ComiketInfoWC(map2SizeW, map2SizeH) VALUES (40, 40)"
            )
            try database.execute(
                sql: """
                    INSERT INTO ComiketLayoutWC(blockId, spaceNo, mapId, xpos2, ypos2)
                    VALUES (10, 20, 1, 100, 200),
                           (11, 21, 1, 140, 200),
                           (12, 22, 2, 100, 240),
                           (13, 23, 2, 140, 240)
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO ComiketCircleWC(
                        id, day, blockId, spaceNo, spaceNoSub,
                        circleName, circleKana, penName, description
                    ) VALUES
                        (1, 1, 10, 20, 0, ?, ?, ?, ?),
                        (2, 1, 11, 21, 0, ?, ?, ?, ?),
                        (3, 1, 12, 22, 0, ?, ?, ?, ?),
                        (4, 2, 13, 23, 0, ?, ?, ?, ?)
                    """,
                arguments: [
                    "アイスココナステッカー",
                    "アイスココナステッカー",
                    "カタカナ作家",
                    "ぶるーあーかいぶ",
                    "オリジナル雑貨",
                    "オリジナルザッカ",
                    "別の作家",
                    "創作作品",
                    "アイスココナステッカー",
                    "アイスココナステッカー",
                    "カタカナ作家",
                    "ぶるーあーかいぶ",
                    "アイスココナステッカー",
                    "アイスココナステッカー",
                    "カタカナ作家",
                    "ぶるーあーかいぶ",
                ]
            )
        }
        return database
    }

    private func makeBookmarkLocationDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { database in
            try database.create(table: "ComiketCircleWC") { table in
                table.column("id", .integer).primaryKey()
                table.column("updateId", .integer).notNull()
                table.column("day", .integer).notNull()
                table.column("blockId", .integer).notNull()
                table.column("spaceNo", .integer).notNull()
                table.column("spaceNoSub", .integer).notNull()
            }
            try database.create(table: "ComiketCircleExtend") { table in
                table.column("id", .integer).primaryKey()
                table.column("WCId", .integer).notNull()
            }
            try database.create(table: "ComiketLayoutWC") { table in
                table.column("blockId", .integer).notNull()
                table.column("spaceNo", .integer).notNull()
                table.column("mapId", .integer).notNull()
                table.column("hallId", .integer)
            }
            try database.create(table: "ComiketAreaWC") { table in
                table.column("id", .integer).primaryKey()
                table.column("name", .text)
            }
            try database.execute(sql: """
                INSERT INTO ComiketAreaWC(id, name) VALUES (11, '東１'), (12, '東2');
                INSERT INTO ComiketLayoutWC(blockId, spaceNo, mapId, hallId)
                VALUES (1, 1, 101, 11), (2, 2, 101, 12);
                INSERT INTO ComiketCircleWC(id, updateId, day, blockId, spaceNo, spaceNoSub)
                VALUES (1, 101, 1, 1, 1, 0), (2, 102, 1, 2, 2, 1);
                INSERT INTO ComiketCircleExtend(id, WCId) VALUES (1, 1001), (2, 1002);
                """)
        }
        return database
    }

    private func makeCombinedMapEvent() -> Comiket {
        Comiket(
            id: "108",
            number: 108,
            name: "コミックマーケット108",
            cover: nil,
            days: [UFDSchema.Day(
                id: "108_1",
                dayIndex: 1,
                date: DateComponents(year: 2026, month: 8, day: 15),
                halls: [UFDSchema.DayHall(
                    id: "108_1_E123",
                    name: "東123",
                    mapName: "E123",
                    externalMapId: 101,
                    externalCorrespondingFloorId: 1,
                    areas: []
                )]
            )],
            blocks: []
        )
    }

    private func makeExploreCircle() -> ExploreCircle {
        ExploreCircle(
            circle: CirclemsDataSchema.ComiketCircleWC(
                comiketNo: 108,
                id: 1,
                pageNo: 1,
                cutIndex: 1,
                day: 1,
                blockId: 10,
                spaceNo: 20,
                spaceNoSub: 0,
                genreId: 1,
                circleName: "アイスココナステッカー",
                circleKana: "アイスココナステッカー",
                penName: "カタカナ作家",
                bookName: nil,
                url: nil,
                mailAddr: nil,
                description: "ぶるーあーかいぶ",
                memo: nil,
                updateId: 1,
                updateData: nil,
                circlems: nil,
                rss: nil,
                updateFlag: nil
            ),
            genreName: "Animation",
            blockName: "A",
            tags: []
        )
    }
}
