//
//  DirectoryManager.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

class DirectoryManager {
    static let shared = DirectoryManager()

    private init() {}

    private func createDirectoryIfNeeded(at url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Error creating directory at \(url.path): \(error)")
            }
        }
    }

    var documentsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        createDirectoryIfNeeded(at: url)
        return url
    }

    var libraryDirectory: URL {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        createDirectoryIfNeeded(at: url)
        return url
    }

    var cachesDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        createDirectoryIfNeeded(at: url)
        return url
    }

    var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        createDirectoryIfNeeded(at: url)
        return url
    }

    var temporaryDirectory: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }
}
