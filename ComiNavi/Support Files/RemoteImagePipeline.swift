import Kingfisher
import UIKit

enum RemoteImagePipeline {
    static let diskCacheSizeLimit = 1_024 * 1_024 * 1_024

    private static let options: KingfisherOptionsInfo = [
        .cacheOriginalImage,
        .diskCacheExpiration(.never),
        .waitForCache,
    ]

    static func configureCache() {
        ImageCache.default.diskStorage.config.expiration = .never
        ImageCache.default.diskStorage.config.sizeLimit = UInt(diskCacheSizeLimit)
    }

    static func image(
        for url: URL,
        targetPixelSize: CGSize? = nil
    ) async -> UIImage? {
        await result(for: url, targetPixelSize: targetPixelSize)?.image
    }

    static func imageData(for url: URL) async -> Data? {
        guard let dataProvider = await result(for: url)?.data else { return nil }
        return await Task.detached(priority: .utility) {
            dataProvider()
        }.value
    }

    static func cachedImageData(forKey key: String) async -> Data? {
        guard let image = try? await ImageCache.default.retrieveImage(
            forKey: key,
            options: [.diskCacheExpiration(.never)]
        ).image else { return nil }
        return await encodedPNGData(for: image)
    }

    static func storeImageData(_ data: Data, forKey key: String) async {
        guard let image = UIImage(data: data) else { return }
        try? await ImageCache.default.store(image, original: data, forKey: key)
    }

    static func authenticatedCacheKey(for url: URL, revision: Int?) -> String {
        "authenticated:\(url.absoluteString)#\(revision.map(String.init) ?? "stable")"
    }

    static func encodedPNGData(for image: UIImage) async -> Data? {
        await Task.detached(priority: .utility) {
            image.pngData()
        }.value
    }

    private static func result(
        for url: URL,
        targetPixelSize: CGSize? = nil
    ) async -> RetrieveImageResult? {
        var requestOptions = options
        if let targetPixelSize {
            requestOptions.append(.processor(DownsamplingImageProcessor(size: targetPixelSize)))
        }

        return try? await KingfisherManager.shared.retrieveImage(
            with: url,
            options: requestOptions
        )
    }
}
