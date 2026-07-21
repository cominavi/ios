//
//  CirclemsDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Alamofire
import CryptoKit
import Foundation
import GRDB
import Gzip

enum Readiness: Equatable {
    struct Progress: Equatable {
        var type: CirclemsDataSourceDatabaseType
        var totalBytes: Int64
        var completedBytes: Int64
        var fractionCompleted: Double {
            return Double(completedBytes) / Double(totalBytes)
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
        return Double(completedBytes) / Double(totalBytes)
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

struct CirclemsDataSourceRemoteConfig {
    var digest: String
    var remoteUrl: String
}

struct CirclemsDataSourceInitializationParams {
    let main: CirclemsDataSourceRemoteConfig
    let image: CirclemsDataSourceRemoteConfig
}

enum CirclemsDataSourceDatabaseType: String {
    case main
    case image
    
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

struct CirclemsDataSourceDatabaseMetadata: Equatable {
    var type: CirclemsDataSourceDatabaseType
    var digest: String
    var remoteUrl: String
    var localPath: String
}

struct CirclemsDataSourceDatabases {
    let main: CirclemsDataSourceDatabaseMetadata
    let image: CirclemsDataSourceDatabaseMetadata
}

class CirclemsDataSource: ObservableObject {
    static let SHOULD_CHECK_DATABASE_EXISTS = true
    
    private let databases: CirclemsDataSourceDatabases
    
    private var sqliteMain: DatabasePool!
    private var sqliteImage: DatabasePool!
    
    public var comiket: Comiket!
    public var comiketId: String
    
    @Published var readiness: Readiness = .uninitialized
    
    var circles: [CirclemsDataSchema.ComiketCircleWC] = []
    
    init(params: CirclemsDataSourceInitializationParams, comiketId: String) {
        self.databases = CirclemsDataSourceDatabases(
            main: CirclemsDataSourceDatabaseMetadata(
                type: .main,
                digest: params.main.digest,
                remoteUrl: params.main.remoteUrl,
                localPath: DirectoryManager.shared.cachesFor(comiketId: comiketId, .circlems, .databases, createIfNeeded: true)
                    .appendingPathComponent("main.sqlite")
                    .path
            ),
            image: CirclemsDataSourceDatabaseMetadata(
                type: .image,
                digest: params.image.digest,
                remoteUrl: params.image.remoteUrl,
                localPath: DirectoryManager.shared.cachesFor(comiketId: comiketId, .circlems, .databases, createIfNeeded: true)
                    .appendingPathComponent("image.sqlite")
                    .path
            )
        )
        self.comiketId = comiketId
        
        self.prepare()
    }
    
    private func prepare() {
        self.readiness = .initializing(state: "Pending...")
        
        Task(priority: .userInitiated) {
            do {
                try await self.initialize()
                
                DispatchQueue.main.async {
                    self.readiness = .ready
                }
            } catch {
                DispatchQueue.main.async {
                    self.readiness = .error(error: error.localizedDescription)
                }
            }
        }
    }
    
    private func initialize() async throws {
        try await self.downloadDatabases()
        DispatchQueue.main.sync {
            self.readiness = .initializing(state: "Initializing databases...")
        }
        try await self.initDatabaseConnections()
        DispatchQueue.main.sync {
            self.readiness = .initializing(state: "Preloading UFD Dataset...")
        }
        try self.preloadUFDData()
        DispatchQueue.main.sync {
            self.readiness = .initializing(state: "Extracting images...")
        }
        try await self.extractAndCacheCircleImages()
        DispatchQueue.main.sync {
            self.readiness = .initializing(state: "Fetching circles...")
        }
        try await self.preloadCircles()
        DispatchQueue.main.sync {
            self.readiness = .initializing(state: "Finalizing...")
        }
    }
    
    private func downloadDatabases() async throws {
        let allDatabases = [self.databases.main, self.databases.image]
        var databasesToDownload: [CirclemsDataSourceDatabaseMetadata] = []

        for database in allDatabases {
            if !self.shouldSkipDatabaseDownload(metadata: database) {
                databasesToDownload.append(database)
            }
        }
        
        if databasesToDownload.isEmpty {
            NSLog("All databases are up-to-date, skipping download all together")
            return
        }
        
        self.readiness = .downloading(progresses: databasesToDownload.map { db in
            Readiness.Progress(type: db.type, totalBytes: db.type.estimatedBytes, completedBytes: 0)
        })

        // parallel download
        try await withThrowingTaskGroup(of: Void.self) { group in
            for database in databasesToDownload {
                group.addTask {
                    try await self.downloadDatabase(metadata: database) { [weak self] completedBytes, totalBytes in
                        if case var .downloading(progresses) = self?.readiness {
                            if let index = progresses.firstIndex(where: { $0.type == database.type }) {
                                progresses[index].completedBytes = completedBytes
                                progresses[index].totalBytes = totalBytes
                                self?.readiness = .downloading(progresses: progresses)
                            }
                        }
                    }
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    private func shouldSkipDatabaseDownload(metadata: CirclemsDataSourceDatabaseMetadata) -> Bool {
        if CirclemsDataSource.SHOULD_CHECK_DATABASE_EXISTS,
           FileManager.default.fileExists(atPath: metadata.localPath),
           hasSQLiteHeader(at: URL(fileURLWithPath: metadata.localPath)),
           let localDataDigest = UserDefaults.standard.string(forKey: databaseDigestKey(for: metadata.type)),
           localDataDigest.caseInsensitiveCompare(metadata.digest) == .orderedSame
        {
            return true
        }
        return false
    }
    
    private func downloadDatabase(metadata: CirclemsDataSourceDatabaseMetadata, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let url = URL(string: metadata.remoteUrl), url.scheme == "https" else {
            throw NSError(
                domain: "CirclemsDataSource",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Circle.ms returned an invalid non-HTTPS database URL."]
            )
        }

        let downloadDirectory = DirectoryManager.shared.cachesFor(
            comiketId: comiketId,
            .circlems,
            .downloads,
            createIfNeeded: true
        )
        let temporaryDatabaseURL = downloadDirectory
            .appendingPathComponent("\(metadata.type.rawValue)-\(UUID().uuidString).sqlite")
        
        print("Downloading database from \(url) to \(metadata.localPath)...")
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.download(url)
                .downloadProgress { progress in
                    progressHandler?(progress.completedUnitCount, progress.totalUnitCount)
                }
                .validate()
                .responseData { response in
                    do {
                        guard let data = try? response.result.get() else {
                            throw NSError(domain: "CirclemsDataSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to download database from \(metadata.remoteUrl)"])
                        }

                        let downloadedDigest = Insecure.MD5.hash(data: data)
                            .map { String(format: "%02x", $0) }
                            .joined()
                        guard downloadedDigest.caseInsensitiveCompare(metadata.digest) == .orderedSame else {
                            throw NSError(
                                domain: "CirclemsDataSource",
                                code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "The downloaded \(metadata.type.rawValue) database failed its MD5 integrity check."]
                            )
                        }

                        let uncompressedData = try data.gunzipped()
                        try uncompressedData.write(to: temporaryDatabaseURL, options: .atomic)
                        try self.validateDatabase(at: temporaryDatabaseURL, type: metadata.type)
                        try self.installDatabase(
                            from: temporaryDatabaseURL,
                            to: URL(fileURLWithPath: metadata.localPath)
                        )

                        UserDefaults.standard.set(metadata.digest, forKey: self.databaseDigestKey(for: metadata.type))
                        continuation.resume()
                    } catch {
                        try? FileManager.default.removeItem(at: temporaryDatabaseURL)
                        continuation.resume(throwing: NSError(domain: "CirclemsDataSource", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to download database from \(metadata.remoteUrl): \(error)"]))
                    }
                }
        }
    }

    private func validateDatabase(at url: URL, type: CirclemsDataSourceDatabaseType) throws {
        guard hasSQLiteHeader(at: url) else {
            throw NSError(
                domain: "CirclemsDataSource",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The downloaded \(type.rawValue) file is not a SQLite 3 database."]
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
                    userInfo: [NSLocalizedDescriptionKey: "SQLite integrity check failed for the \(type.rawValue) database."]
                )
            }

            let tables = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
            let missingTables = type.requiredTables.subtracting(tables)
            guard missingTables.isEmpty else {
                throw NSError(
                    domain: "CirclemsDataSource",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The \(type.rawValue) database is missing required tables: \(missingTables.sorted().joined(separator: ", "))."]
                )
            }
        }
    }

    private func installDatabase(from temporaryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let expectedHeader = Data("SQLite format 3\0".utf8)
        return (try? handle.read(upToCount: expectedHeader.count)) == expectedHeader
    }

    private func databaseDigestKey(for type: CirclemsDataSourceDatabaseType) -> String {
        "CirclemsDataSource.databaseDownloaded.gzippedDigest.\(AppEnvironment.current.storageNamespace).comiket-\(comiketId).\(type.rawValue)"
    }

    private var extractedImagesKey: String {
        "CirclemsDataSource.extractedAndCachedCircleImages.\(AppEnvironment.current.storageNamespace).comiket-\(comiketId).digest-\(databases.image.digest)"
    }
    
    private func initDatabaseConnections() async throws {
        // Initialize the SQLite databases
        var configuration = Configuration()
        configuration.readonly = true
        
        NSLog("Initializing databases at \(databases.main.localPath) and \(databases.image.localPath)...")
        sqliteMain = try DatabasePool(path: databases.main.localPath, configuration: configuration)
        sqliteImage = try DatabasePool(path: databases.image.localPath, configuration: configuration)
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
                throw NSError(domain: "CirclemsDataSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load Comiket info"])
            }
            
            // Save the Cover Image under (cachesDirectory)/(comiketNo)/circlems/cover.png, if it does not exist
            var coverImageURL: URL? = nil
            if let coverImageData = coverImageData {
                coverImageURL = DirectoryManager.shared.cachesFor(comiketId: infoFirst.comiketNo.string, .circlems, .images, createIfNeeded: true)
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
    
    private func extractAndCacheCircleImages() async throws {
        if UserDefaults.standard.bool(forKey: extractedImagesKey) {
            return
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    try FileManager.default.createDirectory(
                        at: DirectoryManager.shared.cachesFor(comiketId: self.comiketId, .circlems, .images)
                            .appendingPathComponent("circles"),
                        withIntermediateDirectories: true, attributes: nil
                    )
                    
                    try self.sqliteImage.read { db in
                        let circleImages = try CirclemsImageSchema.ComiketCircleImage.fetchAll(db)
                        
                        for (i, image) in circleImages.enumerated() {
                            guard let data = image.cutImage else { continue }
                            
                            let url = DirectoryManager.shared.cachesFor(comiketId: self.comiketId, .circlems, .images)
                                .appendingPathComponent("circles")
                                .appendingPathComponent("\(image.id).png")
                            
                            try data.write(to: url)
                            
                            // random 5% possibility
                            if Int.random(in: 0 ..< 20) == 0 {
                                let percentage = ((Double(i) / Double(circleImages.count)) * 100).rounded()
                                DispatchQueue.main.async {
                                    self.readiness = .initializing(state: "Extracting images \(Int(percentage))% (\(i)/\(circleImages.count))...")
                                }
                            }
                        }
                        
                        UserDefaults.standard.set(true, forKey: self.extractedImagesKey)
                        
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func preloadCircles() async throws {
        self.circles = try await self.sqliteMain.read { db in
            try CirclemsDataSchema.ComiketCircleWC.fetchAll(db)
        }
    }
    
    func getCircles() async -> [CirclemsDataSchema.ComiketCircleWC] {
        return self.circles
    }
    
    func searchCircles(_ keyword: String) -> [CirclemsDataSchema.ComiketCircleWC] {
        let keywords = keyword.split(separator: " ")
        
        return self.circles.filter { circle in
            let penName = circle.penName ?? ""
            let circleName = circle.circleName ?? ""
            let description = circle.description ?? ""
                
            return keywords.any { keyword in
                penName.contains(keyword) || circleName.contains(keyword) || description.contains(keyword)
            }
        }
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
    
    private func getCircleImageFromCache(circleId: Int) -> Data? {
        do {
            let url = DirectoryManager.shared.cachesFor(comiketId: comiket.number.string, .circlems, .images)
                .appendingPathComponent("circles")
                .appendingPathComponent("\(circleId).png")
            
            return try Data(contentsOf: url)
        } catch {
            return nil
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
        if let image = self.getCircleImageFromCache(circleId: circleId) {
            return image
        }
        
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCircleImage.fetchOne(db, sql: "SELECT * FROM ComiketCircleImage WHERE comiketNo = ? AND id = ?", arguments: [self.comiketId, circleId])
            }
            
            return image?.cutImage
        } catch {
            return nil
        }
    }
    
    func getCommonImage(name: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [self.comiketId, name])
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    func getFloorMap(layer: FloorMapLayer, day: Int, areaFileNameFragment: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        let name = ["L", layer.fileNameFragment, "\(day)", areaFileNameFragment].joined()
        
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [self.comiketId, name])
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    func cleanAllCaches() {
        UserDefaults.standard.removeObject(forKey: extractedImagesKey)
        UserDefaults.standard.removeObject(forKey: databaseDigestKey(for: databases.main.type))
        UserDefaults.standard.removeObject(forKey: databaseDigestKey(for: databases.image.type))
        try? DirectoryManager.shared.removeCachesFor(comiketId: comiketId)
    }
}
