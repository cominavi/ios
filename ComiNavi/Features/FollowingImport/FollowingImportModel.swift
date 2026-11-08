import Foundation
import Observation

struct FollowingImportProgressPreview: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case fetching
        case finalizing
    }

    var phase: Phase = .fetching
    var page = 0
    var fetchedCount = 0
    var matchedCircleCount = 0
    var maximumCount = FollowingImportProgress.maximumFollowingCount

    var capacityFraction: Double {
        guard maximumCount > 0 else { return 0 }
        return min(max(Double(fetchedCount) / Double(maximumCount), 0), 1)
    }
}

/// The state needed to reverse one "Favorite all" action. Bookmarks that
/// existed before keep their earlier color and memo; bookmarks that the
/// action created are removed again through the normal pending-delete sync.
struct FollowingBulkFavoriteUndo: Equatable, Identifiable {
    let id = UUID()
    let circleCount: Int
    fileprivate let previousBookmarks: [MapBookmark]
    fileprivate let addedBookmarks: [MapBookmark]
}

@MainActor
@Observable
final class FollowingImportModel {
    enum Activity: Equatable {
        case loading
        case idle
        case importing
        case favoriting
    }

    private(set) var importedCircles: [FollowingImportedCircle] = []
    private(set) var importState: FollowingImportState?
    private(set) var favoriteColorsByPublicID: [Int: BookmarkColor] = [:]
    private(set) var activity: Activity = .loading
    private(set) var errorMessage: String?
    private(set) var progressPreview = FollowingImportProgressPreview()
    /// Set after "Favorite all" succeeds, so the view can confirm the count
    /// and offer Undo until the next favorite or import action.
    private(set) var lastBulkFavorite: FollowingBulkFavoriteUndo?
    var twitterUserName = ""
    var selectedColor: BookmarkColor = .orange

    @ObservationIgnored private let dataSource: CirclemsDataSource
    @ObservationIgnored private let client: FollowingImportAPIClient
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var previewMatchedCircleIDs: Set<Int> = []

    init(
        dataSource: CirclemsDataSource,
        client: FollowingImportAPIClient = FollowingImportAPIClient()
    ) {
        self.dataSource = dataSource
        self.client = client
    }

    var canImport: Bool {
        activity == .idle
            && normalizedTwitterUserName != nil
            && (importState?.nextAllowedAt ?? .distantPast) <= Date()
    }

    var manualImportAvailableAt: Date? {
        guard let date = importState?.nextAllowedAt, date > Date() else { return nil }
        return date
    }

    var importedPublicCircleCount: Int {
        Set(importedCircles.flatMap { $0.publicCircleIDsByCatalogID.values }).count
    }

