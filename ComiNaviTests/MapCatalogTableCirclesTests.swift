import Foundation
import GRDB
import XCTest

@testable import ComiNavi

final class MapCatalogTableCirclesTests: XCTestCase {
    func testBatchedLookupMatchesSingleTableLookupsAndDetectsCombinedBooths() async throws {
        let database = try makeDatabase()
        let catalog = SQLiteMapCatalog(mainDatabase: database, imageDatabase: database)

        let bothHalvesSameName = table(day: 1, block: 1, space: 1)
        let bothHalvesSamePortal = table(day: 1, block: 1, space: 2)
        let twoDifferentCircles = table(day: 1, block: 1, space: 3)
        let singleCircleOtherDay = table(day: 2, block: 1, space: 1)
        let notRequested = table(day: 1, block: 2, space: 1)
        let empty = table(day: 1, block: 1, space: 9)
        let requested: Set = [
            bothHalvesSameName,
            bothHalvesSamePortal,
            twoDifferentCircles,
            singleCircleOtherDay,
            empty,
        ]

        let batched = try await catalog.circles(forTables: requested)

        for key in requested {
            let single = try await catalog.circles(day: key.day, tableID: key.tableID)
            XCTAssertEqual(batched[key] ?? [], single, "\(key)")
        }
        XCTAssertNil(batched[notRequested])
        XCTAssertNil(batched[empty])

        // A table is requested for one favorited or planned half, but the
        // read returns both halves, so a+b is still detected.
        XCTAssertEqual(batched[bothHalvesSameName]?.map(\.subspace), [0, 1])
        XCTAssertTrue(CatalogCirclePairing.isCombinedAB(batched[bothHalvesSameName] ?? []))
        XCTAssertTrue(CatalogCirclePairing.isCombinedAB(batched[bothHalvesSamePortal] ?? []))
        XCTAssertFalse(CatalogCirclePairing.isCombinedAB(batched[twoDifferentCircles] ?? []))
        XCTAssertFalse(CatalogCirclePairing.isCombinedAB(batched[singleCircleOtherDay] ?? []))

        let none = try await catalog.circles(forTables: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testBatchedLookupOfManyDemoCatalogTablesIsOneFastRead() async throws {
        let mainURL = try XCTUnwrap(
            CatalogResourceLocator.url(named: "demo-c104-main.sqlite")
        )
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: mainURL.path, configuration: configuration)
        let catalog = SQLiteMapCatalog(mainDatabase: database, imageDatabase: database)

        let tables = try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT day, blockId, spaceNo
                    FROM ComiketCircleWC
                    WHERE day > 0 AND blockId > 0 AND spaceNo > 0
                    ORDER BY day, blockId, spaceNo
                    LIMIT 800
                    """
            ).map { row in
                CatalogMapDayTable(
                    day: row["day"],
                    tableID: .init(blockID: row["blockId"], spaceNumber: row["spaceNo"])
                )
            }
        }
        XCTAssertGreaterThanOrEqual(tables.count, 500)

        let start = ContinuousClock.now
        let batched = try await catalog.circles(forTables: Set(tables))
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(Set(batched.keys), Set(tables))
        // Per-table lookups scan the catalog once per table (about 11 s for
        // 1,000 tables). One read stays far below this generous budget even
        // on a loaded build machine.
        XCTAssertLessThan(elapsed, .seconds(5))

        for key in tables.prefix(25) {
            let single = try await catalog.circles(day: key.day, tableID: key.tableID)
            XCTAssertEqual(batched[key], single, "\(key)")
        }
    }

    private func table(day: Int, block: Int, space: Int) -> CatalogMapDayTable {
        CatalogMapDayTable(day: day, tableID: .init(blockID: block, spaceNumber: space))
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { database in
            try database.create(table: "ComiketCircleWC") { table in
                table.column("id", .integer).primaryKey()
                table.column("updateId", .integer)
                table.column("day", .integer).notNull()
                table.column("blockId", .integer).notNull()
                table.column("spaceNo", .integer).notNull()
                table.column("spaceNoSub", .integer).notNull()
                table.column("genreId", .integer)
                table.column("circleName", .text)
                table.column("penName", .text)
                table.column("description", .text)
                table.column("circlems", .text)
            }
            try database.create(table: "ComiketCircleExtend") { table in
                table.column("id", .integer).primaryKey()
                table.column("WCId", .integer)
                table.column("CirclemsPortalURL", .text)
            }
            try database.create(table: "ComiketGenreWC") { table in
                table.column("id", .integer).primaryKey()
                table.column("name", .text)
            }
            try database.execute(sql: """
                INSERT INTO ComiketGenreWC(id, name) VALUES (1, 'Genre');
                INSERT INTO ComiketCircleWC(id, updateId, day, blockId, spaceNo, spaceNoSub, genreId, circleName, penName)
                VALUES
                    (1, 101, 1, 1, 1, 0, 1, 'Same Circle', 'Pen'),
                    (2, 102, 1, 1, 1, 1, 1, 'Same Circle', 'Pen'),
                    (3, 103, 1, 1, 2, 0, 1, 'Spelling A', 'Pen A'),
                    (4, 104, 1, 1, 2, 1, 1, 'Spelling B', 'Pen B'),
                    (5, 105, 1, 1, 3, 0, 1, 'First', 'One'),
                    (6, 106, 1, 1, 3, 1, 1, 'Second', 'Two'),
                    (7, 107, 2, 1, 1, 0, 1, 'Same Circle', 'Pen'),
                    (8, 108, 1, 2, 1, 0, 1, 'Elsewhere', 'Pen');
                INSERT INTO ComiketCircleExtend(id, WCId, CirclemsPortalURL)
                VALUES
                    (1, 1001, NULL),
                    (2, 1002, NULL),
                    (3, 1003, 'https://portal.circle.ms/Circle/Index/10000001'),
                    (4, 1004, 'https://portal.circle.ms/Circle/Index/10000001'),
                    (5, 1005, NULL),
                    (6, 1006, NULL),
                    (7, 1007, NULL),
                    (8, 1008, NULL);
                """)
        }
        return database
    }
}
