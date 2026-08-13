import Foundation
import GRDB

actor MapCatalogIndex {
    private enum MetadataKey {
        static let catalogDigest = "catalogDigest"
        static let searchFormatVersion = 2
    }

    private struct SourceCircle: Sendable {
        let circleID: Int
        let day: Int
        let mapID: Int
        let blockID: Int
        let spaceNumber: Int
        let subspace: Int
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let circleName: String
        let circleKana: String
        let penName: String
        let description: String
    }

    private let sourceDatabase: any DatabaseReader
    private let catalogDigest: String
    private let database: DatabasePool
    private var preparationTask: Task<Void, Error>?

    init(
        sourceDatabase: any DatabaseReader,
        cacheDatabasePath: String,
        catalogDigest: String
    ) throws {
        self.sourceDatabase = sourceDatabase
        self.catalogDigest = "\(catalogDigest):search-v\(MetadataKey.searchFormatVersion)"
        database = try DatabasePool(path: cacheDatabasePath)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("create-map-index") { database in
            try database.create(table: "index_metadata") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            try database.create(table: "circle_placement") { table in
                table.column("circleID", .integer).primaryKey()
                table.column("day", .integer).notNull()
                table.column("mapID", .integer).notNull()
                table.column("blockID", .integer).notNull()
                table.column("spaceNumber", .integer).notNull()
                table.column("subspace", .integer).notNull()
            }
            try database.create(
                index: "circle_placement_scene",
                on: "circle_placement",
                columns: ["day", "mapID"]
            )
            try database.execute(sql: """
                CREATE VIRTUAL TABLE circle_placement_bounds USING rtree(
                    circleID,
                    minX, maxX,
                    minY, maxY
                )
                """)
            try database.execute(sql: """
                CREATE VIRTUAL TABLE circle_search USING fts5(
                    circleID UNINDEXED,
                    day UNINDEXED,
                    mapID UNINDEXED,
                    blockID UNINDEXED,
                    spaceNumber UNINDEXED,
                    subspace UNINDEXED,
                    circleName,
                    circleKana,
                    penName,
                    description,
                    tokenize='trigram'
                )
                """)
        }
        try migrator.migrate(database)
    }

    func placements(in viewport: CatalogMapViewport) async throws -> [CatalogMapCirclePlacement] {
        try await prepareIfNeeded()
        let bounds = viewport.mapRect.insetBy(dx: -40, dy: -40)

        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT placement.circleID,
                           placement.blockID,
                           placement.spaceNumber,
                           placement.subspace
                    FROM circle_placement_bounds bounds
                    CROSS JOIN circle_placement placement ON placement.circleID = bounds.circleID
                    WHERE placement.day = ?
                      AND placement.mapID = ?
                      AND bounds.minX <= ?
                      AND bounds.maxX >= ?
                      AND bounds.minY <= ?
                      AND bounds.maxY >= ?
                    """,
                arguments: [
                    viewport.sceneID.day,
                    viewport.sceneID.mapID,
                    bounds.maxX,
                    bounds.minX,
                    bounds.maxY,
                    bounds.minY,
                ]
            ).compactMap(Self.placement(from:))
        }
    }

    func search(
        day: Int,
        normalizedTerms: [String]
    ) async throws -> [CatalogMapSearchMatch] {
        guard !normalizedTerms.isEmpty else { return [] }
        try await prepareIfNeeded()

        let matchExpression = normalizedTerms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")

        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT CAST(circleID AS INTEGER) AS circleID,
                           CAST(mapID AS INTEGER) AS mapID,
                           CAST(blockID AS INTEGER) AS blockID,
                           CAST(spaceNumber AS INTEGER) AS spaceNumber,
                           CAST(subspace AS INTEGER) AS subspace,
                           circleName,
                           penName
                    FROM circle_search
                    WHERE circle_search MATCH ?
                      AND CAST(day AS INTEGER) = ?
                    ORDER BY rank,
                             CAST(mapID AS INTEGER),
                             CAST(blockID AS INTEGER),
                             CAST(spaceNumber AS INTEGER),
                             CAST(subspace AS INTEGER)
                    LIMIT 1000
                    """,
                arguments: [matchExpression, day]
            ).compactMap { row -> CatalogMapSearchMatch? in
                guard let id: Int = row["circleID"],
                      let mapID: Int = row["mapID"],
                      let blockID: Int = row["blockID"],
                      let spaceNumber: Int = row["spaceNumber"]
                else {
                    return nil
                }
                return CatalogMapSearchMatch(
                    id: id,
                    mapID: mapID,
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
                    subspace: row["subspace"] ?? 0,
                    circleName: row["circleName"] ?? "",
                    penName: row["penName"] ?? ""
                )
            }
        }
    }

    private func prepareIfNeeded() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { [database, sourceDatabase, catalogDigest] in
            let storedDigest = try await database.read { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT value FROM index_metadata WHERE key = ?",
                    arguments: [MetadataKey.catalogDigest]
                )
            }
            guard storedDigest != catalogDigest else { return }

            let sourceCircles = try await sourceDatabase.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT circle.id,
                               circle.day,
                               layout.mapId,
                               circle.blockId,
                               circle.spaceNo,
                               circle.spaceNoSub,
                               layout.xpos2,
                               layout.ypos2,
                               info.map2SizeW,
                               info.map2SizeH,
                               circle.circleName,
                               circle.circleKana,
                               circle.penName,
                               circle.description
                        FROM ComiketCircleWC circle
                        JOIN ComiketLayoutWC layout
                          ON layout.blockId = circle.blockId
                         AND layout.spaceNo = circle.spaceNo
                        CROSS JOIN ComiketInfoWC info
                        """
                ).compactMap { row -> SourceCircle? in
                    guard let circleID: Int = row["id"],
                          let day: Int = row["day"],
                          let mapID: Int = row["mapId"],
                          let blockID: Int = row["blockId"],
                          let spaceNumber: Int = row["spaceNo"],
                          let minX: Int = row["xpos2"],
                          let minY: Int = row["ypos2"],
                          let width: Int = row["map2SizeW"],
                          let height: Int = row["map2SizeH"]
                    else {
                        return nil
                    }
                    return SourceCircle(
                        circleID: circleID,
                        day: day,
                        mapID: mapID,
                        blockID: blockID,
                        spaceNumber: spaceNumber,
                        subspace: row["spaceNoSub"] ?? 0,
                        minX: minX,
                        maxX: minX + width,
                        minY: minY,
                        maxY: minY + height,
                        circleName: row["circleName"] ?? "",
                        circleKana: row["circleKana"] ?? "",
                        penName: row["penName"] ?? "",
                        description: row["description"] ?? ""
                    )
                }
            }

            try await database.write { database in
                try database.execute(sql: "DELETE FROM circle_placement")
                try database.execute(sql: "DELETE FROM circle_placement_bounds")
                try database.execute(sql: "DELETE FROM circle_search")

                let placementStatement = try database.makeStatement(sql: """
                    INSERT INTO circle_placement(
                        circleID, day, mapID, blockID, spaceNumber, subspace
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """)
                let boundsStatement = try database.makeStatement(sql: """
                    INSERT INTO circle_placement_bounds(
                        circleID, minX, maxX, minY, maxY
                    ) VALUES (?, ?, ?, ?, ?)
                    """)
                let searchStatement = try database.makeStatement(sql: """
                    INSERT INTO circle_search(
                        circleID, day, mapID, blockID, spaceNumber, subspace,
                        circleName, circleKana, penName, description
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)

                for circle in sourceCircles {
                    try placementStatement.execute(arguments: [
                        circle.circleID,
                        circle.day,
                        circle.mapID,
                        circle.blockID,
                        circle.spaceNumber,
                        circle.subspace,
                    ])
                    try boundsStatement.execute(arguments: [
                        circle.circleID,
                        circle.minX,
                        circle.maxX,
                        circle.minY,
                        circle.maxY,
                    ])
                    try searchStatement.execute(arguments: [
                        circle.circleID,
                        circle.day,
                        circle.mapID,
                        circle.blockID,
                        circle.spaceNumber,
                        circle.subspace,
                        circle.circleName,
                        circle.circleKana,
                        circle.penName,
                        JapaneseSearchNormalizer.searchableText([
                            circle.circleName,
                            circle.circleKana,
                            circle.penName,
                            circle.description,
                        ]),
                    ])
                }
                try database.execute(
                    sql: """
                        INSERT INTO index_metadata(key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [MetadataKey.catalogDigest, catalogDigest]
                )
            }
        }
        preparationTask = task

        do {
            try await task.value
        } catch {
            preparationTask = nil
            throw error
        }
    }

    nonisolated private static func placement(from row: Row) -> CatalogMapCirclePlacement? {
        guard let circleID: Int = row["circleID"],
              let blockID: Int = row["blockID"],
              let spaceNumber: Int = row["spaceNumber"]
        else {
            return nil
        }
        return CatalogMapCirclePlacement(
            circleID: circleID,
            tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
            subspace: row["subspace"] ?? 0
        )
    }
}
