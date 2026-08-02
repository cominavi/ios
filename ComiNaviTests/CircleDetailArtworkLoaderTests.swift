import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ComiNavi

final class CircleDetailArtworkLoaderTests: XCTestCase {
    func testHigherResolutionRemoteCutReplacesDatabaseFallbackAndIsCached() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = try makePNG(width: 180, height: 256)
        let remote = try makePNG(width: 600, height: 850)
        let circle = makeCircle(publicCircleID: 42, updateID: 7)
        let loader = CircleDetailArtworkLoader(cacheDirectory: directory) { id in
            XCTAssertEqual(id, 42)
            return remote
        }

        let selected = await loader.bestImageData(for: circle, fallback: fallback)

        XCTAssertEqual(selected, remote)

        let cachedLoader = CircleDetailArtworkLoader(cacheDirectory: directory) { _ in
            XCTFail("A valid versioned cache entry should avoid another request")
            return nil
        }
        let cached = await cachedLoader.bestImageData(for: circle, fallback: fallback)
        XCTAssertEqual(cached, remote)
    }

    func testSmallerRemoteCutDoesNotReplaceDatabaseImage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = try makePNG(width: 211, height: 300)
        let remote = try makePNG(width: 90, height: 128)
        let loader = CircleDetailArtworkLoader(cacheDirectory: directory) { _ in remote }

        let selected = await loader.bestImageData(
            for: makeCircle(publicCircleID: 42, updateID: 7),
            fallback: fallback
        )

        XCTAssertEqual(selected, fallback)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCircleWithoutPublicIDStaysFullyOffline() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = try makePNG(width: 180, height: 256)
        let loader = CircleDetailArtworkLoader(cacheDirectory: directory) { _ in
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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try makePNG(width: 600, height: 850)
        let loader = CircleDetailArtworkLoader(cacheDirectory: directory) { id in
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("circle-detail-artwork-\(UUID().uuidString)", isDirectory: true)
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
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
