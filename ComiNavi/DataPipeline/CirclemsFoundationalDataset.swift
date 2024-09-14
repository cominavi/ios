//
//  CirclemsFoundationalDataset.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

typealias UFDSchema = UnifiedFoundationalDatasetSchema
typealias Comiket = UnifiedFoundationalDatasetSchema.Comiket

enum UnifiedFoundationalDatasetSchema {
    struct Comiket: Identifiable, Hashable {
        /// Currently equals to the numerical representation of `number`, but may be changed in the future
        /// > Example: `"104"`
        var id: String
    
        /// > Example: `104`
        var number: Int
        
        /// > Example: `"コミックマーケット104"`
        var name: String
        
        /// > Example: (a URL pointing to a local PNG image)
        var cover: URL?
        
        /// Sections
        var days: [Day]
    }
    
    struct Day: Identifiable, Hashable {
        /// The parent comiket
        var comiket: Comiket
        
        /// Currently equals to `[comiketId, dayIndex].joined(separator: "_")`
        var id: String
        
        /// Temporal Property: The day index of the section. The dayIndex will be 1-based.
        /// > Example:
        /// > - 1日目 -> `1`
        /// > - 2日目 -> `2`
        /// > - 3日目 -> `3`
        var dayIndex: Int
        
        /// Temporal Property: The date components of the section. The DateComponents will be defining the year, month, day and timeZone of the section.
        var date: DateComponents
        
        var halls: [DayHall]
    }
    
    struct DayHall: Identifiable, Hashable {
        /// The parent day
        var day: Day
        
        /// Currently equals to `[comiketId, dayIndex, mapName].joined(separator: "_")`
        var id: String
        
        /// > Example: `東123`
        var name: String
        
        /// Spacial Property: The mapName of the section. Current possible values are: `"E123"`, `"E456"`, `"E7"`, `"W12"`
        var mapName: String
        
        var externalMapId: Int
        
        var externalCorrespondingFloorId: Int
        
        var areas: [DayHallArea]
    }
    
    struct DayHallArea: Identifiable, Hashable {
        /// The parent hall
        var hall: DayHall
        
        /// Currently equals to `[comiketId, dayIndex, mapName, externalAreaId].joined(separator: "_")`
        var id: String
        
        /// > Example: `東１２３壁`
        var name: String
        
        var externalAreaId: Int
    }
}
