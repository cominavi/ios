//
//  DirectoryManager.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import CryptoKit
import Foundation
import os

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

/// Moves Circle.ms-mode and demo catalog files out of purgeable Caches into
/// Application Support, where the system never deletes them on its own. The
/// moved directory is excluded from iCloud and device backups because it can
/// always be downloaded again; user data next to it (`users/`) stays backed up.
enum CatalogDataStorage {
    /// Returns `<applicationSupportEventDirectory>/<scope>` after moving any
    /// files left in `<legacyCachesEventDirectory>/<scope>` by older builds.
    /// Files already in Application Support win over legacy copies.
    static func prepareScopeDirectory(
        _ scope: String,
        applicationSupportEventDirectory: URL,
        legacyCachesEventDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationSupportEventDirectory
            .appendingPathComponent(scope, isDirectory: true)
        let legacyDirectory = legacyCachesEventDirectory
            .appendingPathComponent(scope, isDirectory: true)
        try fileManager.createDirectory(
            at: applicationSupportEventDirectory,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            try merge(legacyDirectory, into: directory, fileManager: fileManager)
            try? fileManager.removeItem(at: legacyDirectory)
            removeIfEmpty(legacyCachesEventDirectory, fileManager: fileManager)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
        return directory
    }

    static func excludeFromBackup(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Moves `source` to `destination`. Both live in the same app container,
    /// so each move is a rename and never copies catalog bytes.
    private static func merge(
        _ source: URL,
        into destination: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        guard isDirectory(source, fileManager: fileManager),
              isDirectory(destination, fileManager: fileManager)
        else { return }
        for child in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            try merge(
                child,
                into: destination.appendingPathComponent(child.lastPathComponent),
                fileManager: fileManager
            )
        }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func removeIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty
        else { return }
        try? fileManager.removeItem(at: directory)
    }
}

final class DirectoryManager: Sendable {
    static let shared = DirectoryManager()

    enum CatalogDataScope: String, CaseIterable {
        case circlems
    }

    enum CatalogDataType: String {
        case images
        case databases
        case downloads
        case metadata
    }

    /// Event shards whose catalog data has been moved out of Caches during
    /// this process, so the check runs once per shard.
    private let preparedCatalogShards = OSAllocatedUnfairLock<Set<String>>(initialState: [])

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
            AppEnvironment.current.storageDirectoryComponents.reduce(
                cachesDirectory.appendingPathComponent("environments", isDirectory: true)
            ) { $0.appendingPathComponent($1, isDirectory: true) }
        createDirectoryIfNeeded(at: url)
        return url
    }

    var environmentApplicationSupportDirectory: URL {
        let url =
            AppEnvironment.current.storageDirectoryComponents.reduce(
                applicationSupportDirectory.appendingPathComponent("environments", isDirectory: true)
            ) { $0.appendingPathComponent($1, isDirectory: true) }
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

    /// Downloaded catalog databases, derived indexes and images for one event.
    /// They live in Application Support (excluded from backup) so the system
    /// cannot purge them under storage pressure the way it purges Caches.
    func catalogDataFor(
        eventID: Int,
        comiketId: String,
        _ scope: CatalogDataScope,
        _ type: CatalogDataType,
        createIfNeeded: Bool = false
    ) -> URL {
        let url = catalogScopeDirectory(eventID: eventID, comiketId: comiketId, scope)
            .appendingPathComponent(type.rawValue, isDirectory: true)
        if createIfNeeded {
            createDirectoryIfNeeded(at: url)
        }
        return url
    }

    /// Removes the downloaded catalog data for one event, including any copy
    /// an older build left in Caches. User data in the same event shard
    /// (favorites, plans) is not touched.
    func removeCatalogDataFor(eventID: Int, comiketId: String) throws {
        let fileManager = FileManager.default
        let directories = CatalogDataScope.allCases.flatMap { scope in
            [
                eventDirectory(
                    in: environmentApplicationSupportDirectory,
                    eventID: eventID,
                    comiketId: comiketId
                ),
                eventDirectory(
                    in: environmentCachesDirectory,
                    eventID: eventID,
                    comiketId: comiketId
                ),
            ].map { $0.appendingPathComponent(scope.rawValue, isDirectory: true) }
        }
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func catalogScopeDirectory(
        eventID: Int,
        comiketId: String,
        _ scope: CatalogDataScope
    ) -> URL {
        let eventDirectory = eventDirectory(
            in: environmentApplicationSupportDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        let directory = eventDirectory.appendingPathComponent(scope.rawValue, isDirectory: true)
        let shardKey = directory.path
        let alreadyPrepared = preparedCatalogShards.withLock { prepared in
            prepared.contains(shardKey)
        }
        guard !alreadyPrepared else { return directory }
        let legacyEventDirectory = self.eventDirectory(
            in: environmentCachesDirectory,
            eventID: eventID,
            comiketId: comiketId
        )
        do {
            // The lock covers the move so two concurrent downloads (main and
            // image databases) cannot race on the same rename.
            try preparedCatalogShards.withLock { prepared in
                guard !prepared.contains(shardKey) else { return }
                _ = try CatalogDataStorage.prepareScopeDirectory(
                    scope.rawValue,
                    applicationSupportEventDirectory: eventDirectory,
                    legacyCachesEventDirectory: legacyEventDirectory
                )
                prepared.insert(shardKey)
            }
        } catch {
            NSLog("Could not move C\(comiketId) catalog data out of Caches: \(error)")
        }
        return directory
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