    func load() async {
        defer { activity = .idle }

        do {
            importState = try await dataSource.userPlanStore.followingImportState(
                eventNumber: dataSource.comiket.number
            )
            if twitterUserName.isEmpty {
                twitterUserName = importState?.twitterUserName ?? ""
            }
            try await reloadImportedCircles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importNow() {
        guard let userName = normalizedTwitterUserName, canImport else { return }
        AppTrack.userIntent(
            .followingImportStarted,
            data: ["event_number": dataSource.comiket.number]
        )
        activity = .importing
        errorMessage = nil
        lastBulkFavorite = nil
        progressPreview = FollowingImportProgressPreview()
        previewMatchedCircleIDs.removeAll(keepingCapacity: true)
        activityTask = Task { [weak self] in
            await Task.yield()
            await self?.performImport(userName: userName)
        }
    }

    private func performImport(userName: String) async {
        defer { activity = .idle }

        do {
            async let circles = dataSource.getCircles()
            async let extensions = dataSource.getCircleExtensions()
            let (catalogCircles, catalogExtensions) = await (circles, extensions)
            let payload = try await client.importFollowings(
                twitterUserName: userName,
                onProgress: { [weak self] progress in
                    let matches = await Task.detached(priority: .userInitiated) {
                        FollowingCircleMatcher.match(
                            accounts: progress.followings,
                            circles: catalogCircles,
                            extensions: catalogExtensions
                        )
                    }.value
                    await self?.updateProgressPreview(
                        progress,
                        matches: matches
                    )
                }
            )
            progressPreview.phase = .finalizing
            progressPreview.fetchedCount = payload.followings.count
            let matches = await Task.detached(priority: .userInitiated) {
                FollowingCircleMatcher.match(
                    accounts: payload.followings,
                    circles: catalogCircles,
                    extensions: catalogExtensions
                )
            }.value
            progressPreview.matchedCircleCount = Set(matches.map(\.publicCircleID)).count
            let eventNumber = dataSource.comiket.number
            let sources = matches.map { match in
                ImportedCircleSource(
                    eventNumber: eventNumber,
                    publicCircleID: match.publicCircleID,
                    twitterUserID: match.account.id,
                    twitterUserName: match.account.userName,
                    twitterDisplayName: match.account.name,
                    profilePictureURL: match.account.profilePicture,
                    firstImportedAt: payload.importedAt,
                    lastSeenAt: payload.importedAt
                )
            }
            let state = FollowingImportState(
                eventNumber: eventNumber,
                twitterUserName: payload.twitterUserName,
                importedAt: payload.importedAt,
                nextAllowedAt: payload.nextAllowedAt,
                followingCount: payload.followings.count,
                matchedCircleCount: Set(matches.map(\.publicCircleID)).count
            )
            try await dataSource.userPlanStore.mergeFollowingImport(
                state: state,
                sources: sources
            )
            importState = state
            twitterUserName = payload.twitterUserName
            try await reloadImportedCircles(
                circles: catalogCircles,
                extensions: catalogExtensions
            )
        } catch {
            if case FollowingImportAPIError.server(_, _, let nextAllowedAt) = error,
                let nextAllowedAt,
                var importState
            {
                importState = FollowingImportState(
                    eventNumber: importState.eventNumber,
                    twitterUserName: importState.twitterUserName,
                    importedAt: importState.importedAt,
                    nextAllowedAt: nextAllowedAt,
                    followingCount: importState.followingCount,
                    matchedCircleCount: importState.matchedCircleCount
                )
                self.importState = importState
            }
            errorMessage = error.localizedDescription
        }
    }

    private func updateProgressPreview(
        _ progress: FollowingImportProgress,
        matches: [FollowingCircleMatch]
    ) {
        previewMatchedCircleIDs.formUnion(matches.map(\.publicCircleID))
        progressPreview = FollowingImportProgressPreview(
            phase: .fetching,
            page: progress.page,
            fetchedCount: progress.fetchedCount,
            matchedCircleCount: previewMatchedCircleIDs.count,
            maximumCount: progress.maximumCount
        )
    }

    func favorite(_ importedCircle: FollowingImportedCircle) {
        favorite(
            circles: [importedCircle],
            intent: favoriteColor(for: importedCircle) == nil
                ? .favoriteAdded
                : .favoriteRemoved,
            recordsUndo: false
        )
    }

    func favoriteAll() {
        favorite(
            circles: importedCircles,
            intent: .favoritesImported,
            recordsUndo: true
        )
    }

    func undoFavoriteAll() {
        guard activity == .idle, let undo = lastBulkFavorite else { return }
        lastBulkFavorite = nil
        activity = .favoriting
        errorMessage = nil
        activityTask = Task { [weak self] in
            await self?.restore(undo)
        }
    }

    func favoriteColor(for importedCircle: FollowingImportedCircle) -> BookmarkColor? {
        importedCircle.publicCircleIDsByCatalogID.values
            .compactMap { favoriteColorsByPublicID[$0] }
            .first
    }

    private var normalizedTwitterUserName: String? {
        let value = twitterUserName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@", with: "", options: .regularExpression)
        guard value.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil
        else { return nil }
        return value.lowercased()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func favorite(
        circles imported: [FollowingImportedCircle],
        intent: AppTrack.UserIntent,
        recordsUndo: Bool
    ) {
        guard activity == .idle, !imported.isEmpty else { return }
        lastBulkFavorite = nil
        AppTrack.userIntent(
            intent,
            data: [
                "event_number": dataSource.comiket.number,
                "circle_count": Set(
                    imported.flatMap(\.publicCircleIDsByCatalogID.values)
                ).count,
                "source": "following_import",
            ]
        )
        activity = .favoriting
        errorMessage = nil
        let previousFavoriteColors = favoriteColorsByPublicID
        let color = selectedColor
        for publicCircleID in imported.flatMap(\.publicCircleIDsByCatalogID.values) {
            favoriteColorsByPublicID[publicCircleID] = color
        }
        activityTask = Task { [weak self] in
            await self?.persistFavorites(
                imported,
                color: color,
                restoring: previousFavoriteColors,
                recordsUndo: recordsUndo
            )
        }
    }

    private func persistFavorites(
        _ imported: [FollowingImportedCircle],
        color: BookmarkColor,
        restoring previousFavoriteColors: [Int: BookmarkColor],
        recordsUndo: Bool
    ) async {
        defer { activity = .idle }

        do {
            let memberCircles = imported.flatMap(\.circles)
            let publicIDsByCatalogID = imported.reduce(into: [Int: Int]()) {
                $0.merge($1.publicCircleIDsByCatalogID, uniquingKeysWith: { first, _ in first })
            }
            let locations = try await dataSource.mapCatalog.bookmarkLocations(
                updateIDs: memberCircles.compactMap(\.updateId)
            )
            let locationsByCatalogID = Dictionary(
                locations.map { ($0.catalogCircleID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let now = Date()
            var bookmarks: [MapBookmark] = []
            var previousBookmarks: [MapBookmark] = []
            var addedBookmarks: [MapBookmark] = []
            for circle in memberCircles {
                guard let publicCircleID = publicIDsByCatalogID[circle.id],
                    let updateID = circle.updateId,
                    let location = locationsByCatalogID[circle.id]
                else { continue }

                if var existing = try await dataSource.userPlanStore.bookmark(
                    eventNumber: dataSource.comiket.number,
                    publicCircleID: publicCircleID
                ) {
                    previousBookmarks.append(existing)
                    existing.color = color
                    existing.modifiedAt = now
                    existing.syncState = .pendingUpsert
                    bookmarks.append(existing)
                } else {
                    let added = MapBookmark(
                        eventNumber: dataSource.comiket.number,
                        publicCircleID: publicCircleID,
                        catalogCircleID: circle.id,
                        updateID: updateID,
                        day: location.day,
                        mapID: location.mapID,
                        tableID: location.tableID,
                        subspace: location.subspace,
                        color: color,
                        memo: "",
                        modifiedAt: now,
                        syncState: .pendingUpsert
                    )
                    addedBookmarks.append(added)
                    bookmarks.append(added)
                }
            }
            guard !bookmarks.isEmpty else {
                throw FollowingImportModelError.locationsUnavailable
            }
            try await dataSource.userPlanStore.upsert(bookmarks)
            favoriteColorsByPublicID = previousFavoriteColors
            for bookmark in bookmarks {
                favoriteColorsByPublicID[bookmark.publicCircleID] = bookmark.color
            }
            if recordsUndo {
                lastBulkFavorite = FollowingBulkFavoriteUndo(
                    circleCount: Set(bookmarks.map(\.publicCircleID)).count,
                    previousBookmarks: previousBookmarks,
                    addedBookmarks: addedBookmarks
                )
            }
            scheduleBookmarkSync()
        } catch {
            favoriteColorsByPublicID = previousFavoriteColors
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ undo: FollowingBulkFavoriteUndo) async {
        defer { activity = .idle }

        let now = Date()
        let restored = undo.previousBookmarks.map { bookmark in
            var bookmark = bookmark
            bookmark.modifiedAt = now
            // A record that was already waiting for deletion stays that way;
            // every other earlier record is sent again with its old values.
            if bookmark.syncState != .pendingDelete {
                bookmark.syncState = .pendingUpsert
            }
            return bookmark
        }
        let removed = undo.addedBookmarks.map { bookmark in
            var bookmark = bookmark
            bookmark.modifiedAt = now
            bookmark.syncState = .pendingDelete
            return bookmark
        }

        do {
            try await dataSource.userPlanStore.upsert(restored + removed)
            for bookmark in removed {
                favoriteColorsByPublicID[bookmark.publicCircleID] = nil
            }
            for bookmark in restored {
                favoriteColorsByPublicID[bookmark.publicCircleID] =
                    bookmark.isFavorite ? bookmark.color : nil
            }
            scheduleBookmarkSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleBookmarkSync() {
        guard let coordinator = dataSource.bookmarkSyncCoordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.sync()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadImportedCircles(
        circles: [CirclemsDataSchema.ComiketCircleWC]? = nil,
        extensions: [CirclemsDataSchema.ComiketCircleExtend]? = nil
    ) async throws {
        let eventNumber = dataSource.comiket.number
        async let storedSources = dataSource.userPlanStore.importedCircleSources(
            eventNumber: eventNumber
        )
        let catalogCircles = if let circles { circles } else { await dataSource.getCircles() }
        let catalogExtensions =
            if let extensions {
                extensions
            } else {
                await dataSource.getCircleExtensions()
            }
        let sources = try await storedSources
        let resolvedCircles = await Task.detached(priority: .userInitiated) {
            FollowingCircleMatcher.resolveImportedCircles(
                sources: sources,
                circles: catalogCircles,
                extensions: catalogExtensions
            )
        }.value
        let bookmarks = try await dataSource.userPlanStore.allBookmarks(eventNumber: eventNumber)
        importedCircles = resolvedCircles
        favoriteColorsByPublicID = Dictionary(
            bookmarks.compactMap { bookmark in
                bookmark.isFavorite ? (bookmark.publicCircleID, bookmark.color) : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

private enum FollowingImportModelError: LocalizedError {
    case locationsUnavailable

    var errorDescription: String? {
        String(localized: "No map locations were available for these circles.")
    }
}
