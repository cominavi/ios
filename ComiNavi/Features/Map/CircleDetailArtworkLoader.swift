import Foundation
import ImageIO

protocol CircleDetailArtworkLoading: Sendable {
    func bestImageData(for circle: CatalogMapCircle, fallback: Data?) async -> Data?
}

/// Loads the best available cut for a selected circle.
///
/// The catalog database is optimized for bulk/offline map rendering. The
/// authenticated circle endpoint can provide a newer web cut at a higher
/// resolution, so selection details prefer that image and retain it in the
/// categorized remote-image cache. Offline and demo use still work through the
/// database fallback.
struct CircleDetailArtworkLoader: CircleDetailArtworkLoading {
    typealias RemoteImageFetcher = @Sendable (
        _ publicCircleID: Int,
        _ updateID: Int?
    ) async -> Data?

    private let fetchRemoteImage: RemoteImageFetcher

    init() {
        fetchRemoteImage = { publicCircleID, updateID in
            let cacheKey = Self.remoteCacheKey(
                publicCircleID: publicCircleID,
                updateID: updateID
            )
            if let cached = await RemoteImagePipeline.cachedImageData(
                forKey: cacheKey,
                category: .circleArtwork
            ) {
                return cached
            }

            guard await !(AppData.getUserToken()).isEmpty,
                  let circleResponse = try? await CirclemsAPI.getCircle(wcid: String(publicCircleID)),
                  let url = URL(string: circleResponse.response.cutUrl),
                  url.scheme?.lowercased() == "https",
                  let data = await RemoteImagePipeline.imageData(
                      for: url,
                      category: .circleArtwork,
                      cacheKey: cacheKey
                  ),
                  Self.pixelArea(of: data) != nil
            else { return nil }
            return data
        }
    }

    init(fetchRemoteImage: @escaping RemoteImageFetcher) {
        self.fetchRemoteImage = fetchRemoteImage
    }

    init(
        fetchRemoteImage: @escaping @Sendable (_ publicCircleID: Int) async -> Data?
    ) {
        self.init { publicCircleID, _ in
            await fetchRemoteImage(publicCircleID)
        }
    }

    func bestImageData(for circle: CatalogMapCircle, fallback: Data?) async -> Data? {
        await bestImageData(
            publicCircleID: circle.publicCircleID,
            updateID: circle.updateID,
            fallback: fallback
        )
    }

    func bestImageData(
        publicCircleID: Int?,
        updateID: Int?,
        fallback: Data?
    ) async -> Data? {
        guard let publicCircleID else { return fallback }
        guard !Task.isCancelled,
              let remote = await fetchRemoteImage(publicCircleID, updateID),
              !Task.isCancelled,
              Self.isHigherResolution(remote, than: fallback)
        else { return fallback }

        return remote
    }

    static func remoteCacheKey(publicCircleID: Int, updateID: Int?) -> String {
        "circle-artwork:\(publicCircleID):update:\(updateID ?? 0)"
    }

    private static func isHigherResolution(_ candidate: Data, than fallback: Data?) -> Bool {
        guard let candidateArea = pixelArea(of: candidate) else { return false }
        guard let fallback, let fallbackArea = pixelArea(of: fallback) else { return true }
        return candidateArea > fallbackArea
    }

    private static func pixelArea(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else { return nil }
        return width * height
    }
}
