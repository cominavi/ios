import ImageIO
import Kingfisher
import UIKit

enum RemoteImageCacheCategory: String, CaseIterable, Identifiable {
    case shinagaki
    case circleArtwork
    case profileImages

    var id: String {
        rawValue
    }

    var defaultLimit: RemoteImageCacheLimit {
        switch self {
        case .shinagaki: .megabytes512
        case .circleArtwork: .megabytes256
        case .profileImages: .megabytes128
        }
    }

    /// Kingfisher defaults every custom cache to one quarter of physical RAM.
    /// These category-specific ceilings keep the three caches from competing
    /// for most of the device's memory while disk cache hits remain available.
    var memoryCostLimitBytes: Int {
        let mebibytes: Int = switch self {
        case .shinagaki: 64
        case .circleArtwork: 32
        case .profileImages: 16
        }
        return mebibytes * 1_024 * 1_024
    }

    fileprivate var cacheName: String {
        "cominavi.remote-images.\(rawValue).v1"
    }

    fileprivate var limitDefaultsKey: String {
        "cominavi.remote-image-cache.\(rawValue).limit-megabytes.v1"
    }
}

enum RemoteImageCacheLimit: Int, CaseIterable, Identifiable {
    case megabytes64 = 64
    case megabytes128 = 128
    case megabytes256 = 256
    case megabytes512 = 512
    case gigabyte1 = 1024
    case gigabytes2 = 2048

    var id: Int {
        rawValue
    }

    var bytes: UInt {
        UInt(rawValue) * 1024 * 1024
    }
}

struct RemoteImageCacheStatistics: Equatable {
    let category: RemoteImageCacheCategory
    let diskBytes: UInt
    let limitBytes: UInt
}

enum RemoteImagePipeline {
    private static let originalDataSerializer: DefaultCacheSerializer = {
        var serializer = DefaultCacheSerializer()
        serializer.preferCacheOriginalData = true
        return serializer
    }()

    private static let shinagakiCache = ImageCache(
        name: RemoteImageCacheCategory.shinagaki.cacheName
    )
    private static let circleArtworkCache = ImageCache(
        name: RemoteImageCacheCategory.circleArtwork.cacheName
    )
    private static let profileImagesCache = ImageCache(
        name: RemoteImageCacheCategory.profileImages.cacheName
    )

    static func configureCaches(defaults: UserDefaults = .standard) {
        for category in RemoteImageCacheCategory.allCases {
            let cache = cache(for: category)
            cache.memoryStorage.config.totalCostLimit = category.memoryCostLimitBytes
            cache.diskStorage.config.expiration = .never
            cache.diskStorage.config.sizeLimit = configuredLimit(
                for: category,
                defaults: defaults
            ).bytes
        }
    }

    static func cache(for category: RemoteImageCacheCategory) -> ImageCache {
        switch category {
        case .shinagaki: shinagakiCache
        case .circleArtwork: circleArtworkCache
        case .profileImages: profileImagesCache
        }
    }

    static func configuredLimit(
        for category: RemoteImageCacheCategory,
        defaults: UserDefaults = .standard
    ) -> RemoteImageCacheLimit {
        guard let stored = defaults.object(forKey: category.limitDefaultsKey) as? NSNumber,
              let limit = RemoteImageCacheLimit(rawValue: stored.intValue)
        else { return category.defaultLimit }
        return limit
    }

    @MainActor
    static func setLimit(
        _ limit: RemoteImageCacheLimit,
        for category: RemoteImageCacheCategory,
        defaults: UserDefaults = .standard
    ) async {
        defaults.set(limit.rawValue, forKey: category.limitDefaultsKey)
        let cache = cache(for: category)
        cache.diskStorage.config.sizeLimit = limit.bytes
        await cache.cleanExpiredDiskCache()
    }

    static func image(
        for url: URL,
        category: RemoteImageCacheCategory,
        targetPixelSize: CGSize? = nil,
        downloader: ImageDownloader? = nil
    ) async -> UIImage? {
        await result(
            for: url,
            category: category,
            targetPixelSize: targetPixelSize,
            downloader: downloader
        )?.image
    }

    static func imageData(
        for url: URL,
        category: RemoteImageCacheCategory,
        cacheKey: String? = nil,
        downloader: ImageDownloader? = nil
    ) async -> Data? {
        let resolvedCacheKey = cacheKey ?? url.absoluteString
        if let cachedData = await cachedImageData(
            forKey: resolvedCacheKey,
            category: category
        ) {
            return cachedData
        }

        guard let dataProvider = await result(
            for: url,
            category: category,
            cacheKey: resolvedCacheKey,
            downloader: downloader
        )?.data else { return nil }
        return await Task.detached(priority: .utility) {
            dataProvider()
        }.value
    }

