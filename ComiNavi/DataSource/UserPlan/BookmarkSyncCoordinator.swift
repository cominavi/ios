import Foundation

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
    private let remoteStore: any FavoriteRemoteStoring
    private let serviceFavoriteSync: (any CominaviFavoriteSyncing)?
    private var requestedRevision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var worker: Task<Void, Error>?

    init(
        eventID: Int,
        eventNumber: Int,
        catalog: any MapCatalog,
        localStore: any UserPlanStoring,
        remoteStore: any FavoriteRemoteStoring = CirclemsFavoriteRemoteStore(),
        serviceFavoriteSync: (any CominaviFavoriteSyncing)? = nil
    ) {
        self.eventID = eventID
        self.eventNumber = eventNumber
        self.catalog = catalog
        self.localStore = localStore
        self.remoteStore = remoteStore
        self.serviceFavoriteSync = serviceFavoriteSync
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
        let remoteFavorites = try await remoteStore.favorites(eventID: eventID)
        let remoteIDs = Set(remoteFavorites.map(\.publicCircleID))
        let existingLocal = try await localStore.allBookmarks(eventNumber: eventNumber)
        let pendingIDs = Set(existingLocal.filter { $0.syncState != .synced }.map(\.publicCircleID))

        let locations = try await catalog.bookmarkLocations(
            updateIDs: remoteFavorites.map(\.updateID))
        let locationByUpdateID = Dictionary(
            uniqueKeysWithValues: locations.map { ($0.updateID, $0) })

        for remoteFavorite in remoteFavorites {
            guard !pendingIDs.contains(remoteFavorite.publicCircleID),
                let location = locationByUpdateID[remoteFavorite.updateID]
            else {
                continue
            }

            let bookmark = MapBookmark(
                eventNumber: eventNumber,
                publicCircleID: remoteFavorite.publicCircleID,
                catalogCircleID: location.catalogCircleID,
                updateID: location.updateID,
                day: location.day,
                mapID: location.mapID,
                tableID: location.tableID,
                subspace: location.subspace,
                color: remoteFavorite.color,
                memo: remoteFavorite.memo,
                modifiedAt: Date(),
                syncState: .synced
            )
            try await localStore.upsert(bookmark)
        }

        for local in existingLocal
        where local.syncState == .synced && !remoteIDs.contains(local.publicCircleID) {
            try await localStore.remove(
                eventNumber: eventNumber, publicCircleID: local.publicCircleID)
        }

        let pendingChanges = try await localStore.pendingChanges(eventNumber: eventNumber)
        for var bookmark in pendingChanges {
            switch bookmark.syncState {
            case .pendingDelete:
                try await remoteStore.delete(publicCircleID: bookmark.publicCircleID)
                try await localStore.remove(
                    eventNumber: eventNumber, publicCircleID: bookmark.publicCircleID)
            case .pendingUpsert:
                if remoteIDs.contains(bookmark.publicCircleID) {
                    try await remoteStore.update(bookmark)
                } else {
                    try await remoteStore.add(bookmark)
                }
                bookmark.syncState = .synced
                bookmark.modifiedAt = Date()
                try await localStore.upsert(bookmark)
            case .synced:
                break
            }
        }

        if let serviceFavoriteSync {
            let synchronized = try await localStore.allBookmarks(eventNumber: eventNumber)
            try await serviceFavoriteSync.synchronizeFavorites(
                eventNumber: eventNumber,
                bookmarks: synchronized
            )
        }
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
