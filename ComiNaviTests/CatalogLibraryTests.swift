import Foundation
import GRDB
import UIKit
import XCTest
@testable import ComiNavi

@MainActor
final class CatalogLibraryTests: XCTestCase {
    func testDirectCirclemsHeadersRejectMissingAccessTokenBeforeNetworking() throws {
        for accessToken in ["", " ", "\n\t"] {
            XCTAssertThrowsError(
                try CirclemsAPI.authenticatedHeaders(accessToken: accessToken)
            ) { error in
                XCTAssertEqual(
                    error as? CirclemsAPIAuthorizationError,
                    .accessTokenRequired
                )
            }
        }

        let headers = try CirclemsAPI.authenticatedHeaders(accessToken: "  provider-token  ")
        XCTAssertEqual(headers["Authorization"], "Bearer provider-token")
    }

    func testMissingDirectCirclemsTokenFallsBackToBackendCatalog() async throws {
        let circlemsRecorder = CatalogSourceInvocationRecorder()
        let cominaviRecorder = CatalogSourceInvocationRecorder()
        let sources: [CatalogDataMode: any CatalogSource] = [
            .circlems: CatalogSourceStub(
                mode: .circlems,
                behavior: .missingAccessToken,
                recorder: circlemsRecorder
            ),
            .cominavi: CatalogSourceStub(
                mode: .cominavi,
                behavior: .events([.init(id: 230, number: 108)]),
                recorder: cominaviRecorder
            ),
        ]
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            CatalogDataMode.circlems.rawValue,
            forKey: "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)"
        )
        let library = CatalogLibrary(
            sources: sources,
            defaults: defaults,
            initialMode: .circlems
        )

        library.start()
        try await waitForFailure(in: library)

