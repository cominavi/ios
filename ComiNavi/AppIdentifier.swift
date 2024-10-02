//
//  AppIdentifier.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/20/24.
//

import Foundation

enum AppIdentifier {
    static let assetsAppGroup = "group.net.cominavi.cominavi.internally-shared"

    static func of(entityName: String) -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return "\(bundleIdentifier).\(entityName)"
    }
}
