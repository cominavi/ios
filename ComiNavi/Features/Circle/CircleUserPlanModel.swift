import Foundation
import Observation

@MainActor
@Observable
final class CircleUserPlanModel {
    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private(set) var bookmark: MapBookmark?
    private(set) var saveState: SaveState = .idle
    var memo = ""

    private var favoriteOverride: Bool?
    private var colorOverride: BookmarkColor?

    @ObservationIgnored private let circles: [CirclemsDataSchema.ComiketCircleWC]
    @ObservationIgnored private let dataSource: CirclemsDataSource
    @ObservationIgnored private var publicCircleIDsByCatalogID: [Int: Int] = [:]
    @ObservationIgnored private var groupBookmarks: [MapBookmark] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var memoTask: Task<Void, Never>?

    init(
        circle: CirclemsDataSchema.ComiketCircleWC,
        dataSource: CirclemsDataSource
    ) {
        circles = [circle]
        self.dataSource = dataSource
    }

    init(
        circles: [CirclemsDataSchema.ComiketCircleWC],
        dataSource: CirclemsDataSource
    ) {
        precondition(!circles.isEmpty)
        self.circles = circles.sorted { ($0.spaceNoSub ?? 0) < ($1.spaceNoSub ?? 0) }
        self.dataSource = dataSource
    }

    deinit {
        saveTask?.cancel()
        memoTask?.cancel()
    }

    var isFavorite: Bool {
        favoriteOverride ?? (bookmark?.isFavorite == true)
    }

    var selectedColor: BookmarkColor? {
        guard isFavorite else { return nil }
        let color = colorOverride ?? bookmark?.color
        return color?.isFavorite == true ? color : nil
    }

    func load(publicCircleID: Int?) async {
        await load(publicCircleIDsByCatalogID: publicCircleID.map { [circles[0].id: $0] } ?? [:])
    }

