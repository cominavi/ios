import Alamofire
import Foundation

struct CatalogDownloadAttemptError: LocalizedError, @unchecked Sendable {
    let underlyingError: any Error
    let resumeData: Data?
    let isTransient: Bool

    var errorDescription: String? { underlyingError.localizedDescription }
}

protocol CatalogDownloadTransporting: Sendable {
    func download(
        from url: URL,
        resumeData: Data?,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void,
        resumeDataHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> URL
}

struct ResumableCatalogDownload: Sendable {
    static let live = ResumableCatalogDownload(
        transport: AlamofireCatalogDownloadTransport.shared
    )

    private let transport: any CatalogDownloadTransporting
    private let retryDelay: Duration

    init(
        transport: any CatalogDownloadTransporting,
        retryDelay: Duration = .seconds(2)
    ) {
        self.transport = transport
        self.retryDelay = retryDelay
    }

    func download(
        from url: URL,
        checkpointURL: URL,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let checkpoint = CatalogDownloadCheckpoint(url: checkpointURL)
        var didRetryWithoutStoredResumeData = false

        while true {
            try Task.checkCancellation()
            let storedResumeData = checkpoint.load()

            do {
                let downloadedURL = try await transport.download(
                    from: url,
                    resumeData: storedResumeData,
                    progressHandler: progressHandler,
                    resumeDataHandler: { resumeData in
                        checkpoint.save(resumeData)
                    }
                )
                checkpoint.remove()
                return downloadedURL
            } catch is CancellationError {
                // The transport's cancellation callback writes resume data when
                // Foundation can produce it. Keep that checkpoint for next launch.
                throw CancellationError()
            } catch let error as CatalogDownloadAttemptError {
                if let resumeData = error.resumeData {
                    checkpoint.save(resumeData)
                }

                if storedResumeData != nil,
                   !error.isTransient,
                   !didRetryWithoutStoredResumeData
                {
                    // Resume data can become stale when its temporary backing file
                    // is purged or the server representation changes. Retry once
                    // from the current URL instead of trapping the user forever.
                    checkpoint.remove()
                    didRetryWithoutStoredResumeData = true
                    continue
                }

                guard error.isTransient else { throw error }
                try await waitBeforeRetry()
            } catch {
                if storedResumeData != nil, !didRetryWithoutStoredResumeData {
                    checkpoint.remove()
                    didRetryWithoutStoredResumeData = true
                    continue
                }
                throw error
            }
        }
    }

    func discardCheckpoint(at checkpointURL: URL) {
        CatalogDownloadCheckpoint(url: checkpointURL).remove()
    }

    private func waitBeforeRetry() async throws {
        guard retryDelay > .zero else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: retryDelay)
    }
}

private struct CatalogDownloadCheckpoint: Sendable {
    let url: URL

    func load() -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    func save(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Could not persist catalog download resume data: \(error)")
        }
    }

    func remove() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("Could not remove catalog download resume data: \(error)")
        }
    }
}

private final class AlamofireCatalogDownloadTransport: CatalogDownloadTransporting, @unchecked Sendable {
    static let shared = AlamofireCatalogDownloadTransport()

    private let session: Session

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = Session(configuration: configuration)
    }

    func download(
        from url: URL,
        resumeData: Data?,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void,
        resumeDataHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> URL {
        let request = if let resumeData {
            session.download(resumingWith: resumeData)
        } else {
            session.download(url)
        }

        request
            .downloadProgress(queue: .global(qos: .utility)) { progress in
                progressHandler(progress.completedUnitCount, progress.totalUnitCount)
            }
            .validate()

        let task = request.serializingDownloadedFileURL(automaticallyCancelling: false)
        return try await withTaskCancellationHandler {
            do {
                return try await task.value
            } catch {
                if let resumeData = request.resumeData {
                    resumeDataHandler(resumeData)
                }
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw CatalogDownloadAttemptError(
                    underlyingError: error,
                    resumeData: request.resumeData,
                    isTransient: Self.isTransientNetworkFailure(error)
                )
            }
        } onCancel: {
            request.cancel { resumeData in
                if let resumeData {
                    resumeDataHandler(resumeData)
                }
            }
        }
    }

    private static func isTransientNetworkFailure(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return transientURLCodes.contains(urlError.code)
        }
        if let underlyingError = error.asAFError?.underlyingError {
            return isTransientNetworkFailure(underlyingError)
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return transientURLCodes.contains(URLError.Code(rawValue: nsError.code))
    }

    private static let transientURLCodes: Set<URLError.Code> = [
        .backgroundSessionWasDisconnected,
        .callIsActive,
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .timedOut,
    ]
}
