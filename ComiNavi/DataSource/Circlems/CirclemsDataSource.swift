//
//  CirclemsDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import CryptoKit
import Foundation
import GRDB
import Observation
import zlib

enum Readiness: Equatable {
    struct Progress: Equatable {
        var type: CirclemsDataSourceDatabaseType
        var totalBytes: Int64
        var completedBytes: Int64
        var bytesPerSecond: Double?

        init(
            type: CirclemsDataSourceDatabaseType,
            totalBytes: Int64,
            completedBytes: Int64,
            bytesPerSecond: Double? = nil
        ) {
            self.type = type
            self.totalBytes = totalBytes
            self.completedBytes = completedBytes
            self.bytesPerSecond = bytesPerSecond
        }

        var fractionCompleted: Double {
            guard totalBytes > 0 else { return completedBytes > 0 ? 1 : 0 }
            return Swift.min(Swift.max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
    }
    
    typealias Progresses = [Progress]
    
    case uninitialized
    case downloading(progresses: Progresses)
    case initializing(state: String)
    case ready
    case error(error: String)
}

extension Readiness.Progresses {
    var totalBytes: Int64 {
        return self.reduce(0) { $0 + $1.totalBytes }
    }
    
    var completedBytes: Int64 {
        return self.reduce(0) { $0 + $1.completedBytes }
    }
    
