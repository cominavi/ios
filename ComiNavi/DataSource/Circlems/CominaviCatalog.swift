import CryptoKit
import Darwin
import Foundation
import GRDB

struct CominaviCatalogIndexResponse: Decodable, Sendable {
    let items: [CominaviCatalog]
}

struct CominaviCatalog: Codable, Equatable, Sendable {
    struct Artifact: Codable, Equatable, Sendable {
        let url: String
        let sha256: String
        let bytes: Int64
        let contentType: String
    }

    struct Counts: Codable, Equatable, Sendable {
        let circles: Int
        let layouts: Int
        let images: Int
    }

    struct Capabilities: Codable, Equatable, Sendable {
        let stableCircleIdentity: String
        let circleImages: Bool
        let commonImages: Bool
    }

    let schemaVersion: Int
    let versionID: String
    let comiketNo: Int
    let name: String
    let publishedAt: Int64
    let sourceUpdatedAt: Int64?
    let sourceMainSHA256: String
    let artifact: Artifact
    let counts: Counts
    let capabilities: Capabilities

    var expectedETag: String { "\"sha256-\(artifact.sha256)\"" }

    func validated() throws -> Self {
        guard schemaVersion == 1,
              comiketNo > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isSafeVersionID(versionID),
              Self.isDigest(sourceMainSHA256),
              artifact.sha256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              artifact.bytes > 0,
              artifact.contentType == Self.contentType,
              artifact.url == Self.artifactPath(comiketNo: comiketNo, versionID: versionID),
              counts.circles > 0,
              counts.layouts > 0,
              counts.images > 0,
              capabilities.stableCircleIdentity == "comiketNo+wcID",
              capabilities.circleImages,
              capabilities.commonImages
        else { throw CominaviCatalogError.invalidManifest }
        return self
    }

    static let contentType = "application/vnd.cominavi.catalog-v1+sqlite"

    static func artifactPath(comiketNo: Int, versionID: String) -> String {
        "/api/v2/catalogs/\(comiketNo)/versions/\(versionID)/artifact"
    }

    private static func isSafeVersionID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 160
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

struct CominaviCatalogAuthorizedRequest: Sendable {
    let request: URLRequest
    /// Kept only in memory so a 401 can invalidate exactly the token used by
    /// this attempt. Resume metadata never contains authorization material.
    let accessToken: String
}

protocol CominaviCatalogServicing: Sendable {
    func catalogs() async throws -> [CominaviCatalog]
    func catalog(comiketNo: Int) async throws -> CominaviCatalog
}

protocol CominaviCatalogRequestAuthorizing: Sendable {
    func authorizedCatalogRequest(
        method: String,
        path: String,
        headers: [String: String],
        invalidatedAccessToken: String?
    ) async throws -> CominaviCatalogAuthorizedRequest
}

protocol CominaviCatalogDownloadTransporting: Sendable {
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
    func response(for request: URLRequest) async throws -> HTTPURLResponse
}

struct URLSessionCominaviCatalogDownloadTransport: CominaviCatalogDownloadTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CominaviCatalogError.invalidResponse
        }
        return (url, response)
    }

    func response(for request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CominaviCatalogError.invalidResponse
        }
        return response
    }
}

struct CominaviInstalledCatalog: Equatable, Sendable {
    let catalog: CominaviCatalog
    let url: URL
    let isCurrentVersion: Bool
}

