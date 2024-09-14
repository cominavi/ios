//
//  Extensions+URL.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

extension URL {
    /// writeIfNotExists: Write the data to the URL if the file does not exist. Creates intermediate directories if needed.
    func writeIfNotExists(_ data: Data) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: self)
        }
    }
}
