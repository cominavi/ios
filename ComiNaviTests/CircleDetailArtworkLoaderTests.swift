@testable import ComiNavi
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class CircleDetailArtworkLoaderTests: XCTestCase {
    @MainActor
    func testSelectedRemoteCutPromotesMapArtworkCache() async throws {
        let remote = try makePNG(width: 600, height: 850)
        let catalog = FixtureMapCatalog()
        let model = MapScreenModel(
            days: [
                UFDSchema.Day(
                    id: "selected-artwork-test",
                    dayIndex: 1,
                    date: DateComponents(year: 2026, month: 8, day: 15),
                    halls: [
                        UFDSchema.DayHall(
                            id: "selected-artwork-hall",
                            name: "Fixture Hall",
                            mapName: "FIXTURE",
                            externalMapId: 1,
                            externalCorrespondingFloorId: 1,
                            areas: []
                        ),
                    ]
                ),
            ],
            eventNumber: 108,
            selectedMapID: 1,
            initialScope: .venue,
            catalog: catalog,
            detailArtworkLoader: StubCircleDetailArtworkLoader(data: remote),
            userPlanStore: InMemoryUserPlanStore()
        )
        model.load()
        try await waitUntil { model.phase == .ready }
        let scene = try XCTUnwrap(model.scene)
        let table = try XCTUnwrap(scene.tables.first)
        let circleID = table.id.blockID * 100 + table.id.spaceNumber * 2
        model.updateViewport(CatalogMapViewport(
            sceneID: scene.id,
            mapRect: CGRect(origin: .zero, size: scene.size),
            renderedScale: CatalogMapViewport.circleArtworkThreshold
        ))
        try await waitUntil { model.visibleCircleArtwork[circleID] != nil }
        XCTAssertEqual(model.visibleCircleArtwork[circleID]?.width, 1)

        model.select(table: table, preferredSubspace: 0)
        try await waitUntil { model.visibleCircleArtwork[circleID]?.width == 600 }

        XCTAssertEqual(model.visibleCircleArtwork[circleID]?.height, 850)
        XCTAssertEqual(model.selection?.selectedCircleID, circleID)
    }

    func testHigherResolutionRemoteCutReplacesDatabaseFallback() async throws {
        let fallback = try makePNG(width: 180, height: 256)
        let remote = try makePNG(width: 600, height: 850)
        let circle = makeCircle(publicCircleID: 42, updateID: 7)
        let loader = CircleDetailArtworkLoader { id in
            XCTAssertEqual(id, 42)
            return remote
        }

        let selected = await loader.bestImageData(for: circle, fallback: fallback)

        XCTAssertEqual(selected, remote)
    }

    func testSmallerRemoteCutDoesNotReplaceDatabaseImage() async throws {
        let fallback = try makePNG(width: 211, height: 300)
        let remote = try makePNG(width: 90, height: 128)
        let loader = CircleDetailArtworkLoader { _ in remote }

        let selected = await loader.bestImageData(
            for: makeCircle(publicCircleID: 42, updateID: 7),
            fallback: fallback
        )

        XCTAssertEqual(selected, fallback)
    }

    func testCircleWithoutPublicIDStaysFullyOffline() async throws {
        let fallback = try makePNG(width: 180, height: 256)
        let loader = CircleDetailArtworkLoader { _ in
            XCTFail("A private catalog circle cannot be requested from the API")
            return nil
        }

        let selected = await loader.bestImageData(
            for: makeCircle(publicCircleID: nil, updateID: nil),
            fallback: fallback
        )

        XCTAssertEqual(selected, fallback)
    }

    func testIdentifierBasedLookupLoadsArtworkForExploreCards() async throws {
        let remote = try makePNG(width: 600, height: 850)
        let loader = CircleDetailArtworkLoader { id in
            XCTAssertEqual(id, 42)
            return remote
        }

        let selected = await loader.bestImageData(
            publicCircleID: 42,
            updateID: 7,
            fallback: nil
        )

        XCTAssertEqual(selected, remote)
    }

    func testRemoteCacheKeyChangesWithCircleRevision() {
        XCTAssertNotEqual(
            CircleDetailArtworkLoader.remoteCacheKey(publicCircleID: 42, updateID: 7),
            CircleDetailArtworkLoader.remoteCacheKey(publicCircleID: 42, updateID: 8)
        )
    }

    private func makeCircle(publicCircleID: Int?, updateID: Int?) -> CatalogMapCircle {
        CatalogMapCircle(
            id: 1,
            publicCircleID: publicCircleID,
            updateID: updateID,
            subspace: 0,
            circleName: "Test Circle",
            penName: "Tester",
            description: "",
            genreName: nil,
            circlemsURL: nil
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private struct StubCircleDetailArtworkLoader: CircleDetailArtworkLoading {
    let data: Data

    func bestImageData(for _: CatalogMapCircle, fallback _: Data?) async -> Data? {
        data
    }
}