private actor CominaviCatalogManifestCache {
    private var catalogsByComiket: [Int: CominaviCatalog] = [:]

    func replace(with catalogs: [CominaviCatalog]) {
        catalogsByComiket = Dictionary(
            catalogs.map { ($0.comiketNo, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    func catalog(comiketNo: Int) -> CominaviCatalog? {
        catalogsByComiket[comiketNo]
    }

    func store(_ catalog: CominaviCatalog) {
        catalogsByComiket[catalog.comiketNo] = catalog
    }
}

struct CominaviCatalogSource: CatalogSource {
    typealias PublicUserIDProvider = @Sendable () async -> String?

    let mode = CatalogDataMode.cominavi
    private let service: any CominaviCatalogServicing
    private let installer: any CominaviCatalogInstalling
    private let publicUserIDProvider: PublicUserIDProvider
    private let cache = CominaviCatalogManifestCache()

    init(
        service: any CominaviCatalogServicing = CominaviServiceClient.shared,
        installer: (any CominaviCatalogInstalling)? = nil,
        publicUserIDProvider: @escaping PublicUserIDProvider = {
            await MainActor.run {
                guard AppData.profileStore.isIdentityVerified else { return nil }
                return AppData.profileStore.profile?.id
            }
        }
    ) {
        self.service = service
        self.installer = installer ?? CominaviCatalogInstaller(authorizer: CominaviServiceClient.shared)
        self.publicUserIDProvider = publicUserIDProvider
    }

    func availableEvents() async throws -> [CatalogEvent] {
        let catalogs: [CominaviCatalog]
        do {
            catalogs = try await service.catalogs().map { try $0.validated() }
        } catch {
            guard let publicUserID = await publicUserIDProvider() else { throw error }
            let installed = try await installer.installedCatalogs(
                publicUserID: publicUserID
            )
            guard !installed.isEmpty else { throw error }
            catalogs = installed.map(\.catalog)
        }
        await cache.replace(with: catalogs)
        return Dictionary(
            catalogs.map { ($0.comiketNo, CatalogEvent(id: $0.comiketNo, number: $0.comiketNo)) },
            uniquingKeysWith: { current, _ in current }
        ).values
            .sorted { $0.number > $1.number }
    }

    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        let catalog: CominaviCatalog
        if let cached = await cache.catalog(comiketNo: event.number) {
            catalog = cached
        } else {
            catalog = try await service.catalog(comiketNo: event.number)
        }
        guard let publicUserID = await publicUserIDProvider() else {
            throw CominaviCatalogError.invalidAccount
        }
        let installed = try await installer.install(
            catalog,
            publicUserID: publicUserID,
            progress: progress
        )
        return makeConfiguration(installed: installed, publicUserID: publicUserID)
    }

    func recoveryConfiguration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        let catalog = try await service.catalog(comiketNo: event.number).validated()
        await cache.store(catalog)
        guard let publicUserID = await publicUserIDProvider() else {
            throw CominaviCatalogError.invalidAccount
        }
        let installed = try await installer.redownload(
            catalog,
            publicUserID: publicUserID,
            progress: progress
        )
        return makeConfiguration(installed: installed, publicUserID: publicUserID)
    }

    private func makeConfiguration(
        installed: CominaviInstalledCatalog,
        publicUserID: String
    ) -> CatalogDataSourceConfiguration {
        let database = CatalogDatabaseConfiguration(
            digest: installed.catalog.artifact.sha256,
            origin: .local(installed.url)
        )
        return CatalogDataSourceConfiguration(
            eventID: installed.catalog.comiketNo,
            eventNumber: installed.catalog.comiketNo,
            main: database,
            image: database,
            enrichment: CatalogResourceLocator.url(
                named: "crawl-c\(installed.catalog.comiketNo)-shinagaki.json"
            ).map {
                CatalogEnrichmentConfiguration(resourceURL: $0, isRequired: false)
            },
            tagCatalogPayloadSHA256: installed.catalog.sourceMainSHA256,
            allowsBookmarkSync: true,
            // The public Comiket number is not a Circle.ms provider event ID.
            // Sanitized metadata/realtime uses ComiNavi-owned endpoints only.
            allowsRemoteMetadata: false,
            allowsCirclemsFavoriteMirror: false,
            accountPublicUserID: publicUserID
        )
    }
}

protocol CominaviCatalogInstalling: Sendable {
    func install(
        _ catalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CominaviInstalledCatalog
    func redownload(
        _ catalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CominaviInstalledCatalog
    func installedCatalogs(publicUserID: String) async throws -> [CominaviInstalledCatalog]
}

extension CominaviCatalogInstalling {
    func redownload(
        _ catalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CominaviInstalledCatalog {
        try await install(catalog, publicUserID: publicUserID, progress: progress)
    }

    func installedCatalogs(publicUserID: String) async throws -> [CominaviInstalledCatalog] {
        []
    }
}

actor CominaviCatalogInstaller: CominaviCatalogInstalling {
    static let defaultChunkBytes: Int64 = 16 * 1_024 * 1_024

    nonisolated static func removeAllDownloadedData(
        rootDirectory: URL = DirectoryManager.shared.environmentApplicationSupportDirectory
            .appendingPathComponent("CominaviCatalogs", isDirectory: true)
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
            try fileManager.removeItem(at: rootDirectory)
        }.value
    }

    private struct Checkpoint: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let comiketNo: Int
        let versionID: String
        let sha256: String
        let expectedBytes: Int64
        let partialFileName: String
        var currentLength: Int64
        var etag: String?

        func matches(_ catalog: CominaviCatalog, partialFileName: String) -> Bool {
            schemaVersion == 1
                && comiketNo == catalog.comiketNo
                && versionID == catalog.versionID
                && sha256 == catalog.artifact.sha256
                && expectedBytes == catalog.artifact.bytes
                && self.partialFileName == partialFileName
        }
    }

    private struct InstalledReceipt: Codable, Sendable {
        let schemaVersion: Int
        let fileName: String
        let catalog: CominaviCatalog
        let fallback: InstalledVersion?
    }

    private struct InstalledVersion: Codable, Sendable {
        let fileName: String
        let catalog: CominaviCatalog
    }

    private enum ResponseDisposition {
        case append(etag: String, start: Int64, end: Int64)
        case replace(etag: String)
        case unauthorized
        case rangeUnsatisfied
        case notModified
        case transient(status: Int)
    }

    private let authorizer: any CominaviCatalogRequestAuthorizing
    private let transport: any CominaviCatalogDownloadTransporting
    private let rootDirectory: URL
    private let chunkBytes: Int64
    private let retryDelay: Duration
    private let fileManager: FileManager

    init(
        authorizer: any CominaviCatalogRequestAuthorizing,
        transport: any CominaviCatalogDownloadTransporting =
            URLSessionCominaviCatalogDownloadTransport(),
        rootDirectory: URL = DirectoryManager.shared.environmentApplicationSupportDirectory
            .appendingPathComponent("CominaviCatalogs", isDirectory: true),
        chunkBytes: Int64 = CominaviCatalogInstaller.defaultChunkBytes,
        retryDelay: Duration = .seconds(2),
        fileManager: FileManager = .default
    ) {
        self.authorizer = authorizer
        self.transport = transport
        self.rootDirectory = rootDirectory
        self.chunkBytes = max(chunkBytes, 64 * 1_024)
        self.retryDelay = retryDelay
        self.fileManager = fileManager
    }

    func install(
        _ unvalidatedCatalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)? = nil
    ) async throws -> CominaviInstalledCatalog {
        try await install(
            unvalidatedCatalog,
            publicUserID: publicUserID,
            startsFreshDownload: false,
            progress: progress
        )
    }

    func redownload(
        _ unvalidatedCatalog: CominaviCatalog,
        publicUserID: String,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)? = nil
    ) async throws -> CominaviInstalledCatalog {
        try await install(
            unvalidatedCatalog,
            publicUserID: publicUserID,
            startsFreshDownload: true,
            progress: progress
        )
    }

    private func install(
        _ unvalidatedCatalog: CominaviCatalog,
        publicUserID: String,
        startsFreshDownload: Bool,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CominaviInstalledCatalog {
        let catalog = try unvalidatedCatalog.validated()
        try validatePublicUserID(publicUserID)
        let directory = catalogDirectory(comiketNo: catalog.comiketNo)
        let destinationURL = installedURL(for: catalog, in: directory)
        let partialURL = directory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(catalog.artifact.sha256).partial")
        let checkpointURL = partialURL.appendingPathExtension("json")

        do {
            if startsFreshDownload {
                try removeCatalogDirectory(directory)
                if let progress {
                    await progress(Readiness.Progress(
                        type: .main,
                        totalBytes: catalog.artifact.bytes,
                        completedBytes: 0
                    ))
                }
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    try await validateDatabase(at: destinationURL, catalog: catalog)
                    try saveInstalledReceipt(catalog: catalog, url: destinationURL, in: directory)
                    try? garbageCollect(in: directory, keeping: destinationURL)
                    return CominaviInstalledCatalog(
                        catalog: catalog,
                        url: destinationURL,
                        isCurrentVersion: true
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // An immutable digest path that no longer validates must not
                    // short-circuit every later repair attempt.
                    try quarantineInvalidInstalledFile(destinationURL, in: directory)
                }
            }

            var didRetryInvalidCompletedArtifact = false
            while true {
                var checkpoint = try loadCheckpoint(
                    at: checkpointURL,
                    partialURL: partialURL,
                    catalog: catalog
                )
                try await download(
                    catalog,
                    partialURL: partialURL,
                    checkpointURL: checkpointURL,
                    checkpoint: &checkpoint,
                    progress: progress
                )
                do {
                    try await validateDatabase(at: partialURL, catalog: catalog)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A full-size invalid partial is not resumable. Clear both
                    // bytes and marker so a later launch can fetch this immutable
                    // manifest again instead of falling back forever.
                    try discardPartial(partialURL, checkpointURL: checkpointURL)
                    guard !didRetryInvalidCompletedArtifact else { throw error }
                    didRetryInvalidCompletedArtifact = true
                }
            }
            try await installDatabase(from: partialURL, to: destinationURL)
            try saveInstalledReceipt(catalog: catalog, url: destinationURL, in: directory)
            try? discardPartial(partialURL, checkpointURL: checkpointURL)
            try? garbageCollect(in: directory, keeping: destinationURL)
            return CominaviInstalledCatalog(
                catalog: catalog,
                url: destinationURL,
                isCurrentVersion: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !startsFreshDownload else { throw error }
            if let fallback = try? await validatedFallback(in: directory) {
                return CominaviInstalledCatalog(
                    catalog: fallback.catalog,
                    url: fallback.url,
                    isCurrentVersion: false
                )
            }
            throw error
        }
    }

    private func removeCatalogDirectory(_ directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let eventsDirectory = directory.deletingLastPathComponent()
        try fileManager.removeItem(at: directory)
        try Self.synchronizeDirectory(eventsDirectory)
    }

    func installedCatalogs(publicUserID: String) async throws -> [CominaviInstalledCatalog] {
        try validatePublicUserID(publicUserID)
        let eventsDirectory = rootDirectory.appendingPathComponent("events", isDirectory: true)
        guard fileManager.fileExists(atPath: eventsDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var installed: [CominaviInstalledCatalog] = []
        for directory in directories where directory.lastPathComponent.hasPrefix("c") {
            try Task.checkCancellation()
            if let catalog = try? await validatedFallback(in: directory) {
                installed.append(catalog)
            }
        }
        return installed.sorted { $0.catalog.comiketNo > $1.catalog.comiketNo }
    }

    private func download(
        _ catalog: CominaviCatalog,
        partialURL: URL,
        checkpointURL: URL,
        checkpoint: inout Checkpoint,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws {
        var invalidatedAccessToken: String?
        var transientFailures = 0
        var authorizationRecoveries = 0
        var lastProgressTime = ContinuousClock.now
        var lastProgressBytes = checkpoint.currentLength

        while checkpoint.currentLength < catalog.artifact.bytes {
            try Task.checkCancellation()
            let start = checkpoint.currentLength
            let end = min(start + chunkBytes - 1, catalog.artifact.bytes - 1)
            var headers = [
                "Accept": CominaviCatalog.contentType,
                "Range": "bytes=\(start)-\(end)",
            ]
            if start > 0, let etag = checkpoint.etag {
                headers["If-Range"] = etag
            }
            let authorized = try await authorizer.authorizedCatalogRequest(
                method: "GET",
                path: catalog.artifact.url,
                headers: headers,
                invalidatedAccessToken: invalidatedAccessToken
            )
            invalidatedAccessToken = nil

            do {
                let (temporaryURL, response) = try await transport.download(
                    for: authorized.request
                )
                defer { try? fileManager.removeItem(at: temporaryURL) }
                let disposition = try disposition(
                    for: response,
                    requestedStart: start,
                    requestedEnd: end,
                    catalog: catalog
                )
                switch disposition {
                case .unauthorized:
                    guard authorizationRecoveries < 1 else {
                        throw CominaviCatalogError.httpStatus(401)
                    }
                    authorizationRecoveries += 1
                    invalidatedAccessToken = authorized.accessToken
                    continue
                case .rangeUnsatisfied:
                    try await resolveUnsatisfiedRange(
                        catalog,
                        checkpoint: &checkpoint,
                        partialURL: partialURL,
                        checkpointURL: checkpointURL,
                        invalidatedAccessToken: &invalidatedAccessToken,
                        authorizationRecoveries: &authorizationRecoveries
                    )
                    continue
                case .notModified:
                    throw CominaviCatalogError.invalidResponse
                case .transient(let status):
                    transientFailures += 1
                    guard transientFailures <= 5 else {
                        throw CominaviCatalogError.httpStatus(status)
                    }
                    try await waitBeforeRetry(failureCount: transientFailures)
                    continue
                case .append(let etag, let responseStart, let responseEnd):
                    let expectedLength = responseEnd - responseStart + 1
                    guard try fileSize(at: temporaryURL) == expectedLength else {
                        throw CominaviCatalogError.invalidResponse
                    }
                    checkpoint.etag = etag
                    try append(temporaryURL, to: partialURL, expectedOffset: start)
                    checkpoint.currentLength = responseEnd + 1
                case .replace(let etag):
                    guard try fileSize(at: temporaryURL) == catalog.artifact.bytes else {
                        throw CominaviCatalogError.invalidResponse
                    }
                    checkpoint.currentLength = 0
                    checkpoint.etag = etag
                    try durablyReplacePartial(with: temporaryURL, at: partialURL)
                    checkpoint.currentLength = catalog.artifact.bytes
                }
                try save(checkpoint, to: checkpointURL)

                let now = ContinuousClock.now
                let elapsed = lastProgressTime.duration(to: now)
                let seconds = max(elapsed.seconds, 0.001)
                let speed = Double(checkpoint.currentLength - lastProgressBytes) / seconds
                lastProgressTime = now
                lastProgressBytes = checkpoint.currentLength
                if let progress {
                    await progress(Readiness.Progress(
                        type: .main,
                        totalBytes: catalog.artifact.bytes,
                        completedBytes: checkpoint.currentLength,
                        bytesPerSecond: speed > 0 ? speed : nil
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transientFailures += 1
                guard transientFailures <= 5, Self.isTransient(error) else { throw error }
                try await waitBeforeRetry(failureCount: transientFailures)
            }
        }
    }

    private func disposition(
        for response: HTTPURLResponse,
        requestedStart: Int64,
        requestedEnd: Int64,
        catalog: CominaviCatalog
    ) throws -> ResponseDisposition {
        switch response.statusCode {
        case 200:
            try validateIdentityHeaders(response, catalog: catalog)
            try validateAdvertisedLength(response, expected: catalog.artifact.bytes)
            return .replace(etag: try etag(from: response, catalog: catalog))
        case 206:
            try validateIdentityHeaders(response, catalog: catalog)
            let range = try contentRange(from: response)
            guard range.start == requestedStart,
                  range.end <= requestedEnd,
                  range.total == catalog.artifact.bytes
            else { throw CominaviCatalogError.invalidResponse }
            try validateAdvertisedLength(
                response,
                expected: range.end - range.start + 1
            )
            return .append(
                etag: try etag(from: response, catalog: catalog),
                start: range.start,
                end: range.end
            )
        case 304:
            return .notModified
        case 401:
            return .unauthorized
        case 416:
            return .rangeUnsatisfied
        case 408, 429, 500...599:
            return .transient(status: response.statusCode)
        default:
            throw CominaviCatalogError.httpStatus(response.statusCode)
        }
    }

    private func validateAdvertisedLength(
        _ response: HTTPURLResponse,
        expected: Int64
    ) throws {
        let advertised = response.expectedContentLength
        guard advertised == NSURLSessionTransferSizeUnknown || advertised == expected else {
            throw CominaviCatalogError.invalidResponse
        }
    }

    private func resolveUnsatisfiedRange(
        _ catalog: CominaviCatalog,
        checkpoint: inout Checkpoint,
        partialURL: URL,
        checkpointURL: URL,
        invalidatedAccessToken: inout String?,
        authorizationRecoveries: inout Int
    ) async throws {
        let authorized = try await authorizer.authorizedCatalogRequest(
            method: "HEAD",
            path: catalog.artifact.url,
            headers: ["Accept": CominaviCatalog.contentType],
            invalidatedAccessToken: invalidatedAccessToken
        )
        let response = try await transport.response(for: authorized.request)
        if response.statusCode == 401 {
            guard authorizationRecoveries < 1 else {
                throw CominaviCatalogError.httpStatus(401)
            }
            authorizationRecoveries += 1
            invalidatedAccessToken = authorized.accessToken
            return
        }
        guard response.statusCode == 200 else {
            throw CominaviCatalogError.httpStatus(response.statusCode)
        }
        try validateIdentityHeaders(response, catalog: catalog)
        try validateAdvertisedLength(response, expected: catalog.artifact.bytes)
        let length = try fileSizeIfPresent(at: partialURL)
        if length == catalog.artifact.bytes {
            checkpoint.currentLength = length
            checkpoint.etag = try etag(from: response, catalog: catalog)
        } else {
            try resetPartial(at: partialURL)
            checkpoint.currentLength = 0
            checkpoint.etag = nil
        }
        try save(checkpoint, to: checkpointURL)
    }

    private func validateIdentityHeaders(
        _ response: HTTPURLResponse,
        catalog: CominaviCatalog
    ) throws {
        guard response.value(forHTTPHeaderField: "Content-Type") == catalog.artifact.contentType,
              response.value(forHTTPHeaderField: "X-Content-Type-Options")?.lowercased()
                == "nosniff",
              response.value(forHTTPHeaderField: "Digest") == Self.digestHeader(
                forHexSHA256: catalog.artifact.sha256
              )
        else { throw CominaviCatalogError.invalidResponse }
    }

    private func etag(
        from response: HTTPURLResponse,
        catalog: CominaviCatalog
    ) throws -> String {
        guard let value = response.value(forHTTPHeaderField: "ETag"),
              value == catalog.expectedETag
        else { throw CominaviCatalogError.invalidResponse }
        return value
    }

    private func contentRange(
        from response: HTTPURLResponse
    ) throws -> (start: Int64, end: Int64, total: Int64) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              value.hasPrefix("bytes ")
        else { throw CominaviCatalogError.invalidResponse }
        let components = value.dropFirst("bytes ".count).split(separator: "/")
        guard components.count == 2,
              let total = Int64(components[1])
        else { throw CominaviCatalogError.invalidResponse }
        let bounds = components[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              total > end
        else { throw CominaviCatalogError.invalidResponse }
        return (start, end, total)
    }

    private func loadCheckpoint(
        at checkpointURL: URL,
        partialURL: URL,
        catalog: CominaviCatalog
    ) throws -> Checkpoint {
        try fileManager.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileName = partialURL.lastPathComponent
        var checkpoint: Checkpoint
        if let data = try? Data(contentsOf: checkpointURL),
           let stored = try? JSONDecoder().decode(Checkpoint.self, from: data),
           stored.matches(catalog, partialFileName: fileName)
        {
            checkpoint = stored
        } else {
            try? fileManager.removeItem(at: checkpointURL)
            try? fileManager.removeItem(at: partialURL)
            checkpoint = Checkpoint(
                schemaVersion: 1,
                comiketNo: catalog.comiketNo,
                versionID: catalog.versionID,
                sha256: catalog.artifact.sha256,
                expectedBytes: catalog.artifact.bytes,
                partialFileName: fileName,
                currentLength: 0,
                etag: nil
            )
        }

        let actualLength = try fileSizeIfPresent(at: partialURL)
        if actualLength < checkpoint.currentLength {
            try resetPartial(at: partialURL)
            checkpoint.currentLength = 0
            checkpoint.etag = nil
        } else if actualLength > checkpoint.currentLength {
            // Bytes can reach disk before the atomic checkpoint does. Truncate
            // back to the last durable response boundary and retry that range.
            try truncate(partialURL, to: checkpoint.currentLength)
        }
        try save(checkpoint, to: checkpointURL)
        return checkpoint
    }

    private func validatedFallback(in directory: URL) async throws -> CominaviInstalledCatalog {
        let receiptURL = installedReceiptURL(in: directory)
        let data = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(InstalledReceipt.self, from: data)
        guard receipt.schemaVersion == 1,
              receipt.fileName == URL(fileURLWithPath: receipt.fileName).lastPathComponent
        else { throw CominaviCatalogError.invalidInstalledReceipt }
        let candidates = [
            InstalledVersion(fileName: receipt.fileName, catalog: receipt.catalog),
            receipt.fallback,
        ].compactMap { $0 }
        for candidate in candidates {
            guard candidate.fileName
                == URL(fileURLWithPath: candidate.fileName).lastPathComponent
            else { continue }
            let url = directory.appendingPathComponent(candidate.fileName)
            do {
                let catalog = try candidate.catalog.validated()
                try await validateDatabase(at: url, catalog: catalog)
                return CominaviInstalledCatalog(
                    catalog: catalog,
                    url: url,
                    isCurrentVersion: candidate.fileName == receipt.fileName
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw CominaviCatalogError.invalidInstalledReceipt
    }

    private func validateDatabase(at url: URL, catalog: CominaviCatalog) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.validateDatabaseSynchronously(at: url, catalog: catalog)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func validateDatabaseSynchronously(
        at url: URL,
        catalog: CominaviCatalog
    ) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            == NSNumber(value: catalog.artifact.bytes)
        else { throw CominaviCatalogError.sizeMismatch }
        guard try sha256(of: url) == catalog.artifact.sha256 else {
            throw CominaviCatalogError.digestMismatch
        }

        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                  try Int.fetchOne(db, sql: "PRAGMA user_version") == 1
            else { throw CominaviCatalogError.invalidDatabase }

            let metadata = try Row.fetchAll(
                db,
                sql: """
                SELECT schema_version, version_id, comiket_no
                FROM catalog_metadata WHERE singleton = 1
                """
            )
            let schemaVersion: Int? = metadata.first?["schema_version"]
            let versionID: String? = metadata.first?["version_id"]
            let comiketNo: Int? = metadata.first?["comiket_no"]
            guard metadata.count == 1,
                  schemaVersion == 1,
                  versionID == catalog.versionID,
                  comiketNo == catalog.comiketNo
            else { throw CominaviCatalogError.identityMismatch }

            let objects = try Row.fetchAll(
                db,
                sql: "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view')"
            )
            let tables = Set(objects.compactMap { row -> String? in
                let type: String = row["type"]
                return type == "table" ? row["name"] : nil
            })
            let views = Set(objects.compactMap { row -> String? in
                let type: String = row["type"]
                return type == "view" ? row["name"] : nil
            })
            guard normalizedTables.isSubset(of: tables),
                  compatibilityViews.isSubset(of: views)
            else { throw CominaviCatalogError.invalidDatabase }

            let circleCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM circles") ?? -1
            let layoutCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM layouts") ?? -1
            let imageCount =
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM circle_images") ?? -1)
                + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM common_images") ?? -1)
            guard circleCount == catalog.counts.circles,
                  layoutCount == catalog.counts.layouts,
                  imageCount == catalog.counts.images
            else { throw CominaviCatalogError.countMismatch }

            let compatibilitySmokeCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM ComiketCircleWC AS circle
                JOIN ComiketCircleExtend AS extension ON extension.id = circle.id
                JOIN ComiketLayoutWC AS layout
                  ON layout.blockId = circle.blockId AND layout.spaceNo = circle.spaceNo
                JOIN ComiketCircleImage AS image ON image.WCId = extension.WCId
                WHERE circle.id = extension.WCId
                  AND circle.circlems IS NULL
                  AND extension.CirclemsPortalURL IS NULL
                """
            ) ?? 0
            guard compatibilitySmokeCount > 0 else {
                throw CominaviCatalogError.invalidDatabase
            }
            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ComiketCommonImage")
        }
    }

    private func installDatabase(from sourceURL: URL, to destinationURL: URL) async throws {
        let worker = Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stagingURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent("installing-\(UUID().uuidString.lowercased()).sqlite")
            defer { try? fileManager.removeItem(at: stagingURL) }
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            try Task.checkCancellation()
            let handle = try FileHandle(forWritingTo: stagingURL)
            try handle.synchronize()
            try handle.close()
            try Self.replaceAtomically(from: stagingURL, to: destinationURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func saveInstalledReceipt(
        catalog: CominaviCatalog,
        url: URL,
        in directory: URL
    ) throws {
        let oldReceipt: InstalledReceipt?
        if let oldData = try? Data(contentsOf: installedReceiptURL(in: directory)) {
            oldReceipt = try? JSONDecoder().decode(InstalledReceipt.self, from: oldData)
        } else {
            oldReceipt = nil
        }
        let fallback: InstalledVersion?
        if let oldReceipt, oldReceipt.fileName != url.lastPathComponent {
            fallback = InstalledVersion(
                fileName: oldReceipt.fileName,
                catalog: oldReceipt.catalog
            )
        } else {
            fallback = oldReceipt?.fallback
        }
        let receipt = InstalledReceipt(
            schemaVersion: 1,
            fileName: url.lastPathComponent,
            catalog: catalog,
            fallback: fallback
        )
        try save(receipt, to: installedReceiptURL(in: directory))
    }

    private func catalogDirectory(comiketNo: Int) -> URL {
        rootDirectory
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("c\(comiketNo)", isDirectory: true)
    }

    private func installedURL(for catalog: CominaviCatalog, in directory: URL) -> URL {
        directory.appendingPathComponent("catalog-\(catalog.artifact.sha256).sqlite")
    }

    private func installedReceiptURL(in directory: URL) -> URL {
        directory.appendingPathComponent("current.json")
    }

    private func validatePublicUserID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256 else {
            throw CominaviCatalogError.invalidAccount
        }
    }

    private func append(_ sourceURL: URL, to destinationURL: URL, expectedOffset: Int64) throws {
        if !fileManager.fileExists(atPath: destinationURL.path) {
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
        }
        guard try fileSize(at: destinationURL) == expectedOffset else {
            throw CominaviCatalogError.checkpointMismatch
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.seekToEnd()
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private func durablyReplacePartial(with sourceURL: URL, at destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("incoming-\(UUID().uuidString.lowercased()).partial")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        let handle = try FileHandle(forWritingTo: stagingURL)
        try handle.synchronize()
        try handle.close()
        try Self.replaceAtomically(from: stagingURL, to: destinationURL)
    }

    private func resetPartial(at url: URL) throws {
        try? fileManager.removeItem(at: url)
    }

    private func truncate(_ url: URL, to length: Int64) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            guard length == 0 else { throw CominaviCatalogError.checkpointMismatch }
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        try handle.synchronize()
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try fileSize(at: url)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CominaviCatalogError.invalidResponse
        }
        return size.int64Value
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stagingURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try encoder.encode(value).write(to: stagingURL)
        let handle = try FileHandle(forWritingTo: stagingURL)
        try handle.synchronize()
        try handle.close()
        try Self.replaceAtomically(from: stagingURL, to: url)
    }

    private func discardPartial(_ partialURL: URL, checkpointURL: URL) throws {
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        if fileManager.fileExists(atPath: checkpointURL.path) {
            try fileManager.removeItem(at: checkpointURL)
        }
        try Self.synchronizeDirectory(partialURL.deletingLastPathComponent())
    }

    private func quarantineInvalidInstalledFile(_ url: URL, in directory: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let quarantineDirectory = directory.appendingPathComponent("Corrupt", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )
        let quarantineURL = quarantineDirectory.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).sqlite"
        )
        try fileManager.moveItem(at: url, to: quarantineURL)
        try Self.synchronizeDirectory(directory)
        try Self.synchronizeDirectory(quarantineDirectory)
        try pruneFiles(in: quarantineDirectory, keeping: 2)
    }

    private func garbageCollect(in directory: URL, keeping currentURL: URL) throws {
        var retainedNames: Set<String> = [currentURL.lastPathComponent]
        if let data = try? Data(contentsOf: installedReceiptURL(in: directory)),
           let receipt = try? JSONDecoder().decode(InstalledReceipt.self, from: data),
           let fallback = receipt.fallback
        {
            retainedNames.insert(fallback.fileName)
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries
        where entry.lastPathComponent.hasPrefix("catalog-")
            && entry.pathExtension == "sqlite"
            && !retainedNames.contains(entry.lastPathComponent)
        {
            try? fileManager.removeItem(at: entry)
        }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        if fileManager.fileExists(atPath: downloads.path) {
            try pruneFiles(in: downloads, keeping: 2)
        }
        let quarantine = directory.appendingPathComponent("Corrupt", isDirectory: true)
        if fileManager.fileExists(atPath: quarantine.path) {
            try pruneFiles(in: quarantine, keeping: 2)
        }
        try Self.synchronizeDirectory(directory)
    }

    private func pruneFiles(in directory: URL, keeping limit: Int) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        for entry in entries.dropFirst(max(limit, 0)) {
            try? fileManager.removeItem(at: entry)
        }
        try Self.synchronizeDirectory(directory)
    }

    nonisolated private static func replaceAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError() }
        try synchronizeDirectory(destinationURL.deletingLastPathComponent())
    }

    nonisolated private static func synchronizeDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    nonisolated private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func waitBeforeRetry(failureCount: Int) async throws {
        guard retryDelay > .zero else {
            try Task.checkCancellation()
            return
        }
        let multiplier = min(1 << max(failureCount - 1, 0), 8)
        try await Task.sleep(for: retryDelay * multiplier)
    }

    private static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return transientURLCodes.contains(error.code)
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func digestHeader(forHexSHA256 hex: String) -> String {
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return "sha-256=:\(bytes.base64EncodedString()):"
    }

    nonisolated private static let normalizedTables: Set<String> = [
        "catalog_metadata", "dates", "maps", "areas", "blocks", "floors", "mappings",
        "genres", "layouts", "circles", "circle_images", "common_images",
    ]

    nonisolated private static let compatibilityViews: Set<String> = [
        "ComiketInfoWC", "ComiketDateWC", "ComiketMapWC", "ComiketAreaWC",
        "ComiketBlockWC", "ComiketFloorWC", "ComiketMappingWC", "ComiketGenreWC",
        "ComiketLayoutWC", "ComiketCircleWC", "ComiketCircleExtend",
        "ComiketCircleImage", "ComiketCommonImage",
    ]

    private static let transientURLCodes: Set<URLError.Code> = [
        .backgroundSessionWasDisconnected, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
        .resourceUnavailable, .timedOut,
    ]
}

enum CominaviCatalogError: LocalizedError, Equatable, Sendable {
    case invalidManifest
    case invalidAccount
    case invalidResponse
    case httpStatus(Int)
    case checkpointMismatch
    case sizeMismatch
    case digestMismatch
    case invalidDatabase
    case identityMismatch
    case countMismatch
    case invalidInstalledReceipt

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            String(localized: "ComiNavi returned invalid catalog information.")
        case .invalidAccount:
            String(localized: "Please sign in again before opening the catalog.")
        case .invalidResponse, .httpStatus:
            String(localized: "The catalog could not be verified.")
        case .checkpointMismatch:
            String(localized: "The catalog download could not be resumed. Please try again.")
        case .sizeMismatch, .digestMismatch:
            String(localized: "The catalog download was incomplete. Please try again.")
        case .invalidDatabase, .identityMismatch, .countMismatch:
            String(localized: "The catalog could not be opened. Please try downloading it again.")
        case .invalidInstalledReceipt:
            String(localized: "The installed catalog could not be verified. Please try downloading it again.")
        }
    }

    var allowsFreshDownloadRecovery: Bool {
        switch self {
        case .invalidResponse, .httpStatus, .checkpointMismatch, .sizeMismatch,
             .digestMismatch, .invalidDatabase, .identityMismatch, .countMismatch:
            true
        case .invalidManifest, .invalidAccount, .invalidInstalledReceipt:
            false
        }
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
