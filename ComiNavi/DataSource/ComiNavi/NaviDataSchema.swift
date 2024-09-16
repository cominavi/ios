//
//  NaviDataSchema.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/16/24.
//

import Foundation
import GRDB

enum NaviDataSchema {
    class Circle: Codable, FetchableRecord, PersistableRecord {
        /// Currently equals to `c104_circlems-{circlemsCircleID}`
        var id: String

        /// Circle Name
        var name: String
    }
}
