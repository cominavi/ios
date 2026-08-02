import Foundation
import XCTest
@testable import ComiNavi

final class EventStorageShardTests: XCTestCase {
    func testEventAndComiketIdentifiersBothParticipateInShardPath() {
        let eventsDirectory = URL(fileURLWithPath: "/tmp/cominavi-test/events", isDirectory: true)

        let c108 = EventStorageShard(eventID: 230, comiketID: "108")
        let sameNumberDifferentEvent = EventStorageShard(eventID: 231, comiketID: "108")
        let sameEventDifferentNumber = EventStorageShard(eventID: 230, comiketID: "107")

        XCTAssertEqual(
            c108.directory(in: eventsDirectory).path,
            "/tmp/cominavi-test/events/event-230/comiket-108"
        )
        XCTAssertNotEqual(
            c108.directory(in: eventsDirectory),
            sameNumberDifferentEvent.directory(in: eventsDirectory)
        )
        XCTAssertNotEqual(
            c108.directory(in: eventsDirectory),
            sameEventDifferentNumber.directory(in: eventsDirectory)
        )
    }

    func testLegacyShardMigrationPreservesNestedUserPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComiNaviTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let shard = EventStorageShard(eventID: 190, comiketID: "104")
        let legacyPlan = shard.legacyDirectory(in: eventsDirectory)
            .appendingPathComponent("users/user-42/user-plan.sqlite")
        try FileManager.default.createDirectory(
            at: legacyPlan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedPlan = Data("preserved route plan".utf8)
        try expectedPlan.write(to: legacyPlan)

        let resolvedDirectory = try shard.resolveDirectory(in: eventsDirectory)
        let migratedPlan = resolvedDirectory
            .appendingPathComponent("users/user-42/user-plan.sqlite")

        XCTAssertEqual(resolvedDirectory, shard.directory(in: eventsDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlan.path))
        XCTAssertEqual(try Data(contentsOf: migratedPlan), expectedPlan)
    }

    func testExistingDestinationIsNeverOverwrittenByLegacyMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComiNaviTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let shard = EventStorageShard(eventID: 190, comiketID: "104")
        let legacyDirectory = shard.legacyDirectory(in: eventsDirectory)
        let destinationDirectory = shard.directory(in: eventsDirectory)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacyDirectory.appendingPathComponent("user-plan.sqlite")
        )
        try Data("current".utf8).write(
            to: destinationDirectory.appendingPathComponent("user-plan.sqlite")
        )

        let resolvedDirectory = try shard.resolveDirectory(in: eventsDirectory)

        XCTAssertEqual(resolvedDirectory, destinationDirectory)
        XCTAssertEqual(
            try Data(contentsOf: destinationDirectory.appendingPathComponent("user-plan.sqlite")),
            Data("current".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }
}
