//
//  CirclemsDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Alamofire
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

enum CirclemsDataSourceDatabaseType {
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
           let localDataDigest = UserDefaults.standard.string(forKey: "CirclemsDataSource.databaseDownloaded.gzippedDigest.comiket\(comiketId)-\(metadata.type)"),
           localDataDigest.lowercased() == metadata.digest.lowercased()
        {
            return true
        }
        return false
    }
    
    private func downloadDatabase(metadata: CirclemsDataSourceDatabaseMetadata, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws {
        let url = URL(string: metadata.remoteUrl)!
        
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
                        
                        // Decompress the file
                        try data.gunzipped().write(to: URL(fileURLWithPath: metadata.localPath))
                        // Mark the file as downloaded
                        UserDefaults.standard.set(metadata.digest, forKey: "CirclemsDataSource.databaseDownloaded.gzippedDigest.comiket\(self.comiketId)-\(metadata.type)")
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: NSError(domain: "CirclemsDataSource", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to download database from \(metadata.remoteUrl): \(error)"]))
                    }
                }
        }
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
        if UserDefaults.standard.bool(forKey: "CirclemsDataSource.extractedAndCachedCircleImages.databaseDigest.\(self.databases.image.digest).extracted") {
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
                        
                        UserDefaults.standard.set(true, forKey: "CirclemsDataSource.extractedAndCachedCircleImages.databaseDigest.\(self.databases.image.digest).extracted")
                        
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
            
            return keywords.allSatisfy { keyword in
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
        let url = DirectoryManager.shared.cachesFor(comiketId: comiketId, .circlems, .images)
        try? FileManager.default.removeItem(at: url)
        
        UserDefaults.standard.removeObject(forKey: "CirclemsDataSource.extractedAndCachedCircleImages.databaseDigest.\(self.databases.image.digest).extracted")
        UserDefaults.standard.removeObject(forKey: "CirclemsDataSource.databaseDownloaded.gzippedDigest.comiket\(comiketId)-\(self.databases.main.type)")
        UserDefaults.standard.removeObject(forKey: "CirclemsDataSource.databaseDownloaded.gzippedDigest.comiket\(comiketId)-\(self.databases.image.type)")
    }
}
