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
/// event's disposable image cache. Offline and demo use still work through the
/// database fallback.
struct CircleDetailArtworkLoader: CircleDetailArtworkLoading, Sendable {
    typealias RemoteImageFetcher = @Sendable (_ publicCircleID: Int) async -> Data?

    private let cacheDirectory: URL
    private let fetchRemoteImage: RemoteImageFetcher

    init(eventID: Int, eventNumber: Int) {
        cacheDirectory = DirectoryManager.shared
            .cachesFor(
                eventID: eventID,
                comiketId: String(eventNumber),
                .circlems,
                .images,
                createIfNeeded: true
            )
            .appendingPathComponent("selected-circles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        fetchRemoteImage = { publicCircleID in
            guard !(await AppData.getUserToken()).isEmpty,
                  let circleResponse = try? await CirclemsAPI.getCircle(wcid: String(publicCircleID)),
                  let url = URL(string: circleResponse.response.cutUrl),
                  url.scheme?.lowercased() == "https",
                  let data = await RemoteImagePipeline.imageData(for: url),
                  Self.pixelArea(of: data) != nil
            else { return nil }
            return data
        }
    }

    init(cacheDirectory: URL, fetchRemoteImage: @escaping RemoteImageFetcher) {
        self.cacheDirectory = cacheDirectory
        self.fetchRemoteImage = fetchRemoteImage
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
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
        let cacheURL = cacheURL(
            publicCircleID: publicCircleID,
            updateID: updateID
        )

        if let cached = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
           Self.isHigherResolution(cached, than: fallback)
        {
            return cached
        }

        guard !Task.isCancelled,
              let remote = await fetchRemoteImage(publicCircleID),
              !Task.isCancelled,
              Self.isHigherResolution(remote, than: fallback)
        else { return fallback }

        try? remote.write(to: cacheURL, options: .atomic)
        return remote
    }

    private func cacheURL(publicCircleID: Int, updateID: Int?) -> URL {
        cacheDirectory.appendingPathComponent(
            "circle-\(publicCircleID)-update-\(updateID ?? 0).image"
        )
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
