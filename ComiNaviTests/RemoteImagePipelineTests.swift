@testable import ComiNavi
import Kingfisher
import UIKit
import XCTest

final class RemoteImagePipelineTests: XCTestCase {
    @MainActor
    func testPipelineReadsAnImageAfterOnlyItsDiskCopyRemains() async throws {
        RemoteImagePipeline.configureCaches()

        let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).png"))
        let data = makePNG()
        let image = try XCTUnwrap(UIImage(data: data))
        let cache = RemoteImagePipeline.cache(for: .shinagaki)
        let key = url.absoluteString

        try await cache.store(image, original: data, forKey: key)
        try await cache.removeImage(forKey: key, fromMemory: true, fromDisk: false)

        XCTAssertEqual(cache.imageCachedType(forKey: key), .disk)
        let loadedData = await RemoteImagePipeline.imageData(
            for: url,
            category: .shinagaki
        )
        XCTAssertNotNil(loadedData.flatMap(UIImage.init(data:)))

        try await cache.removeImage(forKey: key)
    }

    @MainActor
    func testAuthenticatedImageDataUsesTheProfileImageCache() async throws {
        RemoteImagePipeline.configureCaches()

        let key = "authenticated:test-avatar-\(UUID().uuidString)"
        let data = makePNG()
        let cache = RemoteImagePipeline.cache(for: .profileImages)

        await RemoteImagePipeline.storeImageData(
            data,
            forKey: key,
            category: .profileImages
        )
        try await cache.removeImage(
            forKey: key,
            fromMemory: true,
            fromDisk: false
        )

        XCTAssertEqual(cache.imageCachedType(forKey: key), .disk)
        let loadedData = await RemoteImagePipeline.cachedImageData(
            forKey: key,
            category: .profileImages
        )
        XCTAssertNotNil(loadedData.flatMap(UIImage.init(data:)))

        try await cache.removeImage(forKey: key)
    }

    @MainActor
    func testClearingOneCategoryKeepsOtherCategoriesCached() async throws {
        RemoteImagePipeline.configureCaches()

        let shinagakiKey = "test-shinagaki-\(UUID().uuidString)"
        let profileKey = "test-profile-\(UUID().uuidString)"
        let data = makePNG()
        let shinagakiCache = RemoteImagePipeline.cache(for: .shinagaki)
        let profileCache = RemoteImagePipeline.cache(for: .profileImages)

        await RemoteImagePipeline.storeImageData(
            data,
            forKey: shinagakiKey,
            category: .shinagaki
        )
        await RemoteImagePipeline.storeImageData(
            data,
            forKey: profileKey,
            category: .profileImages
        )

        await RemoteImagePipeline.clear(.shinagaki)

        XCTAssertEqual(shinagakiCache.imageCachedType(forKey: shinagakiKey), .none)
        XCTAssertNotEqual(profileCache.imageCachedType(forKey: profileKey), .none)

        let statistics = try await RemoteImagePipeline.allStatistics()
        XCTAssertEqual(
            statistics.map(\.category),
            RemoteImageCacheCategory.allCases
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(statistics.first { $0.category == .profileImages }).diskBytes,
            0
        )

        try await profileCache.removeImage(forKey: profileKey)
    }

    @MainActor
    func testCacheLimitsPersistAndApplyByCategory() async throws {
        let suiteName = "RemoteImagePipelineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            RemoteImagePipeline.configureCaches()
        }

        RemoteImagePipeline.configureCaches(defaults: defaults)
        for category in RemoteImageCacheCategory.allCases {
            let cache = RemoteImagePipeline.cache(for: category)
            switch cache.diskStorage.config.expiration {
            case .never:
                break
            default:
                XCTFail("Remote images should not expire from disk based on age")
            }
            XCTAssertEqual(
                cache.diskStorage.config.sizeLimit,
                category.defaultLimit.bytes
            )
        }

        await RemoteImagePipeline.setLimit(
            .megabytes64,
            for: .circleArtwork,
            defaults: defaults
        )

        XCTAssertEqual(
            RemoteImagePipeline.configuredLimit(
                for: .circleArtwork,
                defaults: defaults
            ),
            .megabytes64
        )
        XCTAssertEqual(
            RemoteImagePipeline.cache(for: .circleArtwork).diskStorage.config.sizeLimit,
            RemoteImageCacheLimit.megabytes64.bytes
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
