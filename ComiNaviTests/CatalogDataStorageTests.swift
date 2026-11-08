import Foundation
import XCTest

@testable import ComiNavi

final class CatalogDataStorageTests: XCTestCase {
    private var root: URL!
    private var applicationSupportEvent: URL!
    private var cachesEvent: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComiNaviTests-\(UUID().uuidString)", isDirectory: true)
        let shard = EventStorageShard(eventID: 190, comiketID: "104")
        applicationSupportEvent = shard.directory(
            in: root.appendingPathComponent("Application Support/environments/production/events")
        )
        cachesEvent = shard.directory(
            in: root.appendingPathComponent("Caches/environments/production/events")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOldCachesInstallMovesToApplicationSupportAndKeepsFavorites() throws {
        let mainDatabase = Data("SQLite format 3\u{0}main catalog".utf8)
        let imageDatabase = Data("SQLite format 3\u{0}image catalog".utf8)
        let cover = Data([0x89, 0x50, 0x4e, 0x47])
        let checkpoint = Data("resume".utf8)
        try write(mainDatabase, to: cachesEvent, "circlems/databases/main.sqlite")
        try write(imageDatabase, to: cachesEvent, "circlems/databases/image.sqlite")
        try write(cover, to: cachesEvent, "circlems/images/cover.png")
        try write(checkpoint, to: cachesEvent, "circlems/downloads/main-abc.resume-data")

        // Favorites and the user plan already live next to the catalog data in
        // Application Support and must stay exactly as they were.
        let favorites = Data("SQLite format 3\u{0}favorites".utf8)
        try write(favorites, to: applicationSupportEvent, "users/cominavi-abc/user-plan.sqlite")

        let directory = try prepare()

        XCTAssertEqual(directory, applicationSupportEvent.appendingPathComponent("circlems"))
        XCTAssertEqual(try read(directory, "databases/main.sqlite"), mainDatabase)
        XCTAssertEqual(try read(directory, "databases/image.sqlite"), imageDatabase)
        XCTAssertEqual(try read(directory, "images/cover.png"), cover)
        XCTAssertEqual(try read(directory, "downloads/main-abc.resume-data"), checkpoint)
        XCTAssertEqual(
            try read(applicationSupportEvent, "users/cominavi-abc/user-plan.sqlite"),
            favorites
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesEvent.path))

        XCTAssertTrue(try isExcludedFromBackup(directory))
        XCTAssertFalse(try isExcludedFromBackup(applicationSupportEvent.appendingPathComponent("users")))
        XCTAssertFalse(try isExcludedFromBackup(applicationSupportEvent))

        // A second launch finds nothing left to move and changes nothing.
        XCTAssertEqual(try prepare(), directory)
        XCTAssertEqual(try read(directory, "databases/main.sqlite"), mainDatabase)
    }

    func testFilesAlreadyInApplicationSupportWinOverLegacyCopies() throws {
        try write(Data("new".utf8), to: applicationSupportEvent, "circlems/databases/main.sqlite")
        try write(Data("old".utf8), to: cachesEvent, "circlems/databases/main.sqlite")
        try write(Data("old image".utf8), to: cachesEvent, "circlems/databases/image.sqlite")
        try write(Data("other".utf8), to: cachesEvent, "unrelated/keep.txt")

        let directory = try prepare()

        XCTAssertEqual(try read(directory, "databases/main.sqlite"), Data("new".utf8))
        XCTAssertEqual(try read(directory, "databases/image.sqlite"), Data("old image".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cachesEvent.appendingPathComponent("circlems").path
            )
        )
        // Only the catalog scope moves; anything else in the Caches shard stays.
        XCTAssertEqual(try read(cachesEvent, "unrelated/keep.txt"), Data("other".utf8))
    }

    func testFreshInstallCreatesExcludedDirectoryWithoutLegacyData() throws {
        let directory = try prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try isExcludedFromBackup(directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesEvent.path))
    }

    private func prepare() throws -> URL {
        try CatalogDataStorage.prepareScopeDirectory(
            DirectoryManager.CatalogDataScope.circlems.rawValue,
            applicationSupportEventDirectory: applicationSupportEvent,
            legacyCachesEventDirectory: cachesEvent
        )
    }

    private func write(_ data: Data, to directory: URL, _ path: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func read(_ directory: URL, _ path: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(path))
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }
}
