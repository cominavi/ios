@testable import ComiNavi
import Kingfisher
import UIKit
import XCTest

final class RemoteImagePipelineTests: XCTestCase {
    @MainActor
    func testDisplayedDownloadPreservesExactBytesForOfflineExport() async throws {
        RemoteImagePipeline.configureCaches()

        let url = try XCTUnwrap(
            URL(string: "https://remote-image-pipeline.test/\(UUID().uuidString).png")
        )
        let data = makePNG()
        let cache = RemoteImagePipeline.cache(for: .shinagaki)
        let downloader = ImageDownloader(name: "RemoteImagePipelineTests-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImagePipelineURLProtocol.self]
        downloader.sessionConfiguration = configuration
        RemoteImagePipelineURLProtocol.setResponseData(data, for: url)
        defer {
            RemoteImagePipelineURLProtocol.setResponseData(nil, for: url)
            cache.clearMemoryCache()
        }

        let displayedImage = await RemoteImagePipeline.image(
            for: url,
            category: .shinagaki,
            downloader: downloader
        )
        XCTAssertNotNil(displayedImage)

        RemoteImagePipelineURLProtocol.setResponseData(nil, for: url)
        cache.clearMemoryCache()
        XCTAssertEqual(cache.imageCachedType(forKey: url.absoluteString), .disk)

        let exportedData = await RemoteImagePipeline.imageData(
            for: url,
            category: .shinagaki
        )
        XCTAssertEqual(exportedData, data)

        try await cache.removeImage(forKey: url.absoluteString)
    }

    @MainActor
    func testDownsampledDownloadPreservesOriginalBytesForOfflineExport() async throws {
        RemoteImagePipeline.configureCaches()

        let url = try XCTUnwrap(
            URL(string: "https://remote-image-pipeline.test/\(UUID().uuidString).png")
        )
        let data = makePNG()
        let cache = RemoteImagePipeline.cache(for: .shinagaki)
        let downloader = ImageDownloader(name: "RemoteImagePipelineTests-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImagePipelineURLProtocol.self]
        downloader.sessionConfiguration = configuration
        RemoteImagePipelineURLProtocol.setResponseData(data, for: url)
        defer {
            RemoteImagePipelineURLProtocol.setResponseData(nil, for: url)
            cache.clearMemoryCache()
        }

        let displayedImage = await RemoteImagePipeline.image(
            for: url,
            category: .shinagaki,
            targetPixelSize: CGSize(width: 8, height: 8),
            downloader: downloader
        )
        XCTAssertNotNil(displayedImage)

        RemoteImagePipelineURLProtocol.setResponseData(nil, for: url)
        cache.clearMemoryCache()
        XCTAssertEqual(cache.imageCachedType(forKey: url.absoluteString), .disk)

        let exportedData = await RemoteImagePipeline.imageData(
            for: url,
            category: .shinagaki
        )
        XCTAssertEqual(exportedData, data)

        try await cache.removeImage(forKey: url.absoluteString)
    }

    @MainActor
    func testPipelineReadsAnImageAfterOnlyItsDiskCopyRemains() async throws {
        RemoteImagePipeline.configureCaches()

        let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).png"))
        let data = makePNG()
        let cache = RemoteImagePipeline.cache(for: .shinagaki)
        let key = url.absoluteString

        try await cache.storeToDisk(
            data,
            forKey: key,
            expiration: .never
        )

        XCTAssertEqual(cache.imageCachedType(forKey: key), .disk)
        let loadedData = await RemoteImagePipeline.imageData(
            for: url,
            category: .shinagaki
        )
        XCTAssertEqual(loadedData, data)

        try await cache.removeImage(forKey: key)
    }

    @MainActor
    func testImageDataUsesVisibleMemoryCacheWithoutNetwork() async throws {
        RemoteImagePipeline.configureCaches()

        let url = try XCTUnwrap(
            URL(string: "https://example.invalid/\(UUID().uuidString).jpg")
        )
        let renderedImage = UIGraphicsImageRenderer(
            size: CGSize(width: 17, height: 13)
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 17, height: 13))
        }
        let displayedData = try XCTUnwrap(
            renderedImage.jpegData(compressionQuality: 0.83)
        )
        let image = try XCTUnwrap(UIImage(data: displayedData))
        let cache = RemoteImagePipeline.cache(for: .shinagaki)
        let key = url.absoluteString

        try await cache.store(
            image,
            original: displayedData,
            forKey: key,
            toDisk: false
        )

        XCTAssertEqual(cache.imageCachedType(forKey: key), .memory)
        let loadedData = await RemoteImagePipeline.imageData(
            for: url,
            category: .shinagaki
        )
        XCTAssertNotNil(loadedData.flatMap(UIImage.init(data:)))

        cache.clearMemoryCache()
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

private final class RemoteImagePipelineURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let responseLock = NSLock()
    nonisolated(unsafe) private static var responseDataByURL: [URL: Data] = [:]

    static func setResponseData(_ data: Data?, for url: URL) {
        responseLock.withLock {
            responseDataByURL[url] = data
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "remote-image-pipeline.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.responseLock.withLock({ Self.responseDataByURL[url] }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "image/png"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.notConnectedToInternet)
            )
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