    var fractionCompleted: Double {
        guard totalBytes > 0 else { return completedBytes > 0 ? 1 : 0 }
        return Swift.min(Swift.max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    var bytesPerSecond: Double? {
        let activeProgresses = filter { $0.completedBytes < $0.totalBytes }
        guard !activeProgresses.isEmpty,
              activeProgresses.allSatisfy({ ($0.bytesPerSecond ?? 0) > 0 })
        else {
            return nil
        }
        return activeProgresses.compactMap(\.bytesPerSecond).reduce(0, +)
    }

    var estimatedRemainingTime: TimeInterval? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let remainingBytes = reduce(Int64(0)) { partialResult, progress in
            partialResult + Swift.max(progress.totalBytes - progress.completedBytes, 0)
        }
        guard remainingBytes > 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}

enum FloorMapLayer {
    case base
    case overlayGenre
}

extension FloorMapLayer {
    var fileNameFragment: String {
        switch self {
        case .base:
            return "WMP"
        case .overlayGenre:
            return "WGR"
        }
    }
}

enum CatalogDatabaseOrigin: Equatable, Sendable {
    case remote(URL)
    case local(URL)
}

struct CatalogDatabaseConfiguration: Equatable, Sendable {
    let digest: String
    let origin: CatalogDatabaseOrigin
}

struct CatalogDataSourceConfiguration: Equatable, Sendable {
    let eventID: Int
    let eventNumber: Int
    let main: CatalogDatabaseConfiguration
    let image: CatalogDatabaseConfiguration
    let enrichment: CatalogEnrichmentConfiguration?
    let tagCatalogPayloadSHA256: String?
    let allowsBookmarkSync: Bool
    let allowsRemoteMetadata: Bool
    let allowsCirclemsFavoriteMirror: Bool
    let accountPublicUserID: String?

    init(
        eventID: Int,
        eventNumber: Int,
        main: CatalogDatabaseConfiguration,
        image: CatalogDatabaseConfiguration,
        enrichment: CatalogEnrichmentConfiguration? = nil,
        tagCatalogPayloadSHA256: String? = nil,
        allowsBookmarkSync: Bool,
        allowsRemoteMetadata: Bool = true,
        allowsCirclemsFavoriteMirror: Bool = false,
        accountPublicUserID: String? = nil
    ) {
        self.eventID = eventID
        self.eventNumber = eventNumber
        self.main = main
        self.image = image
        self.enrichment = enrichment
        self.tagCatalogPayloadSHA256 = tagCatalogPayloadSHA256
        self.allowsBookmarkSync = allowsBookmarkSync
        self.allowsRemoteMetadata = allowsRemoteMetadata
        self.allowsCirclemsFavoriteMirror = allowsCirclemsFavoriteMirror
        self.accountPublicUserID = accountPublicUserID
    }
}

enum CirclemsDataSourceDatabaseType: String, Equatable, Hashable, Sendable {
    case main
    case image

    var localizedName: String {
        switch self {
        case .main: String(localized: "Catalog")
        case .image: String(localized: "Images")
        }
    }
    
    var estimatedBytes: Int64 {
        switch self {
        case .main:
            return 4_880_130
        case .image:
            return 341_840_565
        }
    }

    var requiredTables: Set<String> {
        switch self {
        case .main:
            ["ComiketInfoWC", "ComiketCircleWC"]
        case .image:
            ["ComiketCircleImage", "ComiketCommonImage"]
        }
    }
}

enum CirclemsDatabaseInstallationError: Error, Equatable, Sendable {
    case integrityCheckFailed
}

struct CirclemsDataSourceDatabaseMetadata: Equatable, Sendable {
    var type: CirclemsDataSourceDatabaseType
    var digest: String
    var origin: CatalogDatabaseOrigin
    var localPath: String

    var remoteURL: URL? {
        guard case .remote(let url) = origin else { return nil }
        return url
    }

    var isLocalResource: Bool {
        if case .local = origin { return true }
        return false
    }
}

struct CirclemsDataSourceDatabases {
    let main: CirclemsDataSourceDatabaseMetadata
    let image: CirclemsDataSourceDatabaseMetadata
}

struct CatalogNotificationCircle: Equatable, Sendable {
    let publicCircleID: Int
    let name: String
    let coverImageData: Data?
}

@MainActor
@Observable
final class CirclemsDataSource {
    static let SHOULD_CHECK_DATABASE_EXISTS = true
    
    private let databases: CirclemsDataSourceDatabases
    private let databaseDownloader: ResumableCatalogDownload
    private let allowsBookmarkSync: Bool
    private let allowsCirclemsFavoriteMirror: Bool
    private let enrichmentIsRequired: Bool
    private let enrichmentStore: CatalogEnrichmentStore?
    private let tagCatalogPayloadSHA256: String?
    private let realtimeStore: CominaviRealtimeStore?
    let allowsRemoteMetadata: Bool
    
    private var sqliteMain: (any DatabaseReader)!
    private var sqliteImage: (any DatabaseReader)!
    private var preparationTask: Task<Void, Error>?

    private(set) var mapCatalog: (any MapCatalog)!
    private(set) var userPlanStore: any UserPlanStoring
    private(set) var bookmarkSyncCoordinator: BookmarkSyncCoordinator!
    
    public var comiket: Comiket!
    public let eventID: Int
    public var comiketId: String
    
    var readiness: Readiness = .uninitialized
    
    init(
        configuration: CatalogDataSourceConfiguration,
        databaseDownloader: ResumableCatalogDownload = .live
    ) {
        let comiketId = String(configuration.eventNumber)
        self.eventID = configuration.eventID
        self.databases = CirclemsDataSourceDatabases(
            main: CirclemsDataSourceDatabaseMetadata(
                type: .main,
                digest: configuration.main.digest,
                origin: configuration.main.origin,
                localPath: Self.localPath(
                    for: configuration.main.origin,
                    type: .main,
                    eventID: configuration.eventID,
                    comiketID: comiketId
                )
            ),
            image: CirclemsDataSourceDatabaseMetadata(
                type: .image,
                digest: configuration.image.digest,
                origin: configuration.image.origin,
                localPath: Self.localPath(
                    for: configuration.image.origin,
                    type: .image,
                    eventID: configuration.eventID,
                    comiketID: comiketId
                )
            )
        )
        self.databaseDownloader = databaseDownloader
        self.allowsBookmarkSync = configuration.allowsBookmarkSync
        self.allowsCirclemsFavoriteMirror = configuration.allowsCirclemsFavoriteMirror
        self.allowsRemoteMetadata = configuration.allowsRemoteMetadata
        enrichmentIsRequired = configuration.enrichment?.isRequired == true
        enrichmentStore = configuration.enrichment.map {
            CatalogEnrichmentStore(
                resourceURL: $0.resourceURL,
                ocrSearchResourceURL: $0.ocrSearchResourceURL
            )
        }
        tagCatalogPayloadSHA256 = configuration.tagCatalogPayloadSHA256
        realtimeStore = configuration.allowsBookmarkSync ? .shared : nil
        self.comiketId = comiketId

        let verifiedPublicUserID = configuration.accountPublicUserID
            ?? (AppData.profileStore.isIdentityVerified ? AppData.profileStore.profile?.id : nil)
        if let verifiedPublicUserID,
           let userPlanURL = try? DirectoryManager.shared
            .userDataFor(
                eventID: configuration.eventID,
                comiketId: comiketId,
                publicUserID: verifiedPublicUserID
            )
            .appendingPathComponent("user-plan.sqlite"),
           let userPlanStore = try? SQLiteUserPlanStore(path: userPlanURL.path)
        {
            self.userPlanStore = userPlanStore
        } else {
            // Never substitute a Circle.ms numeric ID (or zero) before the
            // provider-neutral ComiNavi identity has been verified.
            self.userPlanStore = InMemoryUserPlanStore()
        }

        if !configuration.allowsBookmarkSync {
            bookmarkSyncCoordinator = nil
        }
        
        self.prepare()
    }

    private static func localPath(
        for origin: CatalogDatabaseOrigin,
        type: CirclemsDataSourceDatabaseType,
        eventID: Int,
        comiketID: String
    ) -> String {
        switch origin {
        case .local(let url):
            url.path
        case .remote:
            DirectoryManager.shared
                .cachesFor(
                    eventID: eventID,
                    comiketId: comiketID,
                    .circlems,
                    .databases,
                    createIfNeeded: true
                )
                .appendingPathComponent("\(type.rawValue).sqlite")
                .path
        }
    }
    
    private func prepare() {
        self.readiness = .initializing(state: String(localized: "Preparing catalog…"))

        preparationTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.initialize()
                try Task.checkCancellation()

                self.readiness = .ready
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.readiness = .error(error: error.localizedDescription)
                throw error
            }
        }
    }

