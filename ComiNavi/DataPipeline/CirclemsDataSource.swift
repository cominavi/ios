//
//  CirclemsDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Foundation
import GRDB

enum Readiness {
    case uninitialized
//    case downloading(progressPercentage: Double)
    case initializing
    case ready
    case error(error: Error)
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

typealias Circle = CirclemsDataSchema.ComiketCircleWC

// There are 2 SQLite3 databases located under ComiNavi/DevContent/DB: webcatalog104.db, webcatalog104Image1.db
// These files are the SQLite3 database files for the web catalog
class CirclemsDataSource: ObservableObject {
    static let shared = CirclemsDataSource()
    
    public var sqliteMain: DatabasePool!
    public var sqliteImage: DatabasePool!
    
    public var comiket: Comiket!
    
    @Published var readiness: Readiness = .uninitialized
    
    private init() {
        self.initialize()
    }
    
    private func initialize() {
        self.readiness = .initializing
        
        Task {
            do {
                try await self.initDatabaseConnections()
                try self.preloadUFDData()
                try await self.extractAndCacheCircleImages()
                
                DispatchQueue.main.async {
                    self.readiness = .ready
                }
            } catch {
                DispatchQueue.main.async {
                    self.readiness = .error(error: error)
                }
            }
        }
    }
    
    private func initDatabaseConnections() async throws {
        // Initialize the SQLite databases
        var configuration = Configuration()
        configuration.readonly = true
        
        sqliteMain = try DatabasePool(path: Bundle.main.bundlePath + "/webcatalog104.db", configuration: configuration)
        sqliteImage = try DatabasePool(path: Bundle.main.bundlePath + "/webcatalog104Image1.db", configuration: configuration)
        
//        try await sqliteMain.write { db in
//            try db.create(virtualTable: "ComiketCircleWC_ft", using: FTS5()) { t in
//                t.tokenizer = JapaneseTokenizer.tokenizerDescriptor()
//                t.column("comiketNo")
//                t.column("id")
//                t.column("penName")
//                t.column("circleName")
//                t.column("description")
//            }
//        }
    }

    private func preloadUFDData() throws {
        let coverImage = try self.sqliteImage.read { db in
            try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE name = '0001'")
        }
        
        self.comiket = try self.sqliteMain.read { db in
            // Fetch ComiketInfoWC
            let infoEntries = try CirclemsDataSchema.ComiketInfoWC.fetchAll(db, sql: "SELECT * FROM ComiketInfoWC")
            
            // Fetch ComiketDateWC
            let dateEntries = try CirclemsDataSchema.ComiketDateWC.fetchAll(db, sql: "SELECT * FROM ComiketDateWC")
            
            // Fetch ComiketAreaWC
            let areaEntries = try CirclemsDataSchema.ComiketAreaWC.fetchAll(db, sql: "SELECT * FROM ComiketAreaWC")
            
            // Fetch ComiketFloorWC
            let floorEntries = try CirclemsDataSchema.ComiketFloorWC.fetchAll(db, sql: "SELECT * FROM ComiketFloorWC")
            
            // Fetch ComiketMapWC
            let mapEntries = try CirclemsDataSchema.ComiketMapWC.fetchAll(db, sql: "SELECT * FROM ComiketMapWC")
            
            // Fetch ComiketBlockWC
            let blockEntries = try CirclemsDataSchema.ComiketBlockWC.fetchAll(db, sql: "SELECT * FROM ComiketBlockWC")
            
            let coverImageData = coverImage?.image
            
            guard let infoFirst = infoEntries.first else {
                throw NSError(domain: "CirclemsDataSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load Comiket info"])
            }
            
            // Save the Cover Image under (cachesDirectory)/(comiketNo)/circlems/cover.png, if it does not exist
            var coverImageURL: URL? = nil
            if let coverImageData = coverImageData {
                coverImageURL = DirectoryManager.shared.cachesFor(comiketId: infoFirst.comiketNo, .circlems, .images, createIfNeeded: true)
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
                        
                        for image in circleImages {
                            guard let data = image.cutImage else { continue }
                            
                            let url = DirectoryManager.shared.cachesFor(comiketId: image.comiketNo, .circlems, .images, createIfNeeded: true)
                                .appendingPathComponent("circles")
                                .appendingPathComponent("\(image.id).png")
                            
                            try url.writeIfNotExists(data)
                        }
                        
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func getCircles() async -> [CirclemsDataSchema.ComiketCircleWC] {
        do {
            let circles = try await self.sqliteMain.read { db in
                try CirclemsDataSchema.ComiketCircleWC.fetchAll(db)
            }
            
            return circles
        } catch {
            return []
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
            let url = DirectoryManager.shared.cachesFor(comiketId: comiket.number, .circlems, .images)
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
                // FIXME: comiketNo = 104: hardcoded
                try CirclemsImageSchema.ComiketCircleImage.fetchOne(db, sql: "SELECT * FROM ComiketCircleImage WHERE comiketNo = 104 AND id = ?", arguments: [circleId])
            }
            
            return image?.cutImage
        } catch {
            return nil
        }
    }
    
    func getCommonImage(name: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        do {
            let image = try await self.sqliteImage.read { db in
                // FIXME: comiketNo = 104: hardcoded
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = 104 AND name = ?", arguments: [name])
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    func getFloorMap(layer: FloorMapLayer, day: Int, areaFileNameFragment: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        let name = ["L", layer.fileNameFragment, day.string, areaFileNameFragment].joined()
        print("Fetching \(name)")
        
        do {
            let image = try await self.sqliteImage.read { db in
                // FIXME: comiketNo = 104: hardcoded
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE comiketNo = 104 AND name = ?", arguments: [name])
            }
            
            return image
        } catch {
            return nil
        }
    }
}