    private static func diskCachedImageData(
        forKey key: String,
        category: RemoteImageCacheCategory
    ) async -> Data? {
        let diskStorage = cache(for: category).diskStorage
        return await Task.detached(priority: .utility) { () -> Data? in
            guard let data = try? diskStorage.value(forKey: key) else { return nil }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
            else {
                try? diskStorage.remove(forKey: key)
                return nil
            }
            return data
        }.value
    }

    static func cachedImageData(
        forKey key: String,
        category: RemoteImageCacheCategory
    ) async -> Data? {
        if let cachedData = await diskCachedImageData(
            forKey: key,
            category: category
        ) {
            return cachedData
        }

        // A memory-only entry can still be the exact image the user sees.
        // Encoding it gives Save/Share a reliable offline fallback without
        // attempting a network refresh.
        guard let image = cache(for: category).retrieveImageInMemoryCache(
            forKey: key
        ) else { return nil }
        return await encodedPNGData(for: image)
    }

    static func storeImageData(
        _ data: Data,
        forKey key: String,
        category: RemoteImageCacheCategory
    ) async {
        guard let image = UIImage(data: data) else { return }
        try? await cache(for: category).store(image, original: data, forKey: key)
    }

    static func authenticatedCacheKey(for url: URL, revision: Int?) -> String {
        "authenticated:\(url.absoluteString)#\(revision.map(String.init) ?? "stable")"
    }

    static func encodedPNGData(for image: UIImage) async -> Data? {
        await Task.detached(priority: .utility) {
            image.pngData()
        }.value
    }

    static func statistics(
        for category: RemoteImageCacheCategory
    ) async throws -> RemoteImageCacheStatistics {
        let cache = cache(for: category)
        return try await RemoteImageCacheStatistics(
            category: category,
            diskBytes: cache.diskStorageSize,
            limitBytes: cache.diskStorage.config.sizeLimit
        )
    }

    static func allStatistics() async throws -> [RemoteImageCacheStatistics] {
        try await withThrowingTaskGroup(of: RemoteImageCacheStatistics.self) { group in
            for category in RemoteImageCacheCategory.allCases {
                group.addTask {
                    try await statistics(for: category)
                }
            }

            var statisticsByCategory: [RemoteImageCacheCategory: RemoteImageCacheStatistics] = [:]
            for try await statistics in group {
                statisticsByCategory[statistics.category] = statistics
            }
            return RemoteImageCacheCategory.allCases.compactMap {
                statisticsByCategory[$0]
            }
        }
    }

    static func clear(_ category: RemoteImageCacheCategory) async {
        let cache = cache(for: category)
        cache.clearMemoryCache()
        await cache.clearDiskCache()
    }

    static func clearAll() async {
        await withTaskGroup(of: Void.self) { group in
            for category in RemoteImageCacheCategory.allCases {
                group.addTask {
                    await clear(category)
                }
            }
        }
    }

    private static func options(
        for category: RemoteImageCacheCategory,
        targetPixelSize: CGSize?,
        downloader: ImageDownloader? = nil
    ) -> KingfisherOptionsInfo {
        let cache = cache(for: category)
        var options: KingfisherOptionsInfo = [
            .targetCache(cache),
            .originalCache(cache),
            .cacheOriginalImage,
            .diskCacheExpiration(.never),
            .waitForCache,
        ]
        if let targetPixelSize {
            options.append(.processor(DownsamplingImageProcessor(size: targetPixelSize)))
        } else {
            // Full-resolution image data remains byte-for-byte exportable.
            // Processed thumbnails keep Kingfisher's normal serializer so a
            // disk hit does not decode and re-encode the original before
            // downsampling it again.
            options.append(.cacheSerializer(originalDataSerializer))
        }
        if let downloader {
            options.append(.downloader(downloader))
        }
        return options
    }

    private static func result(
        for url: URL,
        category: RemoteImageCacheCategory,
        targetPixelSize: CGSize? = nil,
        cacheKey: String? = nil,
        downloader: ImageDownloader? = nil
    ) async -> RetrieveImageResult? {
        let resource = KF.ImageResource(downloadURL: url, cacheKey: cacheKey)
        return try? await KingfisherManager.shared.retrieveImage(
            with: resource,
            options: options(
                for: category,
                targetPixelSize: targetPixelSize,
                downloader: downloader
            )
        )
    }
}
