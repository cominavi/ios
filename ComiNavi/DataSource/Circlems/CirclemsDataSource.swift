//
//  CirclemsDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Foundation
import GRDB
import Gzip

enum Readiness: Equatable {
    case uninitialized
    case downloading(progressPercentage: Double)
    case initializing(state: String)
    case ready
    case error(error: String)
}

extension Readiness {
    var progressPercentage: Double? {
        switch self {
        case .downloading(let progress):
            return progress
        default:
            return nil
        }
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

final class JapaneseTokenizer: FTS5WrapperTokenizer {
    static let name = "cominavi_ja_tokenizer"
    var wrappedTokenizer: any GRDB.FTS5Tokenizer
    
    // Kana to Romaji mapping
    private let kanaToRomaji: [String: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "を": "wo", "ん": "n"
    ]
    
    func accept(token: String, flags: GRDB.FTS5TokenFlags, for tokenization: GRDB.FTS5Tokenization, tokenCallback: (String, GRDB.FTS5TokenFlags) throws -> Void) throws {
        // Convert the token from Kana to Romaji
        var romajiToken = ""
        for character in token {
            if let romaji = kanaToRomaji[String(character)] {
                romajiToken += romaji
            } else {
                romajiToken += String(character) // If no mapping, keep the original character
            }
        }
        
        // Pass the converted token to the callback
        try tokenCallback(romajiToken, flags)
    }
    
    init(db: GRDB.Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
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

struct CirclemsDataSourceDatabaseMetadata {
    var digest: String
    var remoteUrl: String
    var localPath: String
}

extension CirclemsDataSourceDatabaseMetadata {
    var localGzippedPath: String {
        return localPath + ".gz"
    }
}

struct CirclemsDataSourceDatabases {
    let main: CirclemsDataSourceDatabaseMetadata
    let image: CirclemsDataSourceDatabaseMetadata
}

class CirclemsDataSource: ObservableObject {
    private let databases: CirclemsDataSourceDatabases?
    
    private var sqliteMain: DatabasePool!
    private var sqliteImage: DatabasePool!
    
    public var comiket: Comiket!
    
    @Published var readiness: Readiness = .uninitialized
    
    var circles: [CirclemsDataSchema.ComiketCircleWC] = []
    
    init(params: CirclemsDataSourceInitializationParams, comiketId: String) {
        self.databases = CirclemsDataSourceDatabases(
            main: CirclemsDataSourceDatabaseMetadata(digest: params.main.digest, remoteUrl: params.main.remoteUrl, localPath: DirectoryManager.shared.cachesFor(comiketId: comiketId, .circlems, .databases).appendingPathComponent("main.sqlite").path),
            image: CirclemsDataSourceDatabaseMetadata(digest: params.image.digest, remoteUrl: params.image.remoteUrl, localPath: DirectoryManager.shared.cachesFor(comiketId: comiketId, .circlems, .databases).appendingPathComponent("image.sqlite").path)
        )
        
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
        NSLog("Downloading databases...")
        guard let databases = self.databases else {
            throw NSError(domain: "CirclemsDataSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No databases to download"])
        }
            
        let downloads = [databases.main, databases.image].map { metadata in
            Task {
                try await withCheckedThrowingContinuation { continuation in
                    if FileManager.default.fileExists(atPath: metadata.localGzippedPath),
                       let localDataDigest = URL(fileURLWithPath: metadata.localGzippedPath).md5Digest(),
                       localDataDigest.hexEncodedString() == metadata.digest.lowercased()
                    {
                        NSLog("Database \(metadata.localGzippedPath) already exists and is valid. Skipping download. (Digest: \(localDataDigest.hexEncodedString()))")
                        return continuation.resume()
                    }
                    
                    let url = URL(string: metadata.remoteUrl)!
                    let request = URLRequest(url: url)
                    let task = URLSession.shared.downloadTask(with: request) { url, _, error in
                        if let error = error {
                            NSLog("Failed to download \(metadata.remoteUrl): \(error.localizedDescription)")
                            continuation.resume(throwing: NSError(domain: "CirclemsDataSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(metadata.remoteUrl): \(error.localizedDescription)"]))
                        } else if let url = url {
                            do {
                                try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: metadata.localGzippedPath))
                                // Decompress the file
                                let data = try Data(contentsOf: URL(fileURLWithPath: metadata.localGzippedPath)).gunzipped()
                                try data.write(to: URL(fileURLWithPath: metadata.localPath))
                                continuation.resume()
                            } catch {
                                NSLog("Failed to move downloaded file to \(metadata.localGzippedPath): \(error.localizedDescription)")
                                continuation.resume(throwing: NSError(domain: "CirclemsDataSource", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to move downloaded file to \(metadata.localGzippedPath): \(error.localizedDescription)"]))
                            }
                        }
                    }
                    
                    task.progress.observe(\.fractionCompleted) { progress, _ in
                        print(metadata.remoteUrl, progress.fractionCompleted)
                    }
                    
                    task.resume()
                }
            }
        }
            
        // Wait for all downloads to complete
        try await withThrowingTaskGroup(of: Void.self) { group in
            for download in downloads {
                group.addTask {
                    try await download.value
                }
            }
                
            var completedDownloads = 0
            for try await _ in group {
                completedDownloads += 1
                await self.updateOverallProgress(progress: 1.0, totalDownloads: downloads.count)
            }
        }
    }
        
    @MainActor
    private func updateOverallProgress(progress: Double, totalDownloads: Int) {
        let currentProgress = (self.readiness.progressPercentage ?? 0) / 100.0
        let newProgress = (currentProgress * Double(totalDownloads - 1) + progress) / Double(totalDownloads)
        self.readiness = .downloading(progressPercentage: newProgress * 100)
    }
    
    private func initDatabaseConnections() async throws {
        // Initialize the SQLite databases
        var configuration = Configuration()
        configuration.readonly = true
        
        guard let databases = databases else {
            throw NSError(domain: "CirclemsDataSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No databases to initialize"])
        }
        
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
        if UserDefaults.standard.bool(forKey: "CirclemsDataSource.extractAndCacheCircleImages") {
            return
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    UserDefaults.standard.set(true, forKey: "CirclemsDataSource.extractAndCacheCircleImages")
                    
                    try self.sqliteImage.read { db in
                        let circleImages = try CirclemsImageSchema.ComiketCircleImage.fetchAll(db)
                        
                        for (i, image) in circleImages.enumerated() {
                            guard let data = image.cutImage else { continue }
                            
                            let url = DirectoryManager.shared.cachesFor(comiketId: image.comiketNo.string, .circlems, .images, createIfNeeded: true)
                                .appendingPathComponent("circles")
                                .appendingPathComponent("\(image.id).png")
                            
                            try url.writeIfNotExists(data)
                            
                            // random 5% possibility
                            if Int.random(in: 0 ..< 20) == 0 {
                                let percentage = ((Double(i) / Double(circleImages.count)) * 100).rounded()
                                DispatchQueue.main.async {
                                    self.readiness = .initializing(state: "Extracting images \(Int(percentage))% (\(i)/\(circleImages.count))...")
                                }
                            }
                        }
                        
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
                try CirclemsImageSchema.ComiketCircleImage.fetchOne(db, sql: "SELECT * FROM ComiketCircleImage WHERE comiketNo = ? AND id = ?", arguments: [self.comiket.number, circleId])
            }
            
            return image?.cutImage
        } catch {
            return nil
        }
    }
    
    func getCommonImage(name: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [self.comiket.number, name])
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
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = ? AND name = ?", arguments: [self.comiket.number, name])
            }
            
            return image
        } catch {
            return nil
        }
    }
}
