import Foundation
import GRDB
import XCTest

@testable import ComiNavi

final class UserPlanStoreTests: XCTestCase {
    func testSQLiteStorePublishesBookmarkMutations() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteUserPlanStore(path: databaseURL.path)
        let updates = await store.bookmarkUpdates(eventNumber: 108)
        var iterator = updates.makeAsyncIterator()
        let initialRevision = await iterator.next()
        XCTAssertEqual(initialRevision, 0)

        try await store.upsert(MapBookmark(
            eventNumber: 108,
            publicCircleID: 100,
            catalogCircleID: 200,
            updateID: 300,
            day: 1,
            mapID: 4,
            tableID: .init(blockID: 5, spaceNumber: 6),
            subspace: 0,
            color: .orange,
            memo: "",
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            syncState: .pendingUpsert
        ))

        let updatedRevision = await iterator.next()
        XCTAssertEqual(updatedRevision, 1)
    }

    func testCurrentStoreRetiresLegacyRouteOrderingWithoutLosingFavorites() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteUserPlanStore(path: databaseURL.path)
        let favorite = MapBookmark(
            eventNumber: 108,
            publicCircleID: 100,
            catalogCircleID: 200,
            updateID: 300,
            day: 1,
            mapID: 4,
            tableID: .init(blockID: 5, spaceNumber: 6),
            subspace: 0,
            color: .orange,
            memo: "Bring cash",
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            syncState: .synced
        )
        try await store.upsert(favorite)

        let database = try DatabaseQueue(path: databaseURL.path)
        let schema = try await database.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(bookmark)")
                .compactMap { $0["name"] as String? }
            let indexes = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
            )
            return (columns, indexes)
        }

        XCTAssertFalse(schema.0.contains("routeOrder"))
        XCTAssertFalse(schema.1.contains("bookmark_route"))
        let storedFavorite = try await store.bookmark(eventNumber: 108, publicCircleID: 100)
        XCTAssertEqual(storedFavorite, favorite)
    }
}
