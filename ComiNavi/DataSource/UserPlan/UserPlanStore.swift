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
    // Retained only so databases and sync payloads written by older builds remain readable.
    var modifiedAt: Date
    var syncState: BookmarkSyncState
}

struct FollowingImportState: Equatable, Sendable {
    let eventNumber: Int
    let twitterUserName: String
    let importedAt: Date
    let nextAllowedAt: Date
    let followingCount: Int
    let matchedCircleCount: Int
}

struct ImportedCircleSource: Equatable, Hashable, Sendable {
    let eventNumber: Int
    let publicCircleID: Int
    let twitterUserID: String
    let twitterUserName: String
    let twitterDisplayName: String
    let profilePictureURL: URL?
    let firstImportedAt: Date
    let lastSeenAt: Date
}

protocol UserPlanStoring: Sendable {
    func bookmark(eventNumber: Int, publicCircleID: Int) async throws -> MapBookmark?
    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark]
    func allBookmarks(eventNumber: Int) async throws -> [MapBookmark]
    func pendingChanges(eventNumber: Int) async throws -> [MapBookmark]
    func upsert(_ bookmark: MapBookmark) async throws
    func upsert(_ bookmarks: [MapBookmark]) async throws
    func remove(eventNumber: Int, publicCircleID: Int) async throws
    func followingImportState(eventNumber: Int) async throws -> FollowingImportState?
    func importedCircleSources(eventNumber: Int) async throws -> [ImportedCircleSource]
    func mergeFollowingImport(
        state: FollowingImportState,
        sources: [ImportedCircleSource]
    ) async throws
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
        migrator.registerMigration("create-following-import-cache") { database in
            try database.create(table: FollowingImportStateRecord.databaseTableName) { table in
                table.column("eventNumber", .integer).primaryKey()
                table.column("twitterUserName", .text).notNull()
                table.column("importedAt", .datetime).notNull()
                table.column("nextAllowedAt", .datetime).notNull()
                table.column("followingCount", .integer).notNull()
                table.column("matchedCircleCount", .integer).notNull()
            }
            try database.create(table: ImportedCircleSourceRecord.databaseTableName) { table in
                table.column("eventNumber", .integer).notNull()
                table.column("publicCircleID", .integer).notNull()
                table.column("twitterUserID", .text).notNull()
                table.column("twitterUserName", .text).notNull()
                table.column("twitterDisplayName", .text).notNull()
                table.column("profilePictureURL", .text)
                table.column("firstImportedAt", .datetime).notNull()
                table.column("lastSeenAt", .datetime).notNull()
                table.primaryKey(["eventNumber", "publicCircleID", "twitterUserID"])
            }
            try database.create(
                index: "imported_circle_event",
                on: ImportedCircleSourceRecord.databaseTableName,
                columns: ["eventNumber", "publicCircleID"]
            )
        }
        migrator.registerMigration("retire-route-order") { database in
            try database.execute(sql: "DROP INDEX IF EXISTS bookmark_route")
            try database.execute(sql: "ALTER TABLE bookmark DROP COLUMN routeOrder")
        }
        try migrator.migrate(database)
    }

    func bookmark(eventNumber: Int, publicCircleID: Int) async throws -> MapBookmark? {
        try await database.read { database in
            try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("publicCircleID") == publicCircleID)
                .fetchOne(database)?
                .bookmark
        }
    }

    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark] {
        try await database.read { database in
            try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("day") == day)
                .filter(Column("mapID") == mapID)
                .filter(Column("syncState") != BookmarkSyncState.pendingDelete.rawValue)
                .order(Column("modifiedAt"))
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
            _ =
                try BookmarkRecord
                .filter(Column("eventNumber") == eventNumber)
                .filter(Column("publicCircleID") == publicCircleID)
                .deleteAll(database)
        }
    }

    func followingImportState(eventNumber: Int) async throws -> FollowingImportState? {
        try await database.read { database in
            try FollowingImportStateRecord.fetchOne(database, key: eventNumber)?.state
        }
    }

    func importedCircleSources(eventNumber: Int) async throws -> [ImportedCircleSource] {
        try await database.read { database in
            try ImportedCircleSourceRecord
                .filter(Column("eventNumber") == eventNumber)
                .order(Column("publicCircleID"), Column("twitterUserName").collating(.nocase))
                .fetchAll(database)
                .compactMap(\.source)
        }
    }

    func mergeFollowingImport(
        state: FollowingImportState,
        sources: [ImportedCircleSource]
    ) async throws {
        try await database.write { database in
            try FollowingImportStateRecord(state).save(database)
            for source in sources where source.eventNumber == state.eventNumber {
                let key: [String: DatabaseValueConvertible] = [
                    "eventNumber": source.eventNumber,
                    "publicCircleID": source.publicCircleID,
                    "twitterUserID": source.twitterUserID,
                ]
                let firstImportedAt =
                    try ImportedCircleSourceRecord
                    .fetchOne(database, key: key)?
                    .firstImportedAt ?? source.firstImportedAt
                try ImportedCircleSourceRecord(
                    source,
                    firstImportedAt: firstImportedAt
                ).save(database)
            }
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
            modifiedAt: modifiedAt,
            syncState: syncState
        )
    }
}

