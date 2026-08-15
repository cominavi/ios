import CoreGraphics
import ImageIO
import SpriteKit
import UniformTypeIdentifiers
import XCTest

@testable import ComiNavi

@MainActor
final class UnifiedMapArtworkLODTests: XCTestCase {
    func testEncodedArtworkDecodesProductionIntermediateResolution() throws {
        let original = try XCTUnwrap(makeImage(width: 3_200, height: 1_600))
        let encodedData = try encodePNG(original)
        let overview = try XCTUnwrap(
            CatalogMapArtworkRendering.image(
                from: encodedData,
                maximumPixelDimension: 1_536
            )
        )
        let artwork = CatalogMapArtwork.testingEncoded(
            name: "EncodedArtwork",
            pixelSize: CGSize(width: 3_200, height: 1_600),
            image: original,
            data: encodedData,
            overview: overview
        )

        XCTAssertEqual(
            artwork.renderingMaximumPixelDimensions,
            [1_536, 3_072, 3_200]
        )
        XCTAssertNil(
            artwork.precomputedRenderingImage(at: 1),
            "The middle rung must exercise the encoded production source"
        )

        let intermediate = artwork.renderingImage(at: 1)

        XCTAssertEqual(max(intermediate.width, intermediate.height), 3_072)
        XCTAssertEqual(intermediate.width, 3_072)
        XCTAssertEqual(intermediate.height, 1_536)
        XCTAssertLessThan(intermediate.width, original.width)
    }

    func testThreeTierCachePreservesAndReusesOverviewWhileEvictingDetailRungs() async throws {
        let overview = try XCTUnwrap(makeImage(width: 100, height: 50))
        let intermediate = try XCTUnwrap(makeImage(width: 300, height: 150))
        let detail = try XCTUnwrap(makeImage(width: 900, height: 450))
        let renderer = makeRenderer(renderingImages: [overview, intermediate, detail])
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        renderer.reduceMotion = true
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        let overviewTextureIdentifiers = renderer.authoredMapTextureIdentifiers
        XCTAssertEqual(renderer.authoredMapTextureIndices, [0])
        XCTAssertEqual(renderer.authoredMapCachedTextureIndices, [[0]])

        renderer.requestVenue(1)
        renderer.didFinishUpdate()
        try await waitUntil {
            renderer.authoredMapTextureIndices == [2]
                && renderer.authoredMapPendingTextureIndices == [nil]
        }
        XCTAssertEqual(renderer.authoredMapCachedTextureIndices, [[0, 2]])

        try await zoomUntilTextureIndex(
            1,
            zoomScale: 0.9,
            renderer: renderer,
            view: view
        )
        XCTAssertEqual(
            renderer.authoredMapCachedTextureIndices,
            [[0, 1]],
            "Adding the middle rung should evict detail, never overview"
        )

        try await zoomUntilTextureIndex(
            2,
            zoomScale: 1.25,
            renderer: renderer,
            view: view
        )
        XCTAssertEqual(
            renderer.authoredMapCachedTextureIndices,
            [[0, 2]],
            "Reloading detail should evict the middle rung and remain bounded"
        )

        renderer.zoom(
            by: 1 / 200,
            around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )
        renderer.endGesture()
        renderer.didFinishUpdate()
        try await waitUntil {
            renderer.authoredMapTextureIndices == [0]
                && renderer.authoredMapPendingTextureIndices == [nil]
        }

        XCTAssertEqual(renderer.authoredMapTextureIdentifiers, overviewTextureIdentifiers)
        XCTAssertEqual(renderer.authoredMapCachedTextureIndices, [[0, 2]])
        XCTAssertEqual(renderer.authoredMapCachedTextureCounts, [2])
    }

    func testCancelledInFlightPreparationCannotInstallOrCacheItsStaleResult() async throws {
        let overview = try XCTUnwrap(makeImage(width: 100, height: 50))
        let detail = try XCTUnwrap(makeImage(width: 400, height: 200))
        let renderer = makeRenderer(renderingImages: [overview, detail])
        let preparation = SuspendedArtworkPreparation()
        renderer.authoredMapImagePreparationOverride = { artwork, textureIndex in
            await preparation.prepare(artwork: artwork, textureIndex: textureIndex)
        }
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        renderer.reduceMotion = true
        view.presentScene(renderer)
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        let overviewTextureIdentifiers = renderer.authoredMapTextureIdentifiers
        renderer.requestVenue(1)
        renderer.didFinishUpdate()
        try await waitUntil {
            preparation.requestedTextureIndices == [1]
                && renderer.authoredMapPendingTextureIndices == [1]
        }

        renderer.zoom(
            by: 1 / 80,
            around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            in: view
        )
        renderer.endGesture()
        renderer.didFinishUpdate()
        try await waitUntil {
            renderer.authoredMapTextureIndices == [0]
                && renderer.authoredMapPendingTextureIndices == [nil]
        }

        preparation.resume()
        try await waitUntil { preparation.returnedTextureIndices == [1] }
        try await Task.sleep(for: .milliseconds(30))
        renderer.didFinishUpdate()

        XCTAssertEqual(renderer.authoredMapTextureIndices, [0])
        XCTAssertEqual(renderer.authoredMapTextureIdentifiers, overviewTextureIdentifiers)
        XCTAssertEqual(
            renderer.authoredMapCachedTextureIndices,
            [[0]],
            "A cancelled result must not enter the texture cache"
        )
    }

    private func makeRenderer(renderingImages: [CGImage]) -> UnifiedBigSightScene {
        let detail = renderingImages[renderingImages.count - 1]
        let pixelSize = CGSize(width: detail.width, height: detail.height)
        let catalogScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Test Hall",
            size: pixelSize,
            tableSize: CGSize(width: 40, height: 40),
            tables: [],
            artwork: CatalogMapArtwork.testing(
                name: "TestArtworkLOD",
                pixelSize: pixelSize,
                image: detail,
                renderingImages: renderingImages
            )
        )
        let venue = BigSightVenuePlacement(
            kind: .east123,
            scene: catalogScene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: .zero,
            rotation: 0,
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: [1]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )
        return UnifiedBigSightScene(campus: campus)
    }

    private func zoomUntilTextureIndex(
        _ textureIndex: Int,
        zoomScale: CGFloat,
        renderer: UnifiedBigSightScene,
        view: SKView
    ) async throws {
        for _ in 0 ..< 30 {
            renderer.zoom(
                by: zoomScale,
                around: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
                in: view
            )
            renderer.didFinishUpdate()
            try await waitUntil {
                renderer.authoredMapPendingTextureIndices == [nil]
            }
            if renderer.authoredMapTextureIndices == [textureIndex] {
                return
            }
        }
        XCTFail(
            "Texture index did not reach \(textureIndex); got \(renderer.authoredMapTextureIndices)"
        )
    }

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

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private final class SuspendedArtworkPreparation {
    private(set) var requestedTextureIndices: [Int] = []
    private(set) var returnedTextureIndices: [Int] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare(artwork: CatalogMapArtwork, textureIndex: Int) async -> CGImage? {
        requestedTextureIndices.append(textureIndex)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        returnedTextureIndices.append(textureIndex)
        return artwork.renderingImage(at: textureIndex)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