    func waitUntilReady() async throws {
        guard let preparationTask else { throw CancellationError() }
        try await preparationTask.value
    }

    func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
    }
    
    private func initialize() async throws {
        try Task.checkCancellation()
        try await self.prepareDatabases()
        try Task.checkCancellation()
        self.readiness = .initializing(state: String(localized: "Preparing catalog…"))
        try await self.initDatabaseConnections()
        try Task.checkCancellation()
        self.readiness = .initializing(state: String(localized: "Preparing map…"))
        try self.preloadUFDData()
        try Task.checkCancellation()
        if let enrichmentStore {
            self.readiness = .initializing(state: String(localized: "Preparing updates…"))
            do {
                try await enrichmentStore.prepare()
            } catch {
                if enrichmentIsRequired {
                    throw error
                }
                NSLog("Optional catalog enrichment could not be loaded: \(error)")
            }
        }
        try Task.checkCancellation()
        #if DEBUG
        await runMapIndexProbeIfRequested()
        #endif
        self.readiness = .initializing(state: String(localized: "Almost ready…"))
    }

    #if DEBUG
    private func runMapIndexProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-map-index-probe") else {
            return
        }

        do {
            let sceneID = CatalogMapScene.ID(day: 1, mapID: 1)
            let placements = try await mapCatalog.circlePlacements(
                in: CatalogMapViewport(
                    sceneID: sceneID,
                    mapRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                    renderedScale: CatalogMapViewport.circleArtworkThreshold
                )
            )
            guard let placement = placements.first,
                  let circle = try await mapCatalog.circles(
                    day: 1,
                    tableID: placement.tableID
                  ).first,
                  circle.circleName.count >= 3
            else {
                throw NSError(
                    domain: "CirclemsDataSource.MapIndexProbe",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No searchable circle was found in the probe viewport."]
                )
            }
            let query = String(circle.circleName.prefix(3))
            let matches = try await mapCatalog.search(day: 1, mapID: 1, query: query)
            guard matches.contains(where: { $0.id == circle.id }) else {
                throw NSError(
                    domain: "CirclemsDataSource.MapIndexProbe",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The derived index did not return its source circle."]
                )
            }
            NSLog("Map index probe succeeded: \(placements.count) placements, query matched \(matches.count) circles")
        } catch {
            NSLog("Map index probe failed: \(error)")
        }
    }
    #endif
    
    private func prepareDatabases() async throws {
        let allDatabases = [self.databases.main, self.databases.image]
        var databasesToDownload: [CirclemsDataSourceDatabaseMetadata] = []

        if databases.main.isLocalResource,
           databases.image.isLocalResource,
           databases.main.localPath == databases.image.localPath
        {
            try await Self.validateCombinedDatabaseOffMainActor(
                at: URL(fileURLWithPath: databases.main.localPath)
            )
            NSLog("Combined catalog database is ready; no duplicate validation is required")
            return
        }

        for database in allDatabases {
            if database.isLocalResource {
                try await Self.validateDatabaseOffMainActor(
                    at: URL(fileURLWithPath: database.localPath),
                    type: database.type
                )
            } else if !self.shouldSkipDatabaseDownload(metadata: database) {
                databasesToDownload.append(database)
            }
        }
        
        if databasesToDownload.isEmpty {
            NSLog("Catalog databases are ready; no download is required")
            return
        }
        
        let initialProgresses = databasesToDownload.map { db in
            Readiness.Progress(type: db.type, totalBytes: db.type.estimatedBytes, completedBytes: 0)
        }
        let progressTracker = DownloadProgressTracker(progresses: initialProgresses)
        self.readiness = .downloading(progresses: initialProgresses)

        // parallel download
        try await withThrowingTaskGroup(of: Void.self) { group in
            for database in databasesToDownload {
                group.addTask {
                    try await self.downloadDatabase(metadata: database) { [weak self] completedBytes, totalBytes in
                        guard let progresses = progressTracker.record(
                            type: database.type,
                            completedBytes: completedBytes,
                            totalBytes: totalBytes
                        ) else { return }
                        self?.readiness = .downloading(progresses: progresses)
                    }
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    private func shouldSkipDatabaseDownload(metadata: CirclemsDataSourceDatabaseMetadata) -> Bool {
        if CirclemsDataSource.SHOULD_CHECK_DATABASE_EXISTS,
           FileManager.default.fileExists(atPath: metadata.localPath),
           Self.hasSQLiteHeader(at: URL(fileURLWithPath: metadata.localPath)),
           let localDataDigest = UserDefaults.standard.string(forKey: databaseDigestKey(for: metadata.type)),
           localDataDigest.caseInsensitiveCompare(metadata.digest) == .orderedSame
        {
            return true
        }
        return false
    }
    
    private func downloadDatabase(
        metadata: CirclemsDataSourceDatabaseMetadata,
        progressHandler: (@MainActor @Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let url = metadata.remoteURL, url.scheme == "https" else {
            throw NSError(
                domain: "CirclemsDataSource",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Circle.ms returned an invalid catalog link."
                    ),
                ]
            )
        }

        let downloadDirectory = DirectoryManager.shared.cachesFor(
            eventID: eventID,
            comiketId: comiketId,
            .circlems,
            .downloads,
            createIfNeeded: true
        )
        let temporaryDatabaseURL = downloadDirectory
            .appendingPathComponent("\(metadata.type.rawValue)-\(UUID().uuidString).sqlite")
        let checkpointURL = downloadCheckpointURL(
            for: metadata,
            in: downloadDirectory
        )
        let digestKey = databaseDigestKey(for: metadata.type)
        
        NSLog(
            "Downloading \(metadata.type.rawValue) catalog database from \(url.host ?? "Circle.ms")"
        )

        do {
            var didRetryFailedIntegrityCheck = false
            while true {
                let downloadedArchiveURL = try await databaseDownloader.download(
                    from: url,
                    checkpointURL: checkpointURL
                ) { completedBytes, totalBytes in
                    Task { @MainActor in
                        progressHandler?(completedBytes, totalBytes)
                    }
                }

                do {
                    try await Self.installDownloadedDatabase(
                        archiveURL: downloadedArchiveURL,
                        temporaryURL: temporaryDatabaseURL,
                        destinationURL: URL(fileURLWithPath: metadata.localPath),
                        expectedDigest: metadata.digest,
                        type: metadata.type
                    )

                    UserDefaults.standard.set(metadata.digest, forKey: digestKey)
                    return
                } catch CirclemsDatabaseInstallationError.integrityCheckFailed {
                    databaseDownloader.discardCheckpoint(at: checkpointURL)
                    if !didRetryFailedIntegrityCheck {
                        didRetryFailedIntegrityCheck = true
                        continue
                    }
                    throw NSError(
                        domain: "CirclemsDataSource",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The downloaded catalog could not be verified."
                            ),
                        ]
                    )
                }
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw NSError(
                domain: "CirclemsDataSource",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The catalog could not be downloaded: \(error.localizedDescription)"
                    ),
                ]
            )
        }
    }

    nonisolated static func installDownloadedDatabase(
        archiveURL: URL,
        temporaryURL: URL,
        destinationURL: URL,
        expectedDigest: String,
        type: CirclemsDataSourceDatabaseType
    ) async throws {
        try await runDatabaseWorker {
            let fileManager = FileManager.default
            defer {
                try? fileManager.removeItem(at: archiveURL)
                try? fileManager.removeItem(at: temporaryURL)
            }

            let downloadedDigest = try md5Digest(of: archiveURL)
            guard downloadedDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                throw CirclemsDatabaseInstallationError.integrityCheckFailed
            }

            try decompressGzipArchive(at: archiveURL, to: temporaryURL)
            try Task.checkCancellation()
            try validateDatabase(at: temporaryURL, type: type)
            try Task.checkCancellation()
            try installDatabase(from: temporaryURL, to: destinationURL)
        }
    }

    nonisolated private static func validateDatabaseOffMainActor(
        at url: URL,
        type: CirclemsDataSourceDatabaseType
    ) async throws {
        try await runDatabaseWorker {
            try validateDatabase(at: url, type: type)
        }
    }

    nonisolated private static func validateCombinedDatabaseOffMainActor(
        at url: URL
    ) async throws {
        try await runDatabaseWorker {
            try validateDatabase(at: url, types: [.main, .image])
        }
    }

    nonisolated private static func runDatabaseWorker<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool(invoking: operation)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func md5Digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var digest = Insecure.MD5()
        let bufferSize = 256 * 1024

        while true {
            try Task.checkCancellation()
            let data = try autoreleasepool {
                try handle.read(upToCount: bufferSize) ?? Data()
            }
            guard !data.isEmpty else { break }

            digest.update(data: data)
        }

        return digest.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func decompressGzipArchive(
        at archiveURL: URL,
        to outputURL: URL
    ) throws {
        guard hasGzipHeader(at: archiveURL) else {
            throw gzipError(
                code: Z_DATA_ERROR,
                description: "The downloaded archive is not in gzip format."
            )
        }

        guard let archive = gzopen(archiveURL.path, "rb") else {
            throw gzipError(
                code: Z_ERRNO,
                description: "The downloaded archive could not be opened."
            )
        }

        var didCloseArchive = false
        defer {
            if !didCloseArchive {
                gzclose(archive)
            }
        }

        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: outputURL.path]
            )
        }

        let output = try FileHandle(forWritingTo: outputURL)
        var didCloseOutput = false
        defer {
            if !didCloseOutput {
                try? output.close()
            }
        }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        while true {
            try Task.checkCancellation()
            let bytesRead = gzread(archive, buffer, UInt32(bufferSize))

            if bytesRead > 0 {
                try autoreleasepool {
                    let data = Data(
                        bytesNoCopy: buffer,
                        count: Int(bytesRead),
                        deallocator: .none
                    )
                    try output.write(contentsOf: data)
                }
                continue
            }

            if bytesRead < 0 {
                var code: Int32 = Z_DATA_ERROR
                let message = gzerror(archive, &code).map(String.init(cString:))
                throw gzipError(
                    code: code,
                    description: message ?? "The downloaded archive could not be decompressed."
                )
            }

            break
        }

        try output.synchronize()
        try output.close()
        didCloseOutput = true

        let closeStatus = gzclose(archive)
        didCloseArchive = true
        guard closeStatus == Z_OK else {
            throw gzipError(
                code: closeStatus,
                description: "The downloaded archive could not be decompressed."
            )
        }
    }

    nonisolated private static func hasGzipHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x1f, 0x8b])
    }

    nonisolated private static func gzipError(
        code: Int32,
        description: String
    ) -> NSError {
        NSError(
            domain: "CirclemsDataSource.Gzip",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    nonisolated static func validateDatabase(
        at url: URL,
        type: CirclemsDataSourceDatabaseType
    ) throws {
        try validateDatabase(at: url, types: [type])
    }

    nonisolated private static func validateDatabase(
        at url: URL,
        types: [CirclemsDataSourceDatabaseType]
    ) throws {
        let type = types.first ?? .main
        guard Self.hasSQLiteHeader(at: url) else {
            throw NSError(
                domain: "CirclemsDataSource",
                code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "The downloaded catalog could not be opened."
                    ),
                ]
            )
        }

        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.read { db in
            let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check")
            guard quickCheck == "ok" else {
                throw NSError(
                    domain: "CirclemsDataSource",
                    code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The downloaded catalog appears damaged. Please try downloading it again."
                        ),
                    ]
                )
            }

            let schemaObjects = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            ))
            let requiredTables = types.reduce(into: Set<String>()) {
                $0.formUnion($1.requiredTables)
            }
            let missingTables = requiredTables.subtracting(schemaObjects)
            guard missingTables.isEmpty else {
                throw NSError(
                    domain: "CirclemsDataSource",
                    code: 7,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The downloaded catalog is missing required information. Please try downloading it again."
                        ),
                    ]
                )
            }

            if Set(types) == Set([.main, .image]) {
                let smokeCount = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM ComiketCircleWC AS circle
                    JOIN ComiketCircleExtend AS extension ON extension.id = circle.id
                    JOIN ComiketLayoutWC AS layout
                      ON layout.blockId = circle.blockId AND layout.spaceNo = circle.spaceNo
                    JOIN ComiketCircleImage AS image ON image.WCId = extension.WCId
                    WHERE circle.id = extension.WCId
                    """
                ) ?? 0
                guard smokeCount > 0 else {
                    throw NSError(
                        domain: "CirclemsDataSource",
                        code: 8,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The downloaded catalog has invalid circle data. Please try downloading it again."
                            ),
                        ]
                    )
                }
            }
        }
    }

    nonisolated private static func installDatabase(
        from temporaryURL: URL,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    nonisolated private static func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let expectedHeader = Data("SQLite format 3\0".utf8)
        return (try? handle.read(upToCount: expectedHeader.count)) == expectedHeader
    }

    private func databaseDigestKey(for type: CirclemsDataSourceDatabaseType) -> String {
        "CirclemsDataSource.databaseDownloaded.gzippedDigest.\(AppEnvironment.current.storageNamespace).event-\(eventID).comiket-\(comiketId).\(type.rawValue)"
    }

    private func downloadCheckpointURL(
        for metadata: CirclemsDataSourceDatabaseMetadata,
        in downloadDirectory: URL
    ) -> URL {
        let digestIdentifier = SHA256.hash(data: Data(metadata.digest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "\(metadata.type.rawValue)-\(digestIdentifier).resume-data"
        let checkpointURL = downloadDirectory.appendingPathComponent(fileName)

        if let existingFiles = try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory,
            includingPropertiesForKeys: nil
        ) {
            let prefix = "\(metadata.type.rawValue)-"
            for fileURL in existingFiles
            where fileURL.lastPathComponent.hasPrefix(prefix)
                && fileURL.pathExtension == "resume-data"
                && fileURL != checkpointURL
            {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        return checkpointURL
    }

    private func initDatabaseConnections() async throws {
        // Initialize the SQLite databases
        var configuration = Configuration()
        configuration.readonly = true
        
        NSLog("Initializing databases at \(databases.main.localPath) and \(databases.image.localPath)...")
        if databases.main.isLocalResource {
            // GRDB recommends a single read-only queue for immutable resources.
            // A pool opens reader connections lazily, which can make SQLite try
            // to create sidecar state beside a file in the read-only app bundle.
            sqliteMain = try DatabaseQueue(
                path: databases.main.localPath,
                configuration: configuration
            )
        } else {
            sqliteMain = try DatabasePool(
                path: databases.main.localPath,
                configuration: configuration
            )
        }
        if databases.image.isLocalResource {
            sqliteImage = try DatabaseQueue(
                path: databases.image.localPath,
                configuration: configuration
            )
        } else {
            sqliteImage = try DatabasePool(
                path: databases.image.localPath,
                configuration: configuration
            )
        }
        let mapIndexURL = DirectoryManager.shared
            .cachesFor(eventID: eventID, comiketId: comiketId, .circlems, .databases, createIfNeeded: true)
            .appendingPathComponent("map-index.sqlite")
        let mapIndex = try? MapCatalogIndex(
            sourceDatabase: sqliteMain,
            cacheDatabasePath: mapIndexURL.path,
            catalogDigest: databases.main.digest
        )
        mapCatalog = SQLiteMapCatalog(
            mainDatabase: sqliteMain,
            imageDatabase: sqliteImage,
            index: mapIndex
        )
        if allowsBookmarkSync {
            bookmarkSyncCoordinator = BookmarkSyncCoordinator(
                eventID: eventID,
                eventNumber: Int(comiketId) ?? 0,
                catalog: mapCatalog,
                localStore: userPlanStore,
                serviceFavoriteSync: CominaviServiceClient.shared,
                circlemsMirror: allowsCirclemsFavoriteMirror
                    ? CirclemsFavoriteRemoteStore()
                    : nil
            )
        }
    }

    private func preloadUFDData() throws {
        let coverImage = try self.sqliteImage.read { db in
            try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE name = '0001'")
        }
        
        self.comiket = try self.sqliteMain.read { db in
            // Fetch ComiketInfoWC
            let infoEntries = try CirclemsDataSchema.ComiketInfoWC.fetchAll(db)
            
            // Fetch ComiketDateWC
            let dateEntries = try CirclemsDataSchema.ComiketDateWC.fetchAll(db)
            
            // Fetch ComiketAreaWC
            let areaEntries = try CirclemsDataSchema.ComiketAreaWC.fetchAll(db)
            
            // Fetch ComiketFloorWC
            let floorEntries = try CirclemsDataSchema.ComiketFloorWC.fetchAll(db)
            
            // Fetch ComiketMapWC
            let mapEntries = try CirclemsDataSchema.ComiketMapWC.fetchAll(db)
            
            // Fetch ComiketBlockWC
            let blockEntries = try CirclemsDataSchema.ComiketBlockWC.fetchAll(db)
            
            let coverImageData = coverImage?.image
            
            guard let infoFirst = infoEntries.first else {
                throw NSError(
                    domain: "CirclemsDataSource",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "Failed to load the Comiket catalog information."
                        ),
                    ]
                )
            }
            
            // Save the Cover Image under (cachesDirectory)/(comiketNo)/circlems/cover.png, if it does not exist
            var coverImageURL: URL? = nil
            if let coverImageData = coverImageData {
                coverImageURL = DirectoryManager.shared.cachesFor(eventID: eventID, comiketId: infoFirst.comiketNo.string, .circlems, .images, createIfNeeded: true)
                    .appendingPathComponent("cover.png")
                try coverImageURL?.writeIfNotExists(coverImageData)
            }
            
            // Populate Comiket objects
            var comiket = Comiket(
                id: "\(infoFirst.comiketNo)",
                number: infoFirst.comiketNo,
                name: infoFirst.comiketName ?? "N/A",
                cover: coverImageURL,
                days: [],
                blocks: []
            )
            
            // Populate Day objects
            for date in dateEntries {
                let dateComponents = DateComponents(
                    year: date.year,
                    month: date.month,
                    day: date.day
                )
                
                let day = UFDSchema.Day(
                    id: "\(date.comiketNo)_\(date.id)",
                    dayIndex: date.id,
                    date: dateComponents,
                    halls: []
                )
                
                comiket.days.append(day)
            }
            
            // Populate DayHall objects
            for floor in floorEntries {
                guard let day = comiket.days.firstIndex(where: { $0.dayIndex == floor.day }) else { continue }
                
                guard let map = mapEntries.first(where: { $0.id == floor.mapId }) else { continue }
                
                let hall = UFDSchema.DayHall(
                    id: "\(floor.comiketNo)_\(floor.day)_\(map.name ?? "")",
                    name: map.name ?? "",
                    mapName: map.filename ?? "",
                    externalMapId: map.id,
                    externalCorrespondingFloorId: floor.id,
                    areas: []
                )
                
                comiket.days[day].halls.append(hall)
            }
            
            // Populate DayHallArea objects
            for area in areaEntries {
                guard let day = comiket.days.firstIndex(where: { $0.dayIndex == area.id }) else { continue }
                
                guard let hall = comiket.days[day].halls.firstIndex(where: { $0.externalMapId == area.mapId }) else { continue }
                
                let area = UFDSchema.DayHallArea(
                    id: "\(area.comiketNo)_\(area.id)_\(area.mapId)_\(area.id)",
                    name: area.name ?? "",
                    externalAreaId: area.id
                )
                
                comiket.days[day].halls[hall].areas.append(area)
            }
            
            // Populate Block objects
            for block in blockEntries {
                let block = UFDSchema.Block(
                    id: "\(block.comiketNo)_\(block.id)",
                    name: block.name ?? "",
                    externalBlockId: block.id
                )
                
                comiket.blocks.append(block)
            }
            
            return comiket
        }
    }
    
    func getCircles() async -> [CirclemsDataSchema.ComiketCircleWC] {
        do {
            return try await sqliteMain.read { database in
                try CirclemsDataSchema.ComiketCircleWC.fetchAll(database)
            }
        } catch {
            return []
        }
    }

    func getGenres() async -> [CirclemsDataSchema.ComiketGenreWC] {
        do {
            return try await sqliteMain.read { database in
                try CirclemsDataSchema.ComiketGenreWC.fetchAll(database)
            }
        } catch {
            return []
        }
    }

    func getCircle(circleID: Int) async -> CirclemsDataSchema.ComiketCircleWC? {
        let comiketNumber = Int(comiketId) ?? 0
        return try? await sqliteMain.read { database in
            try CirclemsDataSchema.ComiketCircleWC.fetchOne(
                database,
                sql: "SELECT * FROM ComiketCircleWC WHERE comiketNo = ? AND id = ?",
                arguments: [comiketNumber, circleID]
            )
        }
    }

    func getCircle(publicCircleID: Int) async -> CirclemsDataSchema.ComiketCircleWC? {
        let comiketNumber = Int(comiketId) ?? 0
        return try? await sqliteMain.read { database in
            try CirclemsDataSchema.ComiketCircleWC.fetchOne(
                database,
                sql: """
                    SELECT circle.*
                    FROM ComiketCircleWC AS circle
                    JOIN ComiketCircleExtend AS extension
                      ON extension.comiketNo = circle.comiketNo
                     AND extension.id = circle.id
                    WHERE circle.comiketNo = ? AND extension.WCId = ?
                    LIMIT 1
                    """,
                arguments: [comiketNumber, publicCircleID]
            )
        }
    }

    func notificationCircle(publicCircleID: Int) async -> CatalogNotificationCircle? {
        let circle = await getCircle(publicCircleID: publicCircleID)
        guard let circle else { return nil }
        let imageData = await getCircleImage(circleId: circle.id)
        let name = circle.circleName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = if let name, !name.isEmpty {
            name
        } else {
            String(localized: "Circle")
        }
        return CatalogNotificationCircle(
            publicCircleID: publicCircleID,
            name: displayName,
            coverImageData: imageData
        )
    }

    func getCircleExtensions() async -> [CirclemsDataSchema.ComiketCircleExtend] {
        do {
            return try await sqliteMain.read { database in
                try CirclemsDataSchema.ComiketCircleExtend.fetchAll(database)
            }
        } catch {
            return []
        }
    }

    func getCircleDetails(circleID: Int) async -> CatalogCircleDetails {
        let comiketNumber = Int(comiketId) ?? 0
        let extensionRecord = try? await sqliteMain.read { database in
            try CirclemsDataSchema.ComiketCircleExtend.fetchOne(
                database,
                sql: "SELECT * FROM ComiketCircleExtend WHERE comiketNo = ? AND id = ?",
                arguments: [comiketNumber, circleID]
            )
        }
        let bundledEnrichment: CatalogCircleEnrichment?
        if let enrichmentStore {
            bundledEnrichment = try? await enrichmentStore.details(
                circleID: circleID,
                publicCircleID: extensionRecord?.WCId
            )
        } else {
            bundledEnrichment = nil
        }
        var realtimeEnrichment: CatalogCircleEnrichment?
        if let realtimeStore, let publicCircleID = extensionRecord?.WCId {
            try? await realtimeStore.refresh(
                eventNumber: comiketNumber,
                expectedTagCatalogPayloadSHA256: tagCatalogPayloadSHA256
            )
            await realtimeStore.waitForRevalidation(eventNumber: comiketNumber)
            realtimeEnrichment = await realtimeStore.enrichment(
                eventNumber: comiketNumber,
                publicCircleID: publicCircleID,
                expectedTagCatalogPayloadSHA256: tagCatalogPayloadSHA256
            )
        }
        let enrichment = if let bundledEnrichment {
            bundledEnrichment.merging(realtimeEnrichment)
        } else {
            realtimeEnrichment
        }
        return CatalogCircleDetails(
            extensionRecord: extensionRecord,
            enrichment: enrichment
        )
    }

    func getCircleEnrichments() async -> [Int: CatalogCircleEnrichment] {
        let extensions = await getCircleExtensions()
        let publicCircleIDsByCircleID = Dictionary(
            uniqueKeysWithValues: extensions.map { ($0.id, $0.WCId) }
        )
        var result: [Int: CatalogCircleEnrichment] = [:]
        if let enrichmentStore {
            result = (try? await enrichmentStore.all(
                publicCircleIDsByCircleID: publicCircleIDsByCircleID
            )) ?? [:]
        }
        if let realtimeStore {
            let eventNumber = Int(comiketId) ?? 0
            try? await realtimeStore.refresh(
                eventNumber: eventNumber,
                expectedTagCatalogPayloadSHA256: tagCatalogPayloadSHA256
            )
            await realtimeStore.waitForRevalidation(eventNumber: eventNumber)
            let realtimeByPublicID = await realtimeStore.enrichments(
                eventNumber: eventNumber,
                expectedTagCatalogPayloadSHA256: tagCatalogPayloadSHA256
            )
            for (circleID, publicCircleID) in publicCircleIDsByCircleID {
                guard let realtime = realtimeByPublicID[publicCircleID] else { continue }
                if let bundled = result[circleID] {
                    result[circleID] = bundled.merging(realtime)
                } else {
                    result[circleID] = realtime
                }
            }
        }
        return result
    }

    func enrichmentStatistics() async -> (
        selectedPosts: Int,
        mappedPosts: Int,
        mappedCircles: Int
    )? {
        guard let enrichmentStore else { return nil }
        return try? await enrichmentStore.statistics()
    }
    
    func getDemoCircle() -> CirclemsDataSchema.ComiketCircleWC! {
        do {
            let circle = try self.sqliteMain.read { db in
                try CirclemsDataSchema.ComiketCircleWC.fetchOne(db, sql: "SELECT * FROM ComiketCircleWC LIMIT 1")
            }
            
            return circle
        } catch {
            return nil
        }
    }
    
    func getDemoCircles() -> [CirclemsDataSchema.ComiketCircleWC] {
        do {
            return try self.sqliteMain.read { db in
                try [
                    CirclemsDataSchema.ComiketCircleWC.fetchOne(db, sql: "SELECT * FROM ComiketCircleWC WHERE description = '' LIMIT 1"),
                    CirclemsDataSchema.ComiketCircleWC.fetchOne(db, sql: "SELECT * FROM ComiketCircleWC WHERE description != '' LIMIT 1"),
                    CirclemsDataSchema.ComiketCircleWC.fetchOne(db, sql: "SELECT * FROM ComiketCircleWC WHERE penName == '' LIMIT 1"),
                    CirclemsDataSchema.ComiketCircleWC.fetchOne(db, sql: "SELECT * FROM ComiketCircleWC WHERE penName != '' LIMIT 1")
                ].compactMap { $0 }
            }
        } catch {
            return []
        }
    }
    
    func getBlocks() -> [CirclemsDataSchema.ComiketBlockWC] {
        do {
            return try self.sqliteMain.read { db in
                try CirclemsDataSchema.ComiketBlockWC.fetchAll(db)
            }
        } catch {
            return []
        }
    }
    
    func getCircleImage(circleId: Int) async -> Data? {
        let comiketId = comiketId
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCircleImage.fetchOne(db, sql: "SELECT * FROM ComiketCircleImage WHERE comiketNo = ? AND id = ?", arguments: [comiketId, circleId])
            }
            
            return image?.cutImage
        } catch {
            return nil
        }
    }
    
    func getCommonImage(name: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        let comiketId = comiketId
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [comiketId, name])
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    func getFloorMap(layer: FloorMapLayer, day: Int, areaFileNameFragment: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        let name = ["L", layer.fileNameFragment, "\(day)", areaFileNameFragment].joined()
        let comiketId = comiketId
        
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [comiketId, name])
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    func cleanAllCaches() async {
        if !databases.main.isLocalResource {
            UserDefaults.standard.removeObject(forKey: databaseDigestKey(for: databases.main.type))
        }
        if !databases.image.isLocalResource {
            UserDefaults.standard.removeObject(forKey: databaseDigestKey(for: databases.image.type))
        }
        let comiketId = comiketId
        let eventID = eventID
        await Task.detached(priority: .utility) {
            try? DirectoryManager.shared.removeCachesFor(eventID: eventID, comiketId: comiketId)
        }.value
    }
}
