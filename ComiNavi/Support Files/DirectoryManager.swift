//
//  DirectoryManager.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import CryptoKit
import Foundation

struct EventStorageShard: Hashable, Sendable {
    let eventID: Int
    let comiketID: String

    var eventDirectoryName: String { "event-\(eventID)" }
    var comiketDirectoryName: String { "comiket-\(comiketID)" }

    func directory(in eventsDirectory: URL) -> URL {
        eventsDirectory
            .appendingPathComponent(eventDirectoryName, isDirectory: true)
            .appendingPathComponent(comiketDirectoryName, isDirectory: true)
    }

    func legacyDirectory(in eventsDirectory: URL) -> URL {
        eventsDirectory.appendingPathComponent(comiketDirectoryName, isDirectory: true)
    }

    /// Moves the pre-multi-event layout into its stable event shard. The move is
    /// atomic within the same application container, preserving user SQLite files.
    func resolveDirectory(
        in eventsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let legacyDirectory = legacyDirectory(in: eventsDirectory)
        let directory = directory(in: eventsDirectory)
        guard fileManager.fileExists(atPath: legacyDirectory.path),
            !fileManager.fileExists(atPath: directory.path)
        else {
            return directory
        }

        try fileManager.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: legacyDirectory, to: directory)
        return directory
    }
}

final class DirectoryManager: Sendable {
    static let shared = DirectoryManager()

    enum CacheScope: String {
        case circlems
    }

    enum CacheType: String {
        case images
        case databases
        case downloads
        case metadata
    }

    private init() {}

    private func createDirectoryIfNeeded(at url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(
                    at: url, withIntermediateDirectories: true, attributes: nil)
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

    var environmentCachesDirectory: URL {
        let url =
            cachesDirectory
            .appendingPathComponent("environments", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.build.rawValue, isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.circlems.rawValue, isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }

    var environmentApplicationSupportDirectory: URL {
        let url =
            applicationSupportDirectory
            .appendingPathComponent("environments", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.build.rawValue, isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.circlems.rawValue, isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }

    var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        createDirectoryIfNeeded(at: url)
        return url
    }

    var temporaryDirectory: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }

    // --

    func cachesFor(eventID: Int, comiketId: String) -> URL {
        let url = eventDirectory(
            in: environmentCachesDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        createDirectoryIfNeeded(at: url)
        return url
    }

    func cachesFor(
        eventID: Int,
        comiketId: String,
        _ scope: CacheScope,
        _ type: CacheType,
        createIfNeeded: Bool = false
    ) -> URL {
        let url = eventDirectory(
            in: environmentCachesDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        .appendingPathComponent(scope.rawValue, isDirectory: true)
        .appendingPathComponent(type.rawValue, isDirectory: true)
        if createIfNeeded {
            createDirectoryIfNeeded(at: url)
        }
        return url
    }

    func removeCachesFor(eventID: Int, comiketId: String) throws {
        let url = eventDirectory(
            in: environmentCachesDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func userDataFor(eventID: Int, comiketId: String, userID: Int) -> URL {
        let url = eventDirectory(
            in: environmentApplicationSupportDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        .appendingPathComponent("users", isDirectory: true)
        .appendingPathComponent("user-\(userID)", isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }

    func userDataFor(
        eventID: Int,
        comiketId: String,
        publicUserID: String
    ) throws -> URL {
        let accountDirectoryName = try Self.accountDirectoryName(
            publicUserID: publicUserID
        )
        let url = eventDirectory(
            in: environmentApplicationSupportDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        .appendingPathComponent("users", isDirectory: true)
        .appendingPathComponent(accountDirectoryName, isDirectory: true)
        createDirectoryIfNeeded(at: url)
        return url
    }

    static func accountDirectoryName(publicUserID: String) throws -> String {
        "cominavi-\(try accountScope(publicUserID: publicUserID))"
    }

    /// Removes only durable data derived from one stable ComiNavi public user
    /// ID. Sanitized catalogs are deliberately environment-scoped and remain
    /// available to another authenticated account, so their global directory
    /// is never part of this cleanup.
    func removeApplicationSupportData(
        publicUserID: String,
        in rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let rootDirectory = rootDirectory ?? environmentApplicationSupportDirectory
        let accountScope = try Self.accountScope(publicUserID: publicUserID)
        let accountDirectoryName = "cominavi-\(accountScope)"
        let eventsDirectory = rootDirectory.appendingPathComponent("events", isDirectory: true)

        if let enumerator = fileManager.enumerator(
            at: eventsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            while let candidate = enumerator.nextObject() as? URL {
                guard candidate.lastPathComponent == accountDirectoryName,
                      candidate.deletingLastPathComponent().lastPathComponent == "users"
                else { continue }
                enumerator.skipDescendants()
                if fileManager.fileExists(atPath: candidate.path) {
                    try fileManager.removeItem(at: candidate)
                }
            }
        }

        let exactFiles = [
            rootDirectory.appendingPathComponent("shared-plans-\(accountScope).sqlite"),
            rootDirectory.appendingPathComponent("shared-plans-\(accountScope).sqlite-wal"),
            rootDirectory.appendingPathComponent("shared-plans-\(accountScope).sqlite-shm"),
            rootDirectory.appendingPathComponent("shared-plans-\(accountScope).sqlite-journal"),
            rootDirectory
                .appendingPathComponent("ProfileMutations", isDirectory: true)
                .appendingPathComponent("profile-mutation-\(accountScope).json"),
        ]
        for file in exactFiles where fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    private static func accountScope(publicUserID: String) throws -> String {
        guard !publicUserID.isEmpty,
              publicUserID.utf8.count <= 256
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return SHA256.hash(data: Data(publicUserID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Event IDs are Circle.ms's stable API identifiers. The nested Comiket number
    /// keeps the on-disk layout readable while preventing unrelated catalogs from
    /// ever sharing databases, derived indexes, images, or user plans.
    private func eventDirectory(in root: URL, eventID: Int, comiketId: String) -> URL {
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let shard = EventStorageShard(eventID: eventID, comiketID: comiketId)
        do {
            return try shard.resolveDirectory(in: eventsDirectory)
        } catch {
            // If migration cannot complete, keep using the legacy location. This is
            // especially important for user-authored favorites, which are not caches.
            NSLog("Could not migrate legacy C\(comiketId) event shard: \(error)")
            let legacyDirectory = shard.legacyDirectory(in: eventsDirectory)
            if FileManager.default.fileExists(atPath: legacyDirectory.path) {
                return legacyDirectory
            }
            return shard.directory(in: eventsDirectory)
        }
    }
}
