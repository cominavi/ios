import Foundation
import Observation

@MainActor
@Observable
final class FollowingImportModel {
    enum Activity: Equatable {
        case idle
        case importing
        case favoriting
    }

    private(set) var importedCircles: [FollowingImportedCircle] = []
    private(set) var importState: FollowingImportState?
    private(set) var favoriteColorsByPublicID: [Int: BookmarkColor] = [:]
    private(set) var activity: Activity = .idle
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var twitterUserName = ""
    var selectedColor: BookmarkColor = .orange

    @ObservationIgnored private let dataSource: CirclemsDataSource
    @ObservationIgnored private let client: FollowingImportAPIClient
    @ObservationIgnored private let accessToken: () async -> String

    init(
        dataSource: CirclemsDataSource,
        client: FollowingImportAPIClient = FollowingImportAPIClient(),
        accessToken: @escaping () async -> String = { await AppData.getUserToken() }
    ) {
        self.dataSource = dataSource
        self.client = client
        self.accessToken = accessToken
    }

    var canImport: Bool {
        activity == .idle
            && normalizedTwitterUserName != nil
            && (importState?.nextAllowedAt ?? .distantPast) <= Date()
    }

    var nextAllowedAt: Date? {
        guard let date = importState?.nextAllowedAt, date > Date() else { return nil }
        return date
    }

    var importedPublicCircleCount: Int {
        Set(importedCircles.flatMap { $0.publicCircleIDsByCatalogID.values }).count
    }

    func load() async {
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

    func importNow() async {
        guard let userName = normalizedTwitterUserName, canImport else { return }
        activity = .importing
        errorMessage = nil
        successMessage = nil
        defer { activity = .idle }

        do {
            let token = await accessToken()
            let payload = try await client.importFollowings(
                twitterUserName: userName,
                circlemsAccessToken: token,
                circlemsEnvironment: AppEnvironment.current.circlems
            )
            async let circles = dataSource.getCircles()
            async let extensions = dataSource.getCircleExtensions()
            let (catalogCircles, catalogExtensions) = await (circles, extensions)
            let matches = FollowingCircleMatcher.match(
                accounts: payload.followings,
                circles: catalogCircles,
                extensions: catalogExtensions
            )
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
            successMessage = String(
                localized: "Imported \(state.matchedCircleCount) matching circles."
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

    func favorite(_ importedCircle: FollowingImportedCircle) async {
        await favorite(circles: [importedCircle])
    }

    func favoriteAll() async {
        await favorite(circles: importedCircles)
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

    private func favorite(circles imported: [FollowingImportedCircle]) async {
        guard activity == .idle, !imported.isEmpty else { return }
        activity = .favoriting
        errorMessage = nil
        successMessage = nil
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
            for circle in memberCircles {
                guard let publicCircleID = publicIDsByCatalogID[circle.id],
                    let updateID = circle.updateId,
                    let location = locationsByCatalogID[circle.id]
                else { continue }

                if var existing = try await dataSource.userPlanStore.bookmark(
                    eventNumber: dataSource.comiket.number,
                    publicCircleID: publicCircleID
                ) {
                    existing.color = selectedColor
                    existing.modifiedAt = now
                    existing.syncState = .pendingUpsert
                    bookmarks.append(existing)
                } else {
                    bookmarks.append(
                        MapBookmark(
                            eventNumber: dataSource.comiket.number,
                            publicCircleID: publicCircleID,
                            catalogCircleID: circle.id,
                            updateID: updateID,
                            day: location.day,
                            mapID: location.mapID,
                            tableID: location.tableID,
                            subspace: location.subspace,
                            color: selectedColor,
                            memo: "",
                            modifiedAt: now,
                            syncState: .pendingUpsert
                        ))
                }
            }
            guard !bookmarks.isEmpty else {
                throw FollowingImportModelError.locationsUnavailable
            }
            try await dataSource.userPlanStore.upsert(bookmarks)
            for bookmark in bookmarks {
                favoriteColorsByPublicID[bookmark.publicCircleID] = bookmark.color
            }
            successMessage = String(localized: "Favorited \(bookmarks.count) circles.")
            if let coordinator = dataSource.bookmarkSyncCoordinator {
                Task { try? await coordinator.sync() }
            }
        } catch {
            errorMessage = error.localizedDescription
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
        importedCircles = FollowingCircleMatcher.resolveImportedCircles(
            sources: sources,
            circles: catalogCircles,
            extensions: catalogExtensions
        )
        let bookmarks = try await dataSource.userPlanStore.allBookmarks(eventNumber: eventNumber)
        favoriteColorsByPublicID = Dictionary(
            bookmarks.compactMap { bookmark in
                bookmark.syncState == .pendingDelete
                    ? nil
                    : (bookmark.publicCircleID, bookmark.color)
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