        XCTAssertEqual(library.mode, .cominavi)
        XCTAssertEqual(
            defaults.string(forKey: "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)"),
            CatalogDataMode.cominavi.rawValue
        )
        let circlemsAvailableEventsCallCount = await circlemsRecorder.availableEventsCallCount
        let cominaviAvailableEventsCallCount = await cominaviRecorder.availableEventsCallCount
        let cominaviConfigurationEventIDs = await cominaviRecorder.configurationEventIDs
        XCTAssertEqual(circlemsAvailableEventsCallCount, 1)
        XCTAssertEqual(cominaviAvailableEventsCallCount, 1)
        XCTAssertEqual(cominaviConfigurationEventIDs, [230])
    }

    func testAuthenticatedUserWithoutCatalogKeepsIndependentAppDestinationsAvailable() {
        XCTAssertEqual(
            EntryContentRoute.resolve(
                accountDeletionPending: false,
                shouldShowSignIn: false,
                hasCatalog: false
            ),
            .catalogIndependent
        )
        XCTAssertEqual(
            EntryContentRoute.resolve(
                accountDeletionPending: false,
                shouldShowSignIn: false,
                hasCatalog: true
            ),
            .catalog
        )
    }

    func testReadinessProgressesClampInvalidTotalsAndOverflow() {
        let empty = Readiness.Progress(
            type: .main,
            totalBytes: 0,
            completedBytes: 0
        )
        let completedWithoutTotal = Readiness.Progress(
            type: .image,
            totalBytes: 0,
            completedBytes: 1
        )
        let overflowing = Readiness.Progress(
            type: .main,
            totalBytes: 100,
            completedBytes: 200
        )
        let half = Readiness.Progress(
            type: .image,
            totalBytes: 100,
            completedBytes: 50
        )

        XCTAssertEqual(empty.fractionCompleted, 0)
        XCTAssertEqual(completedWithoutTotal.fractionCompleted, 1)
        XCTAssertEqual(overflowing.fractionCompleted, 1)
        XCTAssertEqual(
            [empty, half].fractionCompleted,
            0.5
        )
    }

    func testStartRequestsPersistedSupportedEvent() async throws {
        let response = eventListResponse(
            events: [
                .init(eventID: 190, eventNumber: 104),
                .init(eventID: 230, eventNumber: 108),
            ],
            latestEventID: 230,
            latestEventNumber: 108
        )
        let service = CatalogServiceStub(eventListResponse: response)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            190,
            forKey: "CatalogLibrary.selectedEventID.\(AppEnvironment.current.storageNamespace).circlems"
        )
        let library = CatalogLibrary(
            service: service,
            defaults: defaults,
            initialMode: .circlems
        )

        library.start()
        try await waitForFailure(in: library)

        let requestedEventIDs = await service.requestedEventIDs
        XCTAssertEqual(requestedEventIDs, [190])
        XCTAssertEqual(library.events.map(\.number), [108, 104])
        XCTAssertNil(library.dataSource)
    }

    func testFutureOnlyEventListFailsWithoutRequestingMetadata() async throws {
        let response = eventListResponse(
            events: [.init(eventID: 240, eventNumber: 109)],
            latestEventID: 230,
            latestEventNumber: 108
        )
        let service = CatalogServiceStub(eventListResponse: response)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = CatalogLibrary(
            service: service,
            defaults: defaults,
            initialMode: .circlems
        )

        library.start()
        try await waitForFailure(in: library)

        let requestedEventIDs = await service.requestedEventIDs
        XCTAssertTrue(requestedEventIDs.isEmpty)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(
            library.errorMessage,
            "Circle.ms did not return any currently viewable Comiket catalogs."
        )
    }

    func testCirclemsSourceUsesBundledCrawlDataAsOptionalEnrichment() async throws {
        let service = CatalogServiceStub(
            eventListResponse: eventListResponse(
                events: [.init(eventID: 230, eventNumber: 108)],
                latestEventID: 230,
                latestEventNumber: 108
            ),
            catalogBaseResponse: .init(
                response: .init(
                    url: .init(
                        textdbSqlite3UrlSsl: "https://example.com/main.sqlite",
                        imagedb1UrlSsl: "https://example.com/images.sqlite"
                    ),
                    md5: .init(
                        textdbSqlite3UrlSsl: "main-digest",
                        imagedb1UrlSsl: "image-digest"
                    ),
                    updatedate: "2026-07-27"
                ),
                status: "success"
            )
        )

        let configuration = try await CirclemsCatalogSource(service: service).configuration(
            for: .init(id: 230, number: 108)
        )

        let enrichment = try XCTUnwrap(configuration.enrichment)
        XCTAssertEqual(enrichment.resourceURL.lastPathComponent, "crawl-c108-shinagaki.json")
        XCTAssertFalse(enrichment.isRequired)
        XCTAssertTrue(configuration.allowsBookmarkSync)
        XCTAssertTrue(configuration.allowsRemoteMetadata)

        let index = try CatalogEnrichmentIndex(
            data: Data(contentsOf: enrichment.resourceURL)
        )
        // The bundled archive grows whenever the crawler publishes a newer snapshot.
        // Guard against accidental truncation without pinning the test to one crawl run.
        XCTAssertGreaterThanOrEqual(index.selectedPostCount, 1_699)
        XCTAssertGreaterThanOrEqual(index.mappedPostCount, 1_483)
        XCTAssertEqual(
            index.enrichment(circleID: 8_880, publicCircleID: 23_012_210)?
                .primaryPost?.id,
            "2070092138935660893"
        )
    }

    #if DEBUG || COMINAVI_STAGING
    func testDemoSourceReturnsDirectLocalDatabaseConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cominavi-demo-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("demo-c104-main.sqlite")
        let imageURL = directory.appendingPathComponent("demo-c104-images.sqlite")
        try Data().write(to: mainURL)
        try Data().write(to: imageURL)

        let source = DemoCatalogSource(resourceDirectory: directory)
        let events = try await source.availableEvents()
        let configuration = try await source.configuration(for: try XCTUnwrap(events.first))

        XCTAssertEqual(events, [.init(id: 190, number: 104)])
        XCTAssertEqual(configuration.main.origin, .local(mainURL))
        XCTAssertEqual(configuration.image.origin, .local(imageURL))
        XCTAssertFalse(configuration.allowsBookmarkSync)
    }

    func testDemoModeCannotBeSelectedWhenItWasNotExplicitlyEnabledForAutomation() {
        let service = CatalogServiceStub(
            eventListResponse: eventListResponse(
                events: [.init(eventID: 190, eventNumber: 104)],
                latestEventID: 190,
                latestEventNumber: 104
            )
        )
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = CatalogLibrary(service: service, defaults: defaults, initialMode: .circlems)

        library.selectMode(.demo)

        XCTAssertEqual(library.mode, .circlems)
        XCTAssertEqual(library.phase, .idle)
        XCTAssertNil(library.dataSource)
        XCTAssertNil(
            defaults.string(forKey: "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)")
        )
    }

    func testBundledDemoCatalogOpensThroughCatalogDataSource() async throws {
        try? DirectoryManager.shared.removeCachesFor(
            eventID: DemoCatalogSource.c104.id,
            comiketId: String(DemoCatalogSource.c104.number)
        )
        let configuration = try await DemoCatalogSource().configuration(for: DemoCatalogSource.c104)
        let dataSource = CirclemsDataSource(configuration: configuration)

        for _ in 0 ..< 300 {
            if dataSource.readiness == .ready { break }
            if case .error(let message) = dataSource.readiness {
                XCTFail("Demo catalog failed to open: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let circles = await dataSource.getCircles()
        let mapCatalog = try XCTUnwrap(dataSource.mapCatalog as? SQLiteMapCatalog)
        XCTAssertTrue(mapCatalog.mainDatabase is DatabaseQueue)
        XCTAssertTrue(mapCatalog.imageDatabase is DatabaseQueue)
        let imageIDs = try await mapCatalog.imageDatabase.read { database in
            Set(
                try Int.fetchAll(
                    database,
                    sql: "SELECT id FROM ComiketCircleImage WHERE cutImage IS NOT NULL"
                )
            )
        }
        XCTAssertFalse(circles.isEmpty)
        XCTAssertTrue(
            circles.allSatisfy { imageIDs.contains($0.id) },
            "Every circle in the bundled demo catalog must include its circle-cut image."
        )
        for circle in [circles.first, circles.dropFirst(circles.count / 2).first, circles.last]
            .compactMap({ $0 })
        {
            let imageData = await dataSource.getCircleImage(circleId: circle.id)
            let data = try XCTUnwrap(imageData)
            XCTAssertNotNil(
                UIImage(data: data),
                "Demo circle \(circle.id) must contain decodable image data."
            )
        }
        let day = try XCTUnwrap(dataSource.comiket.days.first)
        let hall = try XCTUnwrap(day.halls.first)
        let scene = try await dataSource.mapCatalog.scene(
            day: day.dayIndex,
            mapID: hall.externalMapId
        )
        let genrePlacements = try await dataSource.mapCatalog.genrePlacements(
            day: day.dayIndex,
            mapID: hall.externalMapId
        )
        let tableIDs = Set(scene.tables.map(\.id))
        XCTAssertFalse(genrePlacements.isEmpty)
        XCTAssertTrue(genrePlacements.allSatisfy { tableIDs.contains($0.tableID) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    _ = try await dataSource.mapCatalog.scene(
                        day: day.dayIndex,
                        mapID: hall.externalMapId
                    )
                }
            }
            try await group.waitForAll()
        }
        _ = try await dataSource.mapCatalog.circlePlacements(
            in: CatalogMapViewport(
                sceneID: scene.id,
                mapRect: CGRect(origin: .zero, size: scene.size),
                renderedScale: CatalogMapViewport.circleArtworkThreshold
            )
        )

        XCTAssertEqual(dataSource.readiness, .ready)
        XCTAssertEqual(dataSource.comiket.number, 104)
        XCTAssertEqual(circles.count, 23_857)
        XCTAssertNil(dataSource.bookmarkSyncCoordinator)
    }

    func testNonProductionBuildIncludesCominaviWithDebugCatalogModes() {
        let library = CatalogLibrary(initialMode: .circlems)

        XCTAssertEqual(
            Set(library.availableModes),
            [.cominavi, .circlems]
        )
    }

    func testSwitchingCatalogKeepsReadyDataSourceVisibleUntilReplacementIsReady() async throws {
        let baseConfiguration = try await DemoCatalogSource().configuration(
            for: DemoCatalogSource.c104
        )
        let firstEvent = DemoCatalogSource.c104
        let secondEvent = CatalogEvent(id: 191, number: 105)
        let source = MultiEventDemoCatalogSource(
            events: [firstEvent, secondEvent],
            baseConfiguration: baseConfiguration
        )
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = CatalogLibrary(
            sources: [.demo: source],
            defaults: defaults,
            initialMode: .demo
        )

        library.start()
        try await waitForReady(in: library)
        let originalDataSource = try XCTUnwrap(library.dataSource)

        library.select(secondEvent)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while library.phase != .ready, clock.now < deadline {
            if let visibleDataSource = library.dataSource {
                XCTAssertTrue(
                    visibleDataSource === originalDataSource || visibleDataSource.readiness == .ready,
                    "A partially prepared catalog replaced the currently rendered catalog"
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(library.phase, .ready)
        XCTAssertEqual(library.selectedEvent, secondEvent)
        XCTAssertEqual(library.dataSource?.readiness, .ready)
        XCTAssertFalse(library.dataSource === originalDataSource)
    }
    #endif

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "net.cominavi.tests.catalog-library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func eventListResponse(
        events: [CirclemsAPI.EventListResponseData.Event],
        latestEventID: Int,
        latestEventNumber: Int
    ) -> CirclemsAPI.EventListResponse {
        .init(
            response: .init(
                list: events,
                latestEventID: latestEventID,
                latestEventNumber: latestEventNumber
            ),
            status: "success"
        )
    }

    private func waitForFailure(in library: CatalogLibrary) async throws {
        for _ in 0 ..< 100 {
            if case .failed = library.phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Catalog library did not enter its expected failure state.")
    }

    private func waitForReady(in library: CatalogLibrary) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while library.phase != .ready || library.dataSource?.readiness != .ready,
              clock.now < deadline
        {
            if case .failed(let message) = library.phase {
                XCTFail("Catalog library failed to open: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.phase, .ready)
        XCTAssertEqual(library.dataSource?.readiness, .ready)
    }
}

#if DEBUG || COMINAVI_STAGING
private struct MultiEventDemoCatalogSource: CatalogSource {
    let mode = CatalogDataMode.demo
    let events: [CatalogEvent]
    let baseConfiguration: CatalogDataSourceConfiguration

    func availableEvents() async throws -> [CatalogEvent] {
        events
    }

    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        CatalogDataSourceConfiguration(
            eventID: event.id,
            eventNumber: event.number,
            main: baseConfiguration.main,
            image: baseConfiguration.image,
            allowsBookmarkSync: false
        )
    }
}
#endif

private actor CatalogServiceStub: CatalogEventServicing {
    let eventListResponse: CirclemsAPI.EventListResponse
    let catalogBaseResponse: CirclemsAPI.CatalogBaseResponse?
    private(set) var requestedEventIDs: [Int] = []

    init(
        eventListResponse: CirclemsAPI.EventListResponse,
        catalogBaseResponse: CirclemsAPI.CatalogBaseResponse? = nil
    ) {
        self.eventListResponse = eventListResponse
        self.catalogBaseResponse = catalogBaseResponse
    }

    func eventList() async throws -> CirclemsAPI.EventListResponse {
        eventListResponse
    }

    func catalogBase(eventID: Int) async throws -> CirclemsAPI.CatalogBaseResponse {
        requestedEventIDs.append(eventID)
        if let catalogBaseResponse {
            return catalogBaseResponse
        }
        throw CatalogServiceStubError.metadataUnavailable
    }
}

private enum CatalogServiceStubError: LocalizedError {
    case metadataUnavailable

    var errorDescription: String? { "Fixture metadata is intentionally unavailable." }
}

private actor CatalogSourceInvocationRecorder {
    private(set) var availableEventsCallCount = 0
    private(set) var configurationEventIDs: [Int] = []

    func recordAvailableEventsCall() {
        availableEventsCallCount += 1
    }

    func recordConfiguration(eventID: Int) {
        configurationEventIDs.append(eventID)
    }
}

private struct CatalogSourceStub: CatalogSource {
    enum Behavior: Sendable {
        case missingAccessToken
        case events([CatalogEvent])
    }

    let mode: CatalogDataMode
    let behavior: Behavior
    let recorder: CatalogSourceInvocationRecorder

    func availableEvents() async throws -> [CatalogEvent] {
        await recorder.recordAvailableEventsCall()
        switch behavior {
        case .missingAccessToken:
            throw CirclemsAPIAuthorizationError.accessTokenRequired
        case .events(let events):
            return events
        }
    }

    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        await recorder.recordConfiguration(eventID: event.id)
        throw CatalogServiceStubError.metadataUnavailable
    }
}
