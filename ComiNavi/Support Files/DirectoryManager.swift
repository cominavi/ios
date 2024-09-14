//
//  DirectoryManager.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

class DirectoryManager {
    static let shared = DirectoryManager()

    enum CacheScope: String {
        case circlems
    }

    enum CacheType: String {
        case images
    }

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

    // --

    func cachesFor(comiketId: Int, _ scope: CacheScope, _ type: CacheType, createIfNeeded: Bool = false) -> URL {
        let url = cachesDirectory
            .appendingPathComponent("comiket\(comiketId)", isDirectory: true)
            .appendingPathComponent(scope.rawValue, isDirectory: true)
            .appendingPathComponent(type.rawValue, isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }
}
