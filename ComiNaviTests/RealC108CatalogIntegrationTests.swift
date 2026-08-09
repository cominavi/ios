import ImageIO
import XCTest
@testable import ComiNavi

@MainActor
final class RealC108CatalogIntegrationTests: XCTestCase {
    func testRealC108DatabasesOpenThroughProductionDataSource() async throws {
        let directory = try realCatalogDirectory()
        let mainURL = directory.appendingPathComponent("webcatalog108.db")
        let imageURL = directory.appendingPathComponent("webcatalog108Image1.db")
        try requireFile(mainURL)
        try requireFile(imageURL)

        let dataSource = CirclemsDataSource(configuration: CatalogDataSourceConfiguration(
            eventID: 230,
            eventNumber: 108,
            main: .init(digest: "real-c108-main", origin: .local(mainURL)),
            image: .init(digest: "real-c108-image-1", origin: .local(imageURL)),
            enrichment: nil,
            allowsBookmarkSync: false,
            allowsRemoteMetadata: false
        ))
        try await dataSource.waitUntilReady()

        XCTAssertEqual(dataSource.readiness, .ready)
        XCTAssertEqual(dataSource.comiket.number, 108)
        XCTAssertEqual(dataSource.comiket.days.count, 2)
        XCTAssertFalse(dataSource.comiket.days.flatMap(\.halls).isEmpty)
        XCTAssertNil(dataSource.bookmarkSyncCoordinator)

        let circles = await dataSource.getCircles()
        let extensions = await dataSource.getCircleExtensions()
        XCTAssertEqual(circles.count, 22_854)
        XCTAssertEqual(extensions.count, circles.count)
        XCTAssertEqual(Set(circles.map(\.id)).count, circles.count)

        let oneYearWar = circles.filter { $0.circleName == "一年戦争" }
        XCTAssertEqual(oneYearWar.map(\.id).sorted(), [1, 2])
        let extensionsByCircleID = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })
        let paired = CatalogCirclePairing.groups(
            circles: oneYearWar,
            extensionsByCircleID: extensionsByCircleID
        )
        XCTAssertEqual(paired.count, 1)
        XCTAssertEqual(paired[0].map(\.spaceNoSub), [0, 1])
        XCTAssertEqual(Set(paired[0].compactMap(\.spaceNo)), [1])

        let sample = try XCTUnwrap(circles.first)
        let images = try await dataSource.mapCatalog.circleImages(circleIDs: [sample.id])
        let imageData = try XCTUnwrap(images[sample.id])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 211)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 300)
    }

    private func realCatalogDirectory() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["COMINAVI_C108_REAL_DATABASE_DIR"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(
            "RealC108",
            isDirectory: true
        ),
            FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        throw XCTSkip(
            "Run Scripts/test-real-c108.sh with the directory containing the downloaded C108 databases."
        )
    }

    private func requireFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing real C108 database: \(url.path)")
            throw CocoaError(.fileNoSuchFile)
        }
    }
}
