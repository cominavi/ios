//
//  Extensions+Array.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/17/24.
//

import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
