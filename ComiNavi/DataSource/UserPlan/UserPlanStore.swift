import Foundation
import GRDB

enum BookmarkColor: Int, CaseIterable, Codable, Identifiable, Sendable {
    case memoOnly = 0
    case orange
    case magenta
    case yellow
    case green
    case cyan
    case purple
    case blue
    case lime
    case red

    var id: Int { rawValue }

    static var selectableColors: [BookmarkColor] {
        allCases.filter { $0 != .memoOnly }
    }
}

enum BookmarkSyncState: String, Codable, Sendable {
    case synced
    case pendingUpsert
    case pendingDelete
}

struct MapBookmark: Identifiable, Equatable, Sendable {
    var id: Int { publicCircleID }

    let eventNumber: Int
    let publicCircleID: Int
    let catalogCircleID: Int
    let updateID: Int?
    let day: Int
    let mapID: Int
    let tableID: CatalogMapTable.ID
    let subspace: Int
    var color: BookmarkColor
    var memo: String
    var routeOrder: Int?
    var modifiedAt: Date
    var syncState: BookmarkSyncState
}

protocol UserPlanStoring: Sendable {
    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark]
    func allBookmarks(eventNumber: Int) async throws -> [MapBookmark]
    func pendingChanges(eventNumber: Int) async throws -> [MapBookmark]
    func upsert(_ bookmark: MapBookmark) async throws
    func upsert(_ bookmarks: [MapBookmark]) async throws
    func remove(eventNumber: Int, publicCircleID: Int) async throws
}

actor SQLiteUserPlanStore: UserPlanStoring {
    private let database: DatabasePool

    init(path: String) throws {
        database = try DatabasePool(path: path)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("create-user-plan") { database in
            try database.create(table: BookmarkRecord.databaseTableName) { table in
                table.column("eventNumber", .integer).notNull()
                table.column("publicCircleID", .integer).notNull()
                table.column("catalogCircleID", .integer).notNull()
                table.column("updateID", .integer)
                table.column("day", .integer).notNull()
                table.column("mapID", .integer).notNull()
                table.column("blockID", .integer).notNull()
                table.column("spaceNumber", .integer).notNull()
                table.column("subspace", .integer).notNull()
                table.column("color", .integer).notNull()
                table.column("memo", .text).notNull().defaults(to: "")
                table.column("routeOrder", .integer)
                table.column("modifiedAt", .datetime).notNull()
                table.column("syncState", .text).notNull()
                table.primaryKey(["eventNumber", "publicCircleID"])
            }
            try database.create(
                index: "bookmark_map",
                on: BookmarkRecord.databaseTableName,
                columns: ["eventNumber", "day", "mapID"]
            )
            try database.create(
                index: "bookmark_route",
                on: BookmarkRecord.databaseTableName,
                columns: ["eventNumber", "routeOrder"]
            )
        }
        try migrator.migrate(database)
    }

    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark] {
        try await database.read { database in
            try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("day") == day)
                .filter(Column("mapID") == mapID)
                .filter(Column("syncState") != BookmarkSyncState.pendingDelete.rawValue)
                .order(Column("routeOrder"), Column("modifiedAt"))
                .fetchAll(database)
                .compactMap(\.bookmark)
        }
    }

    func upsert(_ bookmark: MapBookmark) async throws {
        try await database.write { database in
            try BookmarkRecord(bookmark).save(database)
        }
    }

    func upsert(_ bookmarks: [MapBookmark]) async throws {
        try await database.write { database in
            for bookmark in bookmarks {
                try BookmarkRecord(bookmark).save(database)
            }
        }
    }

    func pendingChanges(eventNumber: Int) async throws -> [MapBookmark] {
        try await database.read { database in
            try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("syncState") != BookmarkSyncState.synced.rawValue)
                .order(Column("modifiedAt"))
                .fetchAll(database)
                .compactMap(\.bookmark)
        }
    }

    func allBookmarks(eventNumber: Int) async throws -> [MapBookmark] {
        try await database.read { database in
            try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .fetchAll(database)
                .compactMap(\.bookmark)
        }
    }

    func remove(eventNumber: Int, publicCircleID: Int) async throws {
        try await database.write { database in
            _ = try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("publicCircleID") == publicCircleID)
                .deleteAll(database)
        }
    }
}

private struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bookmark"

    let eventNumber: Int
    let publicCircleID: Int
    let catalogCircleID: Int
    let updateID: Int?
    let day: Int
    let mapID: Int
    let blockID: Int
    let spaceNumber: Int
    let subspace: Int
    let color: Int
    let memo: String
    let routeOrder: Int?
    let modifiedAt: Date
    let syncState: String

    init(_ bookmark: MapBookmark) {
        eventNumber = bookmark.eventNumber
        publicCircleID = bookmark.publicCircleID
        catalogCircleID = bookmark.catalogCircleID
        updateID = bookmark.updateID
        day = bookmark.day
        mapID = bookmark.mapID
        blockID = bookmark.tableID.blockID
        spaceNumber = bookmark.tableID.spaceNumber
        subspace = bookmark.subspace
        color = bookmark.color.rawValue
        memo = bookmark.memo
        routeOrder = bookmark.routeOrder
        modifiedAt = bookmark.modifiedAt
        syncState = bookmark.syncState.rawValue
    }

    var bookmark: MapBookmark? {
        guard let color = BookmarkColor(rawValue: color),
              let syncState = BookmarkSyncState(rawValue: syncState)
        else {
            return nil
        }
        return MapBookmark(
            eventNumber: eventNumber,
            publicCircleID: publicCircleID,
            catalogCircleID: catalogCircleID,
            updateID: updateID,
            day: day,
            mapID: mapID,
            tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
            subspace: subspace,
            color: color,
            memo: memo,
            routeOrder: routeOrder,
            modifiedAt: modifiedAt,
            syncState: syncState
        )
    }
}

actor InMemoryUserPlanStore: UserPlanStoring {
    private var storedBookmarks: [Int: MapBookmark] = [:]

    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark] {
        storedBookmarks.values
            .filter { $0.eventNumber == eventNumber && $0.day == day && $0.mapID == mapID }
            .sorted { ($0.routeOrder ?? .max) < ($1.routeOrder ?? .max) }
    }

    func upsert(_ bookmark: MapBookmark) async throws {
        storedBookmarks[bookmark.publicCircleID] = bookmark
    }

    func upsert(_ bookmarks: [MapBookmark]) async throws {
        for bookmark in bookmarks {
            storedBookmarks[bookmark.publicCircleID] = bookmark
        }
    }

    func allBookmarks(eventNumber: Int) async throws -> [MapBookmark] {
        storedBookmarks.values.filter { $0.eventNumber == eventNumber }
    }

    func pendingChanges(eventNumber: Int) async throws -> [MapBookmark] {
        storedBookmarks.values
            .filter { $0.eventNumber == eventNumber && $0.syncState != .synced }
            .sorted { $0.modifiedAt < $1.modifiedAt }
    }

    func remove(eventNumber: Int, publicCircleID: Int) async throws {
        storedBookmarks[publicCircleID] = nil
    }
}