private struct FollowingImportStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "followingImportState"

    let eventNumber: Int
    let twitterUserName: String
    let importedAt: Date
    let nextAllowedAt: Date
    let followingCount: Int
    let matchedCircleCount: Int

    init(_ state: FollowingImportState) {
        eventNumber = state.eventNumber
        twitterUserName = state.twitterUserName
        importedAt = state.importedAt
        nextAllowedAt = state.nextAllowedAt
        followingCount = state.followingCount
        matchedCircleCount = state.matchedCircleCount
    }

    var state: FollowingImportState {
        FollowingImportState(
            eventNumber: eventNumber,
            twitterUserName: twitterUserName,
            importedAt: importedAt,
            nextAllowedAt: nextAllowedAt,
            followingCount: followingCount,
            matchedCircleCount: matchedCircleCount
        )
    }
}

private struct ImportedCircleSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedCircleSource"

    let eventNumber: Int
    let publicCircleID: Int
    let twitterUserID: String
    let twitterUserName: String
    let twitterDisplayName: String
    let profilePictureURL: String?
    let firstImportedAt: Date
    let lastSeenAt: Date

    init(_ source: ImportedCircleSource, firstImportedAt: Date? = nil) {
        eventNumber = source.eventNumber
        publicCircleID = source.publicCircleID
        twitterUserID = source.twitterUserID
        twitterUserName = source.twitterUserName
        twitterDisplayName = source.twitterDisplayName
        profilePictureURL = source.profilePictureURL?.absoluteString
        self.firstImportedAt = firstImportedAt ?? source.firstImportedAt
        lastSeenAt = source.lastSeenAt
    }

    var source: ImportedCircleSource? {
        let profileURL = profilePictureURL.flatMap(URL.init(string:))
        guard profilePictureURL == nil || profileURL != nil else { return nil }
        return ImportedCircleSource(
            eventNumber: eventNumber,
            publicCircleID: publicCircleID,
            twitterUserID: twitterUserID,
            twitterUserName: twitterUserName,
            twitterDisplayName: twitterDisplayName,
            profilePictureURL: profileURL,
            firstImportedAt: firstImportedAt,
            lastSeenAt: lastSeenAt
        )
    }
}

actor InMemoryUserPlanStore: UserPlanStoring {
    private var storedBookmarks: [Int: MapBookmark] = [:]
    private var followingStates: [Int: FollowingImportState] = [:]
    private var importedSources: [ImportedSourceKey: ImportedCircleSource] = [:]

    func bookmark(eventNumber: Int, publicCircleID: Int) async throws -> MapBookmark? {
        guard let bookmark = storedBookmarks[publicCircleID],
            bookmark.eventNumber == eventNumber
        else { return nil }
        return bookmark
    }

    func bookmarks(eventNumber: Int, day: Int, mapID: Int) async throws -> [MapBookmark] {
        storedBookmarks.values
            .filter { $0.eventNumber == eventNumber && $0.day == day && $0.mapID == mapID }
            .sorted { $0.modifiedAt < $1.modifiedAt }
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

    func followingImportState(eventNumber: Int) async throws -> FollowingImportState? {
        followingStates[eventNumber]
    }

    func importedCircleSources(eventNumber: Int) async throws -> [ImportedCircleSource] {
        importedSources.values
            .filter { $0.eventNumber == eventNumber }
            .sorted {
                ($0.publicCircleID, $0.twitterUserName.lowercased())
                    < ($1.publicCircleID, $1.twitterUserName.lowercased())
            }
    }

    func mergeFollowingImport(
        state: FollowingImportState,
        sources: [ImportedCircleSource]
    ) async throws {
        followingStates[state.eventNumber] = state
        for source in sources where source.eventNumber == state.eventNumber {
            let key = ImportedSourceKey(source: source)
            let firstImportedAt = importedSources[key]?.firstImportedAt ?? source.firstImportedAt
            importedSources[key] = ImportedCircleSource(
                eventNumber: source.eventNumber,
                publicCircleID: source.publicCircleID,
                twitterUserID: source.twitterUserID,
                twitterUserName: source.twitterUserName,
                twitterDisplayName: source.twitterDisplayName,
                profilePictureURL: source.profilePictureURL,
                firstImportedAt: firstImportedAt,
                lastSeenAt: source.lastSeenAt
            )
        }
    }
}

private struct ImportedSourceKey: Hashable {
    let eventNumber: Int
    let publicCircleID: Int
    let twitterUserID: String

    init(source: ImportedCircleSource) {
        eventNumber = source.eventNumber
        publicCircleID = source.publicCircleID
        twitterUserID = source.twitterUserID
    }
}
