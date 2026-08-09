import CryptoKit
import Foundation
import GRDB
import Gzip
import XCTest
@testable import ComiNavi

@MainActor
final class CirclemsDatabaseInstallationTests: XCTestCase {
    func testInstallerStreamsValidArchiveAndReplacesDestination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.sqlite")
        let archiveURL = directory.appendingPathComponent("catalog.sqlite.gz")
        let temporaryURL = directory.appendingPathComponent("installing.sqlite")
        let destinationURL = directory.appendingPathComponent("catalog.sqlite")

        try createMainDatabase(at: sourceURL, marker: "new")
        try createMainDatabase(at: destinationURL, marker: "old")
        let archiveData = try Data(contentsOf: sourceURL).gzipped()
        try archiveData.write(to: archiveURL)

        try await CirclemsDataSource.installDownloadedDatabase(
            archiveURL: archiveURL,
            temporaryURL: temporaryURL,
            destinationURL: destinationURL,
            expectedDigest: md5HexDigest(of: archiveData),
            type: .main
        )

        var configuration = Configuration()
        configuration.readonly = true
        let installedDatabase = try DatabaseQueue(
            path: destinationURL.path,
            configuration: configuration
        )
        let marker = try await installedDatabase.read { database in
            try String.fetchOne(database, sql: "SELECT marker FROM ComiketInfoWC")
        }

        XCTAssertEqual(marker, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testIntegrityFailureLeavesExistingDatabaseUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("catalog.sqlite.gz")
        let temporaryURL = directory.appendingPathComponent("installing.sqlite")
        let destinationURL = directory.appendingPathComponent("catalog.sqlite")
        let existingData = Data("existing database".utf8)
        try existingData.write(to: destinationURL)
        try Data("unexpected response".utf8).write(to: archiveURL)

        do {
            try await CirclemsDataSource.installDownloadedDatabase(
                archiveURL: archiveURL,
                temporaryURL: temporaryURL,
                destinationURL: destinationURL,
                expectedDigest: String(repeating: "0", count: 32),
                type: .main
            )
            XCTFail("Expected the integrity check to fail")
        } catch let error as CirclemsDatabaseInstallationError {
            XCTAssertEqual(error, .integrityCheckFailed)
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), existingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testValidationFailureLeavesExistingDatabaseUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("catalog.sqlite.gz")
        let temporaryURL = directory.appendingPathComponent("installing.sqlite")
        let destinationURL = directory.appendingPathComponent("catalog.sqlite")
        let existingData = Data("existing database".utf8)
        let invalidDatabaseArchive = try Data("not a database".utf8).gzipped()
        try existingData.write(to: destinationURL)
        try invalidDatabaseArchive.write(to: archiveURL)

        do {
            try await CirclemsDataSource.installDownloadedDatabase(
                archiveURL: archiveURL,
                temporaryURL: temporaryURL,
                destinationURL: destinationURL,
                expectedDigest: md5HexDigest(of: invalidDatabaseArchive),
                type: .main
            )
            XCTFail("Expected database validation to fail")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "CirclemsDataSource")
            XCTAssertEqual(error.code, 5)
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), existingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    private func createMainDatabase(at url: URL, marker: String) throws {
        let database = try DatabaseQueue(path: url.path)
        try database.write { database in
            try database.execute(sql: "CREATE TABLE ComiketInfoWC (marker TEXT NOT NULL)")
            try database.execute(sql: "CREATE TABLE ComiketCircleWC (id INTEGER PRIMARY KEY)")
            try database.execute(
                sql: "INSERT INTO ComiketInfoWC (marker) VALUES (?)",
                arguments: [marker]
            )
        }
    }

    private func md5HexDigest(of data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cominavi-database-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
