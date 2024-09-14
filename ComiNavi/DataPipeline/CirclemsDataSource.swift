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

// There are 2 SQLite3 databases located under ComiNavi/DevContent/DB: webcatalog104.db, webcatalog104Image1.db
// These files are the SQLite3 database files for the web catalog
class CirclemsDataSource: ObservableObject {
    static let shared = CirclemsDataSource()
    
    public var sqliteMain: DatabasePool!
    public var sqliteImage: DatabasePool!
    
    @Published var readiness: Readiness = .uninitialized
    
    private init() {
        self.initialize()
    }
    
    private func initialize() {
        self.readiness = .initializing
        
        do {
            // Initialize the SQLite databases
            var configuration = Configuration()
            configuration.readonly = true
            
            sqliteMain = try DatabasePool(path: Bundle.main.bundlePath + "/webcatalog104.db", configuration: configuration)
            sqliteImage = try DatabasePool(path: Bundle.main.bundlePath + "/webcatalog104Image1.db", configuration: configuration)
            
            self.readiness = .ready
        } catch {
            self.readiness = .error(error: error)
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
    
    func getCircleImage(circleId: Int) async -> Data? {
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCircleImage.fetchOne(db, sql: "SELECT * FROM ComiketCircleImage WHERE id = ?", arguments: [circleId])
            }
            
            return image?.cutImage
        } catch {
            return nil
        }
    }
    
    func getCommonImage(name: String) async -> CirclemsImageSchema.ComiketCommonImage? {
        do {
            let image = try await self.sqliteImage.read { db in
                try CirclemsImageSchema.ComiketCommonImage.fetchOne(db, sql: "SELECT * FROM ComiketCommonImage WHERE name = ?", arguments: [name])
            }
            
            return image
        } catch {
            return nil
        }
    }
}
