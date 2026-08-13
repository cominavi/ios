import Foundation

struct CominaviFavorite: Codable, Equatable, Sendable {
    let publicCircleID: Int
    let color: BookmarkColor
    let notificationsEnabled: Bool
}

struct PendingCanonicalFavoriteMutation: Codable, Equatable, Sendable {
    let eventNumber: Int
    let mutationID: UUID
    let baseRevision: Int
    let favorites: [CominaviFavorite]
}

/// An immutable canonical write the service definitively rejected. Keeping the
/// exact request makes the failure inspectable/exportable without allowing it
/// to remain at the head of the active outbox.
struct QuarantinedCanonicalFavoriteMutation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { mutation.mutationID }

    let mutation: PendingCanonicalFavoriteMutation
    let code: String
    let message: String
    let affectedPublicCircleIDs: [Int]
    let rejectedAt: Date
}

struct CominaviFavoriteSnapshot: Equatable, Sendable {
    let eventNumber: Int
    let revision: Int
    let favorites: [CominaviFavorite]
}

struct RemoteFavorite: Equatable, Sendable {
    let publicCircleID: Int
    let updateID: Int
    let color: BookmarkColor
    let memo: String
}

protocol FavoriteRemoteStoring: Sendable {
    func favorites(eventID: Int) async throws -> [RemoteFavorite]
    func add(_ bookmark: MapBookmark) async throws
    func update(_ bookmark: MapBookmark) async throws
    func delete(publicCircleID: Int) async throws
}

struct CirclemsFavoriteRemoteStore: FavoriteRemoteStoring {
    func favorites(eventID: Int) async throws -> [RemoteFavorite] {
        var page = 1
        var result: [RemoteFavorite] = []

        while page <= 100 {
            let response = try await CirclemsAPI.getFavoriteCircles(eventId: eventID, page: page)
            let favorites = response.response.list.compactMap { entry -> RemoteFavorite? in
                guard let color = BookmarkColor(rawValue: entry.favorite.color) else { return nil }
                return RemoteFavorite(
                    publicCircleID: entry.circle.wcid,
                    updateID: entry.circle.updateId,
                    color: color,
                    memo: entry.favorite.memo
                )
            }
            result.append(contentsOf: favorites)

            guard response.response.list.count == 1_000 else { break }
            page += 1
        }
        return result
    }

    func add(_ bookmark: MapBookmark) async throws {
        _ = try await CirclemsAPI.addFavorite(
            wcid: bookmark.publicCircleID,
            color: bookmark.color.rawValue,
            memo: bookmark.memo
        )
    }

    func update(_ bookmark: MapBookmark) async throws {
        _ = try await CirclemsAPI.editFavorite(
            wcid: bookmark.publicCircleID,
            color: bookmark.color.rawValue,
            memo: bookmark.memo
        )
    }

    func delete(publicCircleID: Int) async throws {
        _ = try await CirclemsAPI.deleteFavorite(wcid: publicCircleID)
    }
}

