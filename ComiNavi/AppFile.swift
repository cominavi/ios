//
//  AppFile.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/20/24.
//

import Foundation

enum AppFile {
    static func comiket(_ comiketId: String) -> AppFileComiket {
        return AppFileComiket(comiketId: comiketId)
    }
}

struct AppFileComiket {
    let comiketId: String
}
