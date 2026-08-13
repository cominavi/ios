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