actor BookmarkSyncCoordinator {
    private let eventID: Int
    private let eventNumber: Int
    private let catalog: any MapCatalog
    private let localStore: any UserPlanStoring
    private let serviceFavoriteSync: any CominaviFavoriteSyncing
    private let circlemsImport: (any CirclemsFavoriteImportServicing)?
    private let circlemsMirror: (any FavoriteRemoteStoring)?
    private var requestedRevision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var worker: Task<Void, Error>?

    init(
        eventID: Int,
        eventNumber: Int,
        catalog: any MapCatalog,
        localStore: any UserPlanStoring,
        serviceFavoriteSync: any CominaviFavoriteSyncing,
        circlemsImport: (any CirclemsFavoriteImportServicing)? = nil,
        circlemsMirror: (any FavoriteRemoteStoring)? = nil
    ) {
        self.eventID = eventID
        self.eventNumber = eventNumber
        self.catalog = catalog
        self.localStore = localStore
        self.serviceFavoriteSync = serviceFavoriteSync
        self.circlemsImport = circlemsImport
        self.circlemsMirror = circlemsMirror
    }

    func sync() async throws {
        requestedRevision &+= 1

        if worker == nil {
            worker = Task { [weak self] in
                guard let self else { return }
                try await self.drainSyncQueue()
            }
        }

        guard let worker else { return }
        try await worker.value
    }

    private func drainSyncQueue() async throws {
        while completedRevision < requestedRevision {
            let targetRevision = requestedRevision

            do {
                try await performSync()
            } catch {
                worker = nil
                throw error
            }

            completedRevision = targetRevision
        }

        worker = nil
    }

    private func performSync() async throws {
        if let pending = try await localStore.pendingCanonicalFavoriteMutation(
            eventNumber: eventNumber
        ) {
            do {
                try await sendAndAcknowledge(pending)
            } catch CominaviServiceError.revisionConflict {
                // Idempotency replay is evaluated before revision CAS. A 409
                // therefore proves this immutable request did not commit.
                try await localStore.discardCanonicalFavoriteMutation(
                    eventNumber: eventNumber,
                    mutationID: pending.mutationID
                )
            } catch {
                guard let rejection = terminalRejection(error) else { throw error }
                try await quarantine(pending, rejection: rejection)
            }
        }

        try await reconcileCanonicalFavorites(allowConflictRebase: true)

        if let circlemsMirror {
            do {
                try await mirrorToCirclems(
                    Array((try await localStore.allBookmarks(eventNumber: eventNumber))
                        .filter { $0.syncState == .synced }),
                    remoteStore: circlemsMirror
                )
            } catch {
                // Circle.ms is optional compatibility. It cannot roll back or
                // poison the canonical ComiNavi result.
                NSLog("Circle.ms favorite mirror failed: \(error)")
            }
        }
    }

    private func reconcileCanonicalFavorites(allowConflictRebase: Bool) async throws {
        let canonical = try await serviceFavoriteSync.favoriteSnapshot(eventNumber: eventNumber)
        guard canonical.eventNumber == eventNumber else {
            throw CominaviServiceError.invalidResponse
        }
        await importInitialCirclemsFavoritesIfNeeded(canonicalRevision: canonical.revision)
        let remoteIDs = Set(canonical.favorites.map(\.publicCircleID))
        let existingLocal = try await localStore.allBookmarks(eventNumber: eventNumber)
        let pendingIDs = Set(existingLocal.filter { $0.syncState != .synced }.map(\.publicCircleID))

        let locations = try await catalog.bookmarkLocations(
            publicCircleIDs: canonical.favorites.map(\.publicCircleID)
        )
        let locationByPublicID = Dictionary(
            uniqueKeysWithValues: locations.map { ($0.publicCircleID, $0) }
        )
        let existingByPublicID = Dictionary(
            uniqueKeysWithValues: existingLocal.map { ($0.publicCircleID, $0) }
        )

        for remoteFavorite in canonical.favorites {
            guard !pendingIDs.contains(remoteFavorite.publicCircleID),
                  let location = locationByPublicID[remoteFavorite.publicCircleID]
            else { continue }
            try await localStore.upsert(MapBookmark(
                eventNumber: eventNumber,
                publicCircleID: remoteFavorite.publicCircleID,
                catalogCircleID: location.catalogCircleID,
                updateID: location.updateID,
                day: location.day,
                mapID: location.mapID,
                tableID: location.tableID,
                subspace: location.subspace,
                color: remoteFavorite.color,
                memo: existingByPublicID[remoteFavorite.publicCircleID]?.memo ?? "",
                modifiedAt: Date(),
                syncState: .synced
            ))
        }

        for local in existingLocal
        where local.syncState == .synced && !remoteIDs.contains(local.publicCircleID) {
            try await localStore.remove(
                eventNumber: eventNumber,
                publicCircleID: local.publicCircleID
            )
        }

        let pendingChanges = try await localStore.pendingChanges(eventNumber: eventNumber)
        guard !pendingChanges.isEmpty else { return }
        var desired = Dictionary(
            uniqueKeysWithValues: canonical.favorites.map { ($0.publicCircleID, $0) }
        )
        for bookmark in pendingChanges {
            switch bookmark.syncState {
            case .pendingDelete:
                desired[bookmark.publicCircleID] = nil
            case .pendingUpsert:
                desired[bookmark.publicCircleID] = CominaviFavorite(
                    publicCircleID: bookmark.publicCircleID,
                    color: bookmark.color,
                    notificationsEnabled: true
                )
            case .synced, .quarantined:
                break
            }
        }
        let mutation = PendingCanonicalFavoriteMutation(
            eventNumber: eventNumber,
            mutationID: UUID(),
            baseRevision: canonical.revision,
            favorites: desired.values.sorted { $0.publicCircleID < $1.publicCircleID }
        )
        // Persist the immutable ID/base/payload before its first network send.
        try await localStore.savePendingCanonicalFavoriteMutation(mutation)
        do {
            try await sendAndAcknowledge(mutation)
        } catch let error as CominaviServiceError {
            switch error {
            case .revisionConflict:
                try await localStore.discardCanonicalFavoriteMutation(
                    eventNumber: eventNumber,
                    mutationID: mutation.mutationID
                )
                guard allowConflictRebase else { throw error }
                try await reconcileCanonicalFavorites(allowConflictRebase: false)
            default:
                guard let rejection = terminalRejection(error) else { throw error }
                try await quarantine(mutation, rejection: rejection)
                // The rejected bookmark rows are no longer active pending
                // changes. Reconcile again so unrelated local edits are not
                // stranded behind this terminal request.
                try await reconcileCanonicalFavorites(allowConflictRebase: allowConflictRebase)
            }
        }
    }

    private func importInitialCirclemsFavoritesIfNeeded(canonicalRevision: Int) async {
        guard canonicalRevision == 0, let circlemsImport else { return }
        do {
            let hasCompleted = try await localStore.hasCompletedInitialCirclemsFavoriteImport(
                eventNumber: eventNumber
            )
            guard !hasCompleted else { return }

            var itemsByPublicCircleID: [Int: CirclemsFavoriteImportItem] = [:]
            var cursor: String?
            var seenCursors: Set<String> = []
            for _ in 0..<100 {
                let page = try await circlemsImport.circlemsFavoriteImportPage(
                    eventNumber: eventNumber,
                    cursor: cursor
                )
                guard page.eventNumber == eventNumber else {
                    throw CominaviServiceError.invalidResponse
                }
                for item in page.items {
                    itemsByPublicCircleID[item.wcID] = item
                }
                guard let nextCursor = page.nextCursor else {
                    cursor = nil
                    break
                }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CominaviServiceError.invalidResponse
                }
                cursor = nextCursor
            }
            guard cursor == nil else { throw CominaviServiceError.invalidResponse }

            let locations = try await catalog.bookmarkLocations(
                publicCircleIDs: Array(itemsByPublicCircleID.keys)
            )
            let locationByPublicID = Dictionary(
                uniqueKeysWithValues: locations.map { ($0.publicCircleID, $0) }
            )
            let bookmarks = itemsByPublicCircleID.values.compactMap { item -> MapBookmark? in
                guard let color = BookmarkColor(rawValue: item.color),
                      let location = locationByPublicID[item.wcID]
                else { return nil }
                return MapBookmark(
                    eventNumber: eventNumber,
                    publicCircleID: item.wcID,
                    catalogCircleID: location.catalogCircleID,
                    updateID: location.updateID,
                    day: location.day,
                    mapID: location.mapID,
                    tableID: location.tableID,
                    subspace: location.subspace,
                    color: color,
                    memo: item.memo,
                    modifiedAt: Date(),
                    syncState: .pendingUpsert
                )
            }
            _ = try await localStore.completeInitialCirclemsFavoriteImport(
                eventNumber: eventNumber,
                bookmarks: bookmarks,
                completedAt: Date()
            )
        } catch {
            // Provider import is a one-time compatibility convenience. A provider
            // or network failure must not block ComiNavi's canonical favorites.
            NSLog("Initial Circle.ms favorite import failed: \(error)")
        }
    }

    private struct TerminalRejection: Sendable {
        let code: String
        let message: String
        let affectedPublicCircleIDs: [Int]
    }

    private func terminalRejection(_ error: Error) -> TerminalRejection? {
        guard let error = error as? CominaviServiceError else { return nil }
        switch error {
        case .favoriteMutationRejected(let code, let message, let invalidPublicCircleIDs):
            return TerminalRejection(
                code: code,
                message: message,
                affectedPublicCircleIDs: invalidPublicCircleIDs
            )
        case .server(let code, let message, let status)
        where status == 400 || status == 404 || status == 422:
            return TerminalRejection(
                code: code,
                message: message,
                affectedPublicCircleIDs: []
            )
        default:
            return nil
        }
    }

    private func quarantine(
        _ mutation: PendingCanonicalFavoriteMutation,
        rejection: TerminalRejection
    ) async throws {
        _ = try await localStore.quarantineCanonicalFavoriteMutation(
            mutation,
            code: rejection.code,
            message: rejection.message,
            affectedPublicCircleIDs: rejection.affectedPublicCircleIDs,
            rejectedAt: Date()
        )
    }

    private func sendAndAcknowledge(
        _ mutation: PendingCanonicalFavoriteMutation
    ) async throws {
        let result = try await serviceFavoriteSync.replaceFavorites(
            eventNumber: mutation.eventNumber,
            baseRevision: mutation.baseRevision,
            mutationID: mutation.mutationID,
            favorites: mutation.favorites
        )
        guard result.eventNumber == mutation.eventNumber,
              result.revision > mutation.baseRevision
        else { throw CominaviServiceError.invalidResponse }
        try await localStore.acknowledgeCanonicalFavoriteMutation(mutation)
    }

    private func mirrorToCirclems(
        _ bookmarks: [MapBookmark],
        remoteStore: any FavoriteRemoteStoring
    ) async throws {
        let remote = try await remoteStore.favorites(eventID: eventID)
        let remoteIDs = Set(remote.map(\.publicCircleID))
        for bookmark in bookmarks {
            if remoteIDs.contains(bookmark.publicCircleID) {
                try await remoteStore.update(bookmark)
            } else {
                try await remoteStore.add(bookmark)
            }
        }
        // Never delete provider favorites without provider-origin ownership
        // provenance. An unrelated Circle.ms row is not a mirror tombstone.
    }

    #if DEBUG
        func syncQueueSnapshot() -> (requested: UInt64, completed: UInt64, isRunning: Bool) {
            (requestedRevision, completedRevision, worker != nil)
        }
    #endif
}

#if DEBUG
    actor FixtureFavoriteRemoteStore: FavoriteRemoteStoring {
        private var stored: [Int: RemoteFavorite] = [:]

        func favorites(eventID: Int) async throws -> [RemoteFavorite] {
            Array(stored.values)
        }

        func add(_ bookmark: MapBookmark) async throws {
            stored[bookmark.publicCircleID] = RemoteFavorite(
                publicCircleID: bookmark.publicCircleID,
                updateID: bookmark.updateID ?? bookmark.catalogCircleID,
                color: bookmark.color,
                memo: bookmark.memo
            )
        }

        func update(_ bookmark: MapBookmark) async throws {
            try await add(bookmark)
        }

        func delete(publicCircleID: Int) async throws {
            stored[publicCircleID] = nil
        }
    }
#endif
