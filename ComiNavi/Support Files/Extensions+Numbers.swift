//
//  Extensions+Numbers.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Foundation

extension Int64 {
    var byteSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension Double {
    var byteSizeString: String {
        return Int64(self).byteSizeString
    }
    
    func percentString(decimalPlaces: Int = 1) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = decimalPlaces
        return formatter.string(from: NSNumber(value: self))!
    }
}
