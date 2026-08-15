import Kingfisher
import UIKit
import XCTest
@testable import ComiNavi

final class RemoteImagePipelineTests: XCTestCase {
    @MainActor
    func testPipelineReadsAnImageAfterOnlyItsDiskCopyRemains() async throws {
        RemoteImagePipeline.configureCache()

        let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).png"))
        let data = makePNG()
        let image = try XCTUnwrap(UIImage(data: data))
        let cache = ImageCache.default
        let key = url.absoluteString

        try await cache.store(image, original: data, forKey: key)
        try await cache.removeImage(forKey: key, fromMemory: true, fromDisk: false)

        XCTAssertEqual(cache.imageCachedType(forKey: key), .disk)
        let loadedData = await RemoteImagePipeline.imageData(for: url)
        XCTAssertNotNil(loadedData.flatMap(UIImage.init(data:)))

        try await cache.removeImage(forKey: key)
    }

    @MainActor
    func testAuthenticatedImageDataUsesTheSameDiskCache() async throws {
        RemoteImagePipeline.configureCache()

        let key = "authenticated:test-avatar-\(UUID().uuidString)"
        let data = makePNG()

        await RemoteImagePipeline.storeImageData(data, forKey: key)
        try await ImageCache.default.removeImage(
            forKey: key,
            fromMemory: true,
            fromDisk: false
        )

        XCTAssertEqual(ImageCache.default.imageCachedType(forKey: key), .disk)
        let loadedData = await RemoteImagePipeline.cachedImageData(forKey: key)
        XCTAssertNotNil(loadedData.flatMap(UIImage.init(data:)))

        try await ImageCache.default.removeImage(forKey: key)
    }

    func testCacheConfigurationPersistsImagesWithinAStorageBound() {
        RemoteImagePipeline.configureCache()

        switch ImageCache.default.diskStorage.config.expiration {
        case .never:
            break
        default:
            XCTFail("Remote images should not expire from disk based on age")
        }
        XCTAssertEqual(
            ImageCache.default.diskStorage.config.sizeLimit,
            UInt(RemoteImagePipeline.diskCacheSizeLimit)
        )
    }

    @MainActor
    private func makePNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }
}