    func load(publicCircleIDsByCatalogID: [Int: Int]) async {
        self.publicCircleIDsByCatalogID = publicCircleIDsByCatalogID
        guard !publicCircleIDsByCatalogID.isEmpty else {
            bookmark = nil
            groupBookmarks = []
            memo = ""
            return
        }

        do {
            let stored = try await withThrowingTaskGroup(
                of: MapBookmark?.self,
                returning: [MapBookmark].self
            ) { group in
                for publicCircleID in publicCircleIDsByCatalogID.values {
                    group.addTask { [dataSource] in
                        try await dataSource.userPlanStore.bookmark(
                            eventNumber: dataSource.comiket.number,
                            publicCircleID: publicCircleID
                        )
                    }
                }
                var bookmarks: [MapBookmark] = []
                for try await result in group {
                    if let result { bookmarks.append(result) }
                }
                return bookmarks
            }
            guard !Task.isCancelled else { return }
            groupBookmarks = stored
            bookmark = preferredBookmark(in: stored)
            memo = bookmark?.memo ?? ""
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func toggleFavorite() {
        if isFavorite {
            guard !groupBookmarks.isEmpty else {
                saveTask?.cancel()
                favoriteOverride = nil
                colorOverride = nil
                saveState = .idle
                return
            }
            AppTrack.userIntent(
                .favoriteRemoved,
                data: favoriteIntentData()
            )
            let previousBookmarks = groupBookmarks
            let previousMemo = memo
            let now = Date()
            let pendingDeletes = groupBookmarks.map { stored in
                var stored = stored
                stored.modifiedAt = now
                stored.syncState = .pendingDelete
                return stored
            }
            groupBookmarks = pendingDeletes
            bookmark = preferredBookmark(in: pendingDeletes)
            memo = ""
            favoriteOverride = false
            colorOverride = nil
            persist(
                pendingDeletes,
                restoring: previousBookmarks,
                memo: previousMemo
            )
        } else {
            AppTrack.userIntent(
                .favoriteAdded,
                data: favoriteIntentData(color: .orange)
            )
            createOrUpdate(color: .orange, memo: memo)
        }
    }

    func selectColor(_ color: BookmarkColor) {
        guard color.isFavorite else { return }
        AppTrack.userIntent(
            isFavorite ? .favoriteColorChanged : .favoriteAdded,
            data: favoriteIntentData(color: color)
        )
        createOrUpdate(color: color, memo: memo)
    }

    func memoDidChange() {
        memoTask?.cancel()
        memoTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                self.createOrUpdate(
                    color: self.selectedColor ?? .memoOnly,
                    memo: self.memo
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func flushMemo() {
        memoTask?.cancel()
        guard memo != bookmark?.memo else { return }
        createOrUpdate(color: selectedColor ?? .memoOnly, memo: memo)
    }

    func dismissSaveError() {
        guard case .failed = saveState else { return }
        saveState = .idle
    }

    private func createOrUpdate(color: BookmarkColor, memo: String) {
        saveTask?.cancel()
        let previousBookmarks = groupBookmarks
        favoriteOverride = color.isFavorite
        colorOverride = color.isFavorite ? color : nil
        saveState = .saving
        saveTask = Task { [weak self] in
            guard let self else { return }

            do {
                let updateIDs = self.circles.compactMap(\.updateId)
                let locations = try await self.dataSource.mapCatalog.bookmarkLocations(
                    updateIDs: updateIDs
                )
                try Task.checkCancellation()
                let previousByPublicID = Dictionary(
                    uniqueKeysWithValues: self.groupBookmarks.map { ($0.publicCircleID, $0) }
                )
                let now = Date()
                let updated = try self.circles.compactMap { circle -> MapBookmark? in
                    guard let publicCircleID = self.publicCircleIDsByCatalogID[circle.id],
                        let updateID = circle.updateId
                    else { return nil }
                    if var existing = previousByPublicID[publicCircleID] {
                        existing.color = color
                        existing.memo = memo
                        existing.modifiedAt = now
                        existing.syncState = .pendingUpsert
                        return existing
                    }
                    guard
                        let location = locations.first(where: {
                            $0.catalogCircleID == circle.id
                        })
                    else {
                        throw CircleUserPlanError.locationUnavailable
                    }
                    return MapBookmark(
                        eventNumber: self.dataSource.comiket.number,
                        publicCircleID: publicCircleID,
                        catalogCircleID: circle.id,
                        updateID: updateID,
                        day: location.day,
                        mapID: location.mapID,
                        tableID: location.tableID,
                        subspace: location.subspace,
                        color: color,
                        memo: memo,
                        modifiedAt: now,
                        syncState: .pendingUpsert
                    )
                }
                guard !updated.isEmpty else { throw CircleUserPlanError.locationUnavailable }
                self.groupBookmarks = updated
                self.bookmark = self.preferredBookmark(in: updated)
                try await self.persistLocally(updated)
                self.favoriteOverride = nil
                self.colorOverride = nil
            } catch is CancellationError {
                return
            } catch {
                self.groupBookmarks = previousBookmarks
                self.bookmark = self.preferredBookmark(in: previousBookmarks)
                self.favoriteOverride = nil
                self.colorOverride = nil
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func persist(
        _ bookmarks: [MapBookmark],
        restoring previousBookmarks: [MapBookmark],
        memo previousMemo: String
    ) {
        saveTask?.cancel()
        saveState = .saving
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.persistLocally(bookmarks)
                self.favoriteOverride = nil
                self.colorOverride = nil
            } catch is CancellationError {
                return
            } catch {
                self.groupBookmarks = previousBookmarks
                self.bookmark = self.preferredBookmark(in: previousBookmarks)
                self.memo = previousMemo
                self.favoriteOverride = nil
                self.colorOverride = nil
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func persistLocally(_ bookmarks: [MapBookmark]) async throws {
        try await dataSource.userPlanStore.upsert(bookmarks)
        try Task.checkCancellation()
        saveState = .saved

        guard let coordinator = dataSource.bookmarkSyncCoordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.sync()
            } catch {
                self?.saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func preferredBookmark(in bookmarks: [MapBookmark]) -> MapBookmark? {
        for circle in circles {
            if let bookmark = bookmarks.first(where: { $0.catalogCircleID == circle.id }) {
                return bookmark
            }
        }
        return bookmarks.max { $0.modifiedAt < $1.modifiedAt }
    }

    private func favoriteIntentData(color: BookmarkColor? = nil) -> [String: Any] {
        var data: [String: Any] = [
            "event_number": dataSource.comiket.number,
            "circle_count": publicCircleIDsByCatalogID.count,
            "source": "circle_detail",
        ]
        if let color {
            data["color"] = color.rawValue
        }
        return data
    }
}

private enum CircleUserPlanError: LocalizedError {
    case locationUnavailable

    var errorDescription: String? {
        String(localized: "This circle's map location is unavailable.")
    }
}
