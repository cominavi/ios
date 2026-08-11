import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import ComiNavi

final class CominaviCatalogTests: XCTestCase {
    func testRemovingDownloadedDataDeletesOnlyTheCatalogRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let catalogRoot = root.appendingPathComponent("CominaviCatalogs", isDirectory: true)
        let sibling = root.appendingPathComponent("keep.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: catalogRoot.appendingPathComponent("events/c108", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("partial catalog".utf8).write(
            to: catalogRoot.appendingPathComponent("events/c108/catalog.partial")
        )
        try Data("keep".utf8).write(to: sibling)

        try await CominaviCatalogInstaller.removeAllDownloadedData(
            rootDirectory: catalogRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testCanonicalCatalogFixtureDecodesLiterallyAndFreezesCompatibilitySmokeQuery() throws {
        struct Fixture: Decodable {
            struct Smoke: Decodable {
                struct Row: Decodable {
                    let comiketNo: Int
                    let id: Int
                    let WCId: Int
                    let circleName: String
                    let circlems: String?
                    let CirclemsPortalURL: String?
                }

                let query: String
                let row: Row
            }

            let catalogList: CominaviCatalogIndexResponse
            let catalogVersion: CominaviCatalog
            let compatibilitySmoke: Smoke
        }

        let data = try fixtureData()
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let listItem = try XCTUnwrap(fixture.catalogList.items.first)

        XCTAssertEqual(listItem, fixture.catalogVersion)
        XCTAssertNoThrow(try listItem.validated())
        XCTAssertEqual(
            listItem.artifact.url,
            "/api/v2/catalogs/108/versions/c108-v1-aaaaaaaaaaaaaaaaaaaaaaaa/artifact"
        )
        XCTAssertEqual(fixture.compatibilitySmoke.row.comiketNo, 108)
        XCTAssertEqual(fixture.compatibilitySmoke.row.id, 9_001)
        XCTAssertEqual(fixture.compatibilitySmoke.row.WCId, 9_001)
        XCTAssertEqual(fixture.compatibilitySmoke.row.circleName, "Fixture Circle")
        XCTAssertNil(fixture.compatibilitySmoke.row.circlems)
        XCTAssertNil(fixture.compatibilitySmoke.row.CirclemsPortalURL)
        XCTAssertTrue(fixture.compatibilitySmoke.query.contains("ComiketCircleImage"))
    }

    func testRangeResumeRefreshesAuthorizationAndInstallsOneRawDatabaseForBothReaders() async throws {
        let root = try temporaryDirectory(named: "range-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeCatalogDatabase(in: root, versionID: "c108-range-v1")
        let authorizer = CatalogAuthorizerStub()
        let transport = CatalogTransportStub(
            artifact: try Data(contentsOf: fixture.databaseURL),
            catalog: fixture.catalog,
            steps: [.automatic, .status(401), .automatic, .automatic, .automatic]
        )
        let installer = CominaviCatalogInstaller(
            authorizer: authorizer,
            transport: transport,
            rootDirectory: root.appendingPathComponent("installed"),
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )

        let installed = try await installer.install(
            fixture.catalog,
            publicUserID: "0123456789abcdef0123456789abcdef",
            progress: nil
        )

        XCTAssertTrue(installed.isCurrentVersion)
        XCTAssertNoThrow(
            try CirclemsDataSource.validateDatabase(at: installed.url, type: .main)
        )
        XCTAssertNoThrow(
            try CirclemsDataSource.validateDatabase(at: installed.url, type: .image)
        )
        let invalidatedTokens = await authorizer.invalidatedTokens()
        XCTAssertEqual(invalidatedTokens, ["catalog-token-1"])
        let requests = await transport.requests()
        XCTAssertGreaterThan(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer catalog-token-")
                == true
        })
        XCTAssertTrue(requests.dropFirst().contains {
            $0.value(forHTTPHeaderField: "If-Range") == fixture.catalog.expectedETag
        })

        let source = CominaviCatalogSource(
            service: CatalogServiceStub(catalog: fixture.catalog),
            installer: InstalledCatalogStub(installed: installed),
            publicUserIDProvider: { "0123456789abcdef0123456789abcdef" }
        )
        _ = try await source.availableEvents()
        let configuration = try await source.configuration(
            for: CatalogEvent(id: 108, number: 108)
        )
        XCTAssertEqual(configuration.main.origin, .local(installed.url))
        XCTAssertEqual(configuration.image.origin, .local(installed.url))
        XCTAssertEqual(configuration.accountPublicUserID, "0123456789abcdef0123456789abcdef")
        XCTAssertFalse(configuration.allowsCirclemsFavoriteMirror)
        XCTAssertFalse(configuration.allowsRemoteMetadata)
    }

    func testCancellationPreservesCheckpointAndRelaunchContinuesAtDurableRangeBoundary() async throws {
        let root = try temporaryDirectory(named: "cancel-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeCatalogDatabase(in: root, versionID: "c108-resume-v1")
        let firstAuthorizer = CatalogAuthorizerStub()
        let firstTransport = CatalogTransportStub(
            artifact: try Data(contentsOf: fixture.databaseURL),
            catalog: fixture.catalog,
            steps: [.automatic, .cancel]
        )
        let installRoot = root.appendingPathComponent("installed")
        let firstInstaller = CominaviCatalogInstaller(
            authorizer: firstAuthorizer,
            transport: firstTransport,
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )

        do {
            _ = try await firstInstaller.install(
                fixture.catalog,
                publicUserID: "account-a",
                progress: nil
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected. The first complete range and checkpoint remain durable.
        }

        let secondTransport = CatalogTransportStub(
            artifact: try Data(contentsOf: fixture.databaseURL),
            catalog: fixture.catalog
        )
        let secondInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: secondTransport,
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let installed = try await secondInstaller.install(
            fixture.catalog,
            publicUserID: "account-a",
            progress: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.url.path))
        let resumedRequests = await secondTransport.requests()
        let resumedRequest = try XCTUnwrap(resumedRequests.first)
        XCTAssertEqual(resumedRequest.value(forHTTPHeaderField: "Range"), "bytes=65536-131071")
        XCTAssertEqual(
            resumedRequest.value(forHTTPHeaderField: "If-Range"),
            fixture.catalog.expectedETag
        )
    }

    func test200And416AreHandledWithoutBlessingTheWrongRepresentation() async throws {
        let root = try temporaryDirectory(named: "statuses")
        defer { try? FileManager.default.removeItem(at: root) }
        let fullFixture = try makeCatalogDatabase(in: root, versionID: "c108-full-v1")
        let fullTransport = CatalogTransportStub(
            artifact: try Data(contentsOf: fullFixture.databaseURL),
            catalog: fullFixture.catalog,
            steps: [.status(200)]
        )
        let fullInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: fullTransport,
            rootDirectory: root.appendingPathComponent("full"),
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let full = try await fullInstaller.install(
            fullFixture.catalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertTrue(full.isCurrentVersion)

        let rangeFixture = try makeCatalogDatabase(in: root, versionID: "c108-416-v1")
        let rangeTransport = CatalogTransportStub(
            artifact: try Data(contentsOf: rangeFixture.databaseURL),
            catalog: rangeFixture.catalog,
            steps: [.status(416), .automatic, .automatic, .automatic]
        )
        let rangeInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: rangeTransport,
            rootDirectory: root.appendingPathComponent("range"),
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let ranged = try await rangeInstaller.install(
            rangeFixture.catalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertTrue(ranged.isCurrentVersion)
        let headRequestCount = await rangeTransport.headRequestCount()
        XCTAssertEqual(headRequestCount, 1)
    }

    func testDigestMismatchAnd304KeepThePreviouslyInstalledVersionAtomically() async throws {
        let root = try temporaryDirectory(named: "fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("installed")
        let firstFixture = try makeCatalogDatabase(in: root, versionID: "c108-old-v1")
        let firstInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: try Data(contentsOf: firstFixture.databaseURL),
                catalog: firstFixture.catalog
            ),
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let first = try await firstInstaller.install(
            firstFixture.catalog,
            publicUserID: "account-a",
            progress: nil
        )

        let nextFixture = try makeCatalogDatabase(in: root, versionID: "c108-new-v1")
        let wrongDigestCatalog = replacingDigest(
            in: nextFixture.catalog,
            with: String(repeating: "f", count: 64)
        )
        let mismatchInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: try Data(contentsOf: nextFixture.databaseURL),
                catalog: wrongDigestCatalog
            ),
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let fallback = try await mismatchInstaller.install(
            wrongDigestCatalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertFalse(fallback.isCurrentVersion)
        XCTAssertEqual(fallback.url, first.url)
        XCTAssertEqual(fallback.catalog.versionID, firstFixture.catalog.versionID)

        let notModifiedInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: try Data(contentsOf: nextFixture.databaseURL),
                catalog: nextFixture.catalog,
                steps: [.status(304)]
            ),
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let notModifiedFallback = try await notModifiedInstaller.install(
            nextFixture.catalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertFalse(notModifiedFallback.isCurrentVersion)
        XCTAssertEqual(notModifiedFallback.url, first.url)
    }

    func testCatalogIsGloballyDeduplicatedWhileUserPlansUseProviderNeutralPublicUserID() async throws {
        let root = try temporaryDirectory(named: "accounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeCatalogDatabase(in: root, versionID: "c108-account-v1")

        func install(for userID: String) async throws -> CominaviInstalledCatalog {
            let installer = CominaviCatalogInstaller(
                authorizer: CatalogAuthorizerStub(),
                transport: CatalogTransportStub(
                    artifact: try Data(contentsOf: fixture.databaseURL),
                    catalog: fixture.catalog
                ),
                rootDirectory: root.appendingPathComponent("installed"),
                chunkBytes: 64 * 1_024,
                retryDelay: .zero
            )
            return try await installer.install(
                fixture.catalog,
                publicUserID: userID,
                progress: nil
            )
        }

        let accountA = try await install(for: "google-public-user-a")
        let accountB = try await install(for: "circle-public-user-b")
        XCTAssertEqual(accountA.url, accountB.url)
        XCTAssertFalse(accountA.url.path.contains("google-public-user-a"))
        XCTAssertFalse(accountB.url.path.contains("circle-public-user-b"))

        let planA = try DirectoryManager.accountDirectoryName(
            publicUserID: "google-public-user-a"
        )
        let planB = try DirectoryManager.accountDirectoryName(
            publicUserID: "circle-public-user-b"
        )
        XCTAssertNotEqual(planA, planB)
        XCTAssertFalse(planA.contains("google-public-user-a"))
        XCTAssertFalse(planB.contains("circle-public-user-b"))
    }

    func testInvalidCompletedPartialAndCorruptCurrentAreRedownloadedAndStorageIsBounded() async throws {
        let root = try temporaryDirectory(named: "repair-gc")
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("installed")
        let old = try makeCatalogDatabase(in: root, versionID: "c108-old-repair-v1")
        let oldInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: try Data(contentsOf: old.databaseURL),
                catalog: old.catalog
            ),
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        _ = try await oldInstaller.install(old.catalog, publicUserID: "account-a", progress: nil)

        let current = try makeCatalogDatabase(in: root, versionID: "c108-current-repair-v1")
        let validBytes = try Data(contentsOf: current.databaseURL)
        let badInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: Data(repeating: 0x7f, count: validBytes.count),
                catalog: current.catalog
            ),
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let fallback = try await badInstaller.install(
            current.catalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertEqual(fallback.catalog.versionID, old.catalog.versionID)
        XCTAssertFalse(fallback.isCurrentVersion)

        let repairTransport = CatalogTransportStub(artifact: validBytes, catalog: current.catalog)
        let repairInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: repairTransport,
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let repaired = try await repairInstaller.install(
            current.catalog,
            publicUserID: "account-b",
            progress: nil
        )
        XCTAssertTrue(repaired.isCurrentVersion)
        let repairRequests = await repairTransport.requests()
        XCTAssertFalse(repairRequests.isEmpty)

        var corruptBytes = try Data(contentsOf: repaired.url)
        corruptBytes[0] ^= 0xff
        try corruptBytes.write(to: repaired.url)
        let corruptRepairTransport = CatalogTransportStub(
            artifact: validBytes,
            catalog: current.catalog
        )
        let corruptRepairInstaller = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: corruptRepairTransport,
            rootDirectory: installRoot,
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let repairedAgain = try await corruptRepairInstaller.install(
            current.catalog,
            publicUserID: "account-a",
            progress: nil
        )
        XCTAssertTrue(repairedAgain.isCurrentVersion)
        let corruptRepairRequests = await corruptRepairTransport.requests()
        XCTAssertFalse(corruptRepairRequests.isEmpty)

        let eventDirectory = repaired.url.deletingLastPathComponent()
        let installedFiles = try FileManager.default.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("catalog-") && $0.pathExtension == "sqlite" }
        XCTAssertLessThanOrEqual(installedFiles.count, 2)
        let downloads = eventDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let downloadFiles = (try? FileManager.default.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertLessThanOrEqual(downloadFiles.count, 2)
    }

    func testRetryBudgetsBoundPersistentGET500AndGETOrHEAD401() async throws {
        let root = try temporaryDirectory(named: "retry-budgets")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeCatalogDatabase(in: root, versionID: "c108-budget-v1")
        let bytes = try Data(contentsOf: fixture.databaseURL)

        func attempt(
            name: String,
            steps: [CatalogTransportStub.Step]
        ) async -> (CatalogTransportStub, CatalogAuthorizerStub) {
            let transport = CatalogTransportStub(
                artifact: bytes,
                catalog: fixture.catalog,
                steps: steps
            )
            let authorizer = CatalogAuthorizerStub()
            let installer = CominaviCatalogInstaller(
                authorizer: authorizer,
                transport: transport,
                rootDirectory: root.appendingPathComponent(name),
                chunkBytes: 64 * 1_024,
                retryDelay: .zero
            )
            do {
                _ = try await installer.install(
                    fixture.catalog,
                    publicUserID: "account-a",
                    progress: nil
                )
                XCTFail("Expected bounded terminal response for \(name)")
            } catch {
                // Expected: no prior installed receipt exists for fallback.
            }
            return (transport, authorizer)
        }

        let (serverTransport, _) = await attempt(
            name: "server",
            steps: Array(repeating: .status(500), count: 8)
        )
        let serverRequests = await serverTransport.requests()
        XCTAssertEqual(serverRequests.count, 6)

        let (getAuthTransport, getAuthorizer) = await attempt(
            name: "get-auth",
            steps: [.status(401), .status(401), .automatic]
        )
        let getAuthRequests = await getAuthTransport.requests()
        let getInvalidations = await getAuthorizer.invalidatedTokens()
        XCTAssertEqual(getAuthRequests.count, 2)
        XCTAssertEqual(getInvalidations.count, 1)

        let (headAuthTransport, headAuthorizer) = await attempt(
            name: "head-auth",
            steps: [.status(416), .status(401), .status(416), .status(401), .automatic]
        )
        let headAuthRequests = await headAuthTransport.requests()
        let headInvalidations = await headAuthorizer.invalidatedTokens()
        XCTAssertEqual(headAuthRequests.count, 4)
        XCTAssertEqual(headInvalidations.count, 1)
    }

    func testColdLaunchOfflineDiscoversValidatedInstalledReceiptOnlyForBoundIdentity() async throws {
        let root = try temporaryDirectory(named: "offline-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeCatalogDatabase(in: root, versionID: "c108-offline-v1")
        let installer = CominaviCatalogInstaller(
            authorizer: CatalogAuthorizerStub(),
            transport: CatalogTransportStub(
                artifact: try Data(contentsOf: fixture.databaseURL),
                catalog: fixture.catalog
            ),
            rootDirectory: root.appendingPathComponent("installed"),
            chunkBytes: 64 * 1_024,
            retryDelay: .zero
        )
        let installed = try await installer.install(
            fixture.catalog,
            publicUserID: "bound-account",
            progress: nil
        )

        let offlineSource = CominaviCatalogSource(
            service: FailingCatalogServiceStub(),
            installer: installer,
            publicUserIDProvider: { "bound-account" }
        )
        let offlineEvents = try await offlineSource.availableEvents()
        XCTAssertEqual(offlineEvents, [CatalogEvent(id: 108, number: 108)])
        let offlineConfiguration = try await offlineSource.configuration(
            for: CatalogEvent(id: 108, number: 108)
        )
        XCTAssertEqual(offlineConfiguration.main.origin, .local(installed.url))

        let unboundSource = CominaviCatalogSource(
            service: FailingCatalogServiceStub(),
            installer: installer,
            publicUserIDProvider: { nil }
        )
        do {
            _ = try await unboundSource.availableEvents()
            XCTFail("An unverified cached profile must not open the offline receipt")
        } catch {
            // Expected.
        }
    }

    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "sanitized-catalog-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "sanitized-catalog-v1", withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cominavi-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCatalogDatabase(
        in directory: URL,
        versionID: String
    ) throws -> (databaseURL: URL, catalog: CominaviCatalog) {
        let url = directory.appendingPathComponent("\(versionID).sqlite")
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: """
                PRAGMA journal_mode = DELETE;
                PRAGMA user_version = 1;
                CREATE TABLE catalog_metadata (
                  singleton INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL,
                  version_id TEXT NOT NULL, comiket_no INTEGER NOT NULL
                );
                CREATE TABLE dates (day INTEGER PRIMARY KEY);
                CREATE TABLE maps (map_id INTEGER PRIMARY KEY);
                CREATE TABLE areas (area_id INTEGER PRIMARY KEY);
                CREATE TABLE blocks (block_id INTEGER PRIMARY KEY);
                CREATE TABLE floors (floor_id INTEGER PRIMARY KEY);
                CREATE TABLE mappings (day INTEGER, block_id INTEGER);
                CREATE TABLE genres (genre_id INTEGER PRIMARY KEY);
                CREATE TABLE layouts (
                  block_id INTEGER, space_no INTEGER, x INTEGER, y INTEGER
                );
                CREATE TABLE circles (
                  wc_id INTEGER PRIMARY KEY, day INTEGER, block_id INTEGER,
                  space_no INTEGER, space_no_sub INTEGER, genre_id INTEGER,
                  name TEXT, update_id INTEGER
                );
                CREATE TABLE circle_images (
                  wc_id INTEGER PRIMARY KEY, byte_count INTEGER, bytes BLOB
                );
                CREATE TABLE common_images (
                  name TEXT PRIMARY KEY, byte_count INTEGER, bytes BLOB
                );
                CREATE VIEW ComiketInfoWC AS
                  SELECT comiket_no AS comiketNo FROM catalog_metadata;
                CREATE VIEW ComiketDateWC AS SELECT 1 AS id;
                CREATE VIEW ComiketMapWC AS SELECT 1 AS id;
                CREATE VIEW ComiketAreaWC AS SELECT 1 AS id;
                CREATE VIEW ComiketBlockWC AS SELECT 1 AS id;
                CREATE VIEW ComiketFloorWC AS SELECT 1 AS id;
                CREATE VIEW ComiketMappingWC AS SELECT 1 AS id;
                CREATE VIEW ComiketGenreWC AS SELECT 1 AS id;
                CREATE VIEW ComiketLayoutWC AS
                  SELECT block_id AS blockId, space_no AS spaceNo,
                         x AS xpos2, y AS ypos2 FROM layouts;
                CREATE VIEW ComiketCircleWC AS
                  SELECT metadata.comiket_no AS comiketNo, circle.wc_id AS id,
                         circle.name AS circleName, circle.block_id AS blockId,
                         circle.space_no AS spaceNo, NULL AS circlems
                  FROM circles AS circle CROSS JOIN catalog_metadata AS metadata;
                CREATE VIEW ComiketCircleExtend AS
                  SELECT wc_id AS id, wc_id AS WCId, NULL AS CirclemsPortalURL FROM circles;
                CREATE VIEW ComiketCircleImage AS
                  SELECT wc_id AS id, wc_id AS WCId, byte_count AS size, bytes AS cutImage
                  FROM circle_images;
                CREATE VIEW ComiketCommonImage AS
                  SELECT name, byte_count AS size, bytes AS image FROM common_images;
                INSERT INTO catalog_metadata VALUES (1, 1, ?, 108);
                INSERT INTO layouts VALUES (1, 1, 100, 200);
                INSERT INTO circles VALUES (9001, 1, 1, 1, 0, 1, 'Fixture Circle', 9001);
                """, arguments: [versionID])
            let largeImage = Data(repeating: 0x5a, count: 180_000)
            try db.execute(
                sql: "INSERT INTO circle_images VALUES (9001, ?, ?)",
                arguments: [largeImage.count, largeImage]
            )
            try db.execute(
                sql: "INSERT INTO common_images VALUES ('0001', 1, ?)",
                arguments: [Data([0x00])]
            )
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let catalog = CominaviCatalog(
            schemaVersion: 1,
            versionID: versionID,
            comiketNo: 108,
            name: "Comic Market 108",
            publishedAt: 103,
            sourceUpdatedAt: 90,
            artifact: .init(
                url: CominaviCatalog.artifactPath(comiketNo: 108, versionID: versionID),
                sha256: digest,
                bytes: Int64(data.count),
                contentType: CominaviCatalog.contentType
            ),
            counts: .init(circles: 1, layouts: 1, images: 2),
            capabilities: .init(
                stableCircleIdentity: "comiketNo+wcID",
                circleImages: true,
                commonImages: true
            )
        )
        return (url, catalog)
    }

    private func replacingDigest(
        in catalog: CominaviCatalog,
        with digest: String
    ) -> CominaviCatalog {
        CominaviCatalog(
            schemaVersion: catalog.schemaVersion,
            versionID: catalog.versionID,
            comiketNo: catalog.comiketNo,
            name: catalog.name,
            publishedAt: catalog.publishedAt,
            sourceUpdatedAt: catalog.sourceUpdatedAt,
            artifact: .init(
                url: catalog.artifact.url,
                sha256: digest,
                bytes: catalog.artifact.bytes,
                contentType: catalog.artifact.contentType
            ),
            counts: catalog.counts,
            capabilities: catalog.capabilities
        )
    }
}

private actor CatalogAuthorizerStub: CominaviCatalogRequestAuthorizing {
    private var tokenGeneration = 1
    private var invalidated: [String] = []

    func authorizedCatalogRequest(
        method: String,
        path: String,
        headers: [String: String],
        invalidatedAccessToken: String?
    ) async throws -> CominaviCatalogAuthorizedRequest {
        if let invalidatedAccessToken {
            invalidated.append(invalidatedAccessToken)
            tokenGeneration += 1
        }
        var request = URLRequest(url: URL(string: "https://cominavi.net\(path)")!)
        request.httpMethod = method
        let token = "catalog-token-\(tokenGeneration)"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return CominaviCatalogAuthorizedRequest(request: request, accessToken: token)
    }

    func invalidatedTokens() -> [String] { invalidated }
}

private actor CatalogTransportStub: CominaviCatalogDownloadTransporting {
    enum Step: Sendable {
        case automatic
        case status(Int)
        case cancel
    }

    private let artifact: Data
    private let catalog: CominaviCatalog
    private var steps: [Step]
    private var recordedRequests: [URLRequest] = []
    private var headRequests = 0

    init(artifact: Data, catalog: CominaviCatalog, steps: [Step] = []) {
        self.artifact = artifact
        self.catalog = catalog
        self.steps = steps
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        recordedRequests.append(request)
        let step = steps.isEmpty ? .automatic : steps.removeFirst()
        if case .cancel = step { throw CancellationError() }
        let status: Int = switch step {
        case .automatic: 206
        case .status(let status): status
        case .cancel: 0
        }

        let range = requestedRange(request) ?? (0, artifact.count - 1)
        let bytes: Data
        switch status {
        case 200:
            bytes = artifact
        case 206:
            bytes = artifact.subdata(in: range.0 ..< min(range.1 + 1, artifact.count))
        default:
            bytes = Data()
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-transport-\(UUID().uuidString)")
        try bytes.write(to: temporaryURL, options: .atomic)
        return (temporaryURL, response(status: status, range: range, bodyBytes: bytes.count))
    }

    func response(for request: URLRequest) async throws -> HTTPURLResponse {
        recordedRequests.append(request)
        headRequests += 1
        let step = steps.isEmpty ? .automatic : steps.removeFirst()
        if case .cancel = step { throw CancellationError() }
        let status: Int = switch step {
        case .automatic: 200
        case .status(let status): status
        case .cancel: 0
        }
        return response(status: status, range: nil, bodyBytes: artifact.count)
    }

    func requests() -> [URLRequest] { recordedRequests }
    func headRequestCount() -> Int { headRequests }

    private func requestedRange(_ request: URLRequest) -> (Int, Int)? {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=")
        else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1])
        else { return nil }
        return (start, end)
    }

    private func response(
        status: Int,
        range: (Int, Int)?,
        bodyBytes: Int
    ) -> HTTPURLResponse {
        var headers: [String: String] = [
            "Accept-Ranges": "bytes",
            "Content-Length": String(bodyBytes),
            "Content-Type": catalog.artifact.contentType,
            "Digest": digestHeader(catalog.artifact.sha256),
            "ETag": catalog.expectedETag,
            "X-Content-Type-Options": "nosniff",
        ]
        if status == 206, let range {
            headers["Content-Range"] = "bytes \(range.0)-\(min(range.1, artifact.count - 1))/\(artifact.count)"
        } else if status == 416 {
            headers["Content-Range"] = "bytes */\(artifact.count)"
        }
        return HTTPURLResponse(
            url: URL(string: "https://cominavi.net\(catalog.artifact.url)")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func digestHeader(_ hex: String) -> String {
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return "sha-256=:\(bytes.base64EncodedString()):"
    }
}

private struct CatalogServiceStub: CominaviCatalogServicing {
    let catalogValue: CominaviCatalog

    init(catalog: CominaviCatalog) {
        catalogValue = catalog
    }

    func catalogs() async throws -> [CominaviCatalog] { [catalogValue] }
    func catalog(comiketNo: Int) async throws -> CominaviCatalog { catalogValue }
}

private struct FailingCatalogServiceStub: CominaviCatalogServicing {
    func catalogs() async throws -> [CominaviCatalog] {
        throw URLError(.notConnectedToInternet)
    }

    func catalog(comiketNo: Int) async throws -> CominaviCatalog {
        throw URLError(.notConnectedToInternet)
    }
}

private struct InstalledCatalogStub: CominaviCatalogInstalling {
    let installed: CominaviInstalledCatalog

    func install(
        _ catalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CominaviInstalledCatalog {
        installed
    }
}
