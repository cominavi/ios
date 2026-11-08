import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

enum ExploreLayout: String, CaseIterable, Identifiable, Sendable {
    case gallery
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .gallery: String(localized: "Gallery")
        case .list: String(localized: "List")
        }
    }

    var systemImage: String {
        switch self {
        case .gallery: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

enum ExploreSort: String, CaseIterable, Identifiable, Sendable {
    case catalog
    case latestShinagaki

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .catalog: "Catalog order"
        case .latestShinagaki: "Latest item lists"
        }
    }

    var systemImage: String {
        switch self {
        case .catalog: "map"
        case .latestShinagaki: "clock.badge"
        }
    }
}

enum ExploreShinagakiFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case available
    case highConfidence

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All circles"
        case .available: "Has item list"
        case .highConfidence: "High-confidence item list"
        }
    }

    /// The one-line choice title in the filter sheet, where the field title
    /// ("Item list") already gives the context.
    var choiceTitle: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .available: "Has item list"
        case .highConfidence: "High confidence"
        }
    }
}

enum ExploreFavoriteFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case saved
    case notSaved

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All save states"
        case .saved: "Saved only"
        case .notSaved: "Not saved"
        }
    }

    /// The one-line choice title in the filter sheet.
    var choiceTitle: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .saved: "Saved only"
        case .notSaved: "Not saved"
        }
    }
}

enum ExploreAttendanceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case attending
    case withdrawn

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All attendance states"
        case .attending: "Attendance confirmed"
        case .withdrawn: "Withdrawn circles"
        }
    }

    /// The one-line choice title in the filter sheet.
    var choiceTitle: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .attending: "Confirmed"
        case .withdrawn: "Withdrawn"
        }
    }
}

enum ExploreSpaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case combinedAB
    case singleSpace

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All space types"
        case .combinedAB: "A+B circles"
        case .singleSpace: "Single-space circles"
        }
    }

    /// The one-line choice title in the filter sheet.
    var choiceTitle: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .combinedAB: "A+B"
        case .singleSpace: "Single space"
        }
    }
}

/// One filter input that currently narrows Explore results. The toolbar badge,
/// the removable chips above the results and the filter sheet's Clear button
/// all derive from the same list, so they cannot disagree about what is active.
enum ExploreActiveFilterKind: Hashable, Sendable {
    case genre
    case tag
    case discoveryTerm(String)
    case shinagaki
    case saved
    case favoriteColors
    case attendance
    case space
}

struct ExploreActiveFilter: Identifiable, Equatable, Sendable {
    let kind: ExploreActiveFilterKind
    let title: String
    let systemImage: String

    var id: ExploreActiveFilterKind { kind }
}

struct ExploreArtworkPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    var cacheKey: String {
        "\(width)x\(height)"
    }
}

struct ExploreCoverCandidate: Sendable {
    let data: Data
    let targetCoverage: Double

    init(data: Data, targetCoverage: Double) {
        self.data = data
        self.targetCoverage = targetCoverage.isFinite
            ? max(targetCoverage, 0)
            : 0
    }

    var coversTarget: Bool {
        targetCoverage >= 1
    }
}

enum ExploreCoverSource: Equatable, Sendable {
    case shinagaki
    case circle
}

struct ExploreResolvedCover: Equatable, Sendable {
    let data: Data
    let source: ExploreCoverSource
}

struct ExploreCircle: Identifiable {
    let circle: CirclemsDataSchema.ComiketCircleWC
    var memberCircles: [CirclemsDataSchema.ComiketCircleWC] = []
    let genreName: String?
    let blockName: String
    var tags: [String]
    var enrichment: CatalogCircleEnrichment? = nil
    /// The catalog hall name ("西12", "東123") when the catalog layout knows
    /// it. It adds the hall direction to `spaceLabel`.
    var hallName: String? = nil

    var id: Int { circle.id }
    var circles: [CirclemsDataSchema.ComiketCircleWC] {
        memberCircles.isEmpty ? [circle] : memberCircles
    }
    var isCombinedAB: Bool { circles.count == 2 }
    var day: Int { circle.day ?? 0 }
    var genreID: Int? { circle.genreId }

    var displayName: String {
        circle.circleName?.nilIfBlank ?? String(localized: "Unnamed circle")
    }

    var penName: String? {
        circle.penName?.nilIfBlank
    }

    var description: String? {
        circle.description?.nilIfBlank
    }

    /// The short space address, "West あ01a", in the same format as map
    /// search. Without a known hall it falls back to the bare code "あ01a".
    var spaceLabel: String {
        spaceAddress?.formatted(.short) ?? blockName
    }

    /// The bare space code, "あ01a", for cards too narrow for the hall.
    var spaceCode: String {
        spaceAddress?.spaceCode ?? blockName
    }

    private var spaceAddress: ComiketSpaceAddress? {
        guard let number = circle.spaceNo, number > 0 else { return nil }
        return ComiketSpaceAddress(
            day: day,
            hallName: hallName ?? "",
            blockName: blockName,
            spaceNumber: number,
            subspace: circle.spaceNoSub == 1 ? 1 : 0,
            isCombinedAB: isCombinedAB
        )
    }

    var preferredCoverURLs: [URL] {
        guard let enrichment else { return [] }

        var urls: [URL] = []
        var seen: Set<URL> = []
        for media in enrichment.posts.lazy.flatMap(\.media) where media.kind != .video {
            for url in [media.previewURL, media.url].compactMap({ $0 })
                where seen.insert(url).inserted
            {
                urls.append(url)
            }
        }
        return urls
    }

    var preferredCoverURL: URL? {
        preferredCoverURLs.first
    }

    var hasShinagaki: Bool {
        enrichment?.posts.isEmpty == false
    }

    var searchableText: String {
        [
            circle.circleName,
            circle.circleKana,
            circle.penName,
            circle.bookName,
            circle.description,
            genreName,
            blockName,
            tags.joined(separator: " "),
            enrichment?.searchableText,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    var ocrSearchableText: String {
        enrichment?.ocrSearchableText ?? ""
    }
}

struct ExploreGenreFacet: Identifiable, Equatable {
    let id: Int
    let name: String
    let count: Int
}

struct ExploreTagFacet: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

private struct ExploreSearchDocument: Sendable {
    let circleID: Int
    let primaryText: String
    let ocrText: String
}

private struct ExploreSearchResult: Sendable {
    let scoresByCircleID: [Int: Int]
    let hasKeywords: Bool
}

private enum ExploreSearchEngine {
    static func search(
        documents: [ExploreSearchDocument],
        query: String
    ) -> ExploreSearchResult? {
        guard !Task.isCancelled else { return nil }

        let keywords = query
            .split(whereSeparator: \.isWhitespace)
            .map { JapaneseSearchNormalizer.normalize(String($0)) }
        guard !keywords.isEmpty else {
            return ExploreSearchResult(scoresByCircleID: [:], hasKeywords: false)
        }

        var scoresByCircleID: [Int: Int] = [:]
        scoresByCircleID.reserveCapacity(documents.count)
        for document in documents {
            guard !Task.isCancelled else { return nil }

            var score = 0
            for keyword in keywords {
                if document.primaryText.contains(keyword) {
                    score += 100
                } else if document.ocrText.contains(keyword) {
                    score += 1
                } else {
                    score = -1
                    break
                }
            }
            if score >= 0 {
                scoresByCircleID[document.circleID] = score
            }
        }
        return ExploreSearchResult(
            scoresByCircleID: scoresByCircleID,
            hasKeywords: true
        )
    }
}

@MainActor
@Observable
final class ExploreModel {
    enum TagState: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    #if DEBUG
        struct DebugRecomputeWorkCounts: Equatable {
            var totalRecomputeInvocations = 0
            var catalogComparatorCalls = 0
            var bookmarkLookups = 0
        }
    #endif

    var layout: ExploreLayout = .gallery
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleSearch()
        }
    }
    var selectedGenreID: Int? {
        didSet {
            guard selectedGenreID != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var selectedTag: String? {
        didSet {
            guard selectedTag != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var selectedDiscoveryTermIDs: Set<String> = [] {
        didSet {
            guard selectedDiscoveryTermIDs != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var discoveryMatchMode: ExploreDiscoveryMatchMode = .any {
        didSet {
            guard discoveryMatchMode != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var sort: ExploreSort = .catalog {
        didSet {
            guard sort != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var shinagakiFilter: ExploreShinagakiFilter = .all {
        didSet {
            guard shinagakiFilter != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var favoriteFilter: ExploreFavoriteFilter = .all {
        didSet {
            guard favoriteFilter != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var selectedFavoriteColors: Set<BookmarkColor> = [] {
        didSet {
            guard selectedFavoriteColors != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var attendanceFilter: ExploreAttendanceFilter = .all {
        didSet {
            guard attendanceFilter != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }
    var spaceFilter: ExploreSpaceFilter = .all {
        didSet {
            guard spaceFilter != oldValue else { return }
            recomputeVisibleCirclesAfterFilterChange()
        }
    }

    private(set) var selectedDay: Int
    private(set) var allCircles: [ExploreCircle] = []
    private(set) var visibleCircles: [ExploreCircle] = []
    private(set) var selectedDayCircleCount = 0
    private(set) var genreFacets: [ExploreGenreFacet] = []
    private(set) var tagFacets: [ExploreTagFacet] = []
    private(set) var shinagakiCircleCount = 0
    private(set) var highConfidenceShinagakiCircleCount = 0
    /// The most-used tags for the selected day, shown as one-tap shortcuts.
    private(set) var discoveryTerms: [ExploreDiscoveryTerm] = []
    /// Every tag for the selected day, for the filter sheet's tag list. Both
    /// lists share `selectedDiscoveryTermIDs`, the only multi-tag state.
    private(set) var allDiscoveryTerms: [ExploreDiscoveryTerm] = []
    private(set) var isDiscoveryLoading = false
    private(set) var isLoading = false
    private(set) var tagState: TagState = .idle
    private(set) var bookmarksByCatalogCircleID: [Int: MapBookmark] = [:]

    @ObservationIgnored private let dataSource: CirclemsDataSource?
    @ObservationIgnored private let userPlanStore: (any UserPlanStoring)?
    @ObservationIgnored private let eventNumber: Int?
    @ObservationIgnored private let fixtureCircles: [ExploreCircle]?
    @ObservationIgnored private let fixedTag: String?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var bookmarkUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryIndex = ExploreDiscoveryIndex.empty
    @ObservationIgnored private var discoveryRevision = 0
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var searchDocuments: [ExploreSearchDocument] = []
    @ObservationIgnored private var searchScoresByCircleID: [Int: Int] = [:]
    @ObservationIgnored private var hasActiveSearch = false
    @ObservationIgnored private var searchRevision = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadRevision = 0
    @ObservationIgnored private var isClearingFilters = false
    @ObservationIgnored private let artworkLoader: CircleDetailArtworkLoader?
    @ObservationIgnored private let imageCache = NSCache<NSNumber, NSData>()
    @ObservationIgnored private let coverThumbnailCache = NSCache<NSString, NSData>()
    #if DEBUG
        @ObservationIgnored private(set) var debugLastRecomputeWorkCounts =
            DebugRecomputeWorkCounts()
    #endif

    init(
        dataSource: CirclemsDataSource,
        selectedDay: Int,
        selectedTag: String? = nil
    ) {
        self.dataSource = dataSource
        userPlanStore = dataSource.userPlanStore
        eventNumber = dataSource.comiket.number
        fixtureCircles = nil
        fixedTag = selectedTag
        self.selectedDay = selectedDay
        self.selectedTag = selectedTag
        artworkLoader = CircleDetailArtworkLoader()
        imageCache.totalCostLimit = 48 * 1_024 * 1_024
        coverThumbnailCache.totalCostLimit = 12 * 1_024 * 1_024
    }

    deinit {
        loadTask?.cancel()
        discoveryTask?.cancel()
        searchTask?.cancel()
        bookmarkUpdatesTask?.cancel()
    }

    init(
        circles: [ExploreCircle],
        selectedDay: Int,
        userPlanStore: (any UserPlanStoring)? = nil,
        eventNumber: Int? = nil
    ) {
        dataSource = nil
        self.userPlanStore = userPlanStore
        self.eventNumber = eventNumber
        fixtureCircles = circles
        fixedTag = nil
        self.selectedDay = selectedDay
        artworkLoader = nil
        imageCache.totalCostLimit = 48 * 1_024 * 1_024
        coverThumbnailCache.totalCostLimit = 12 * 1_024 * 1_024
    }

    var catalogDataSource: CirclemsDataSource? {
        dataSource
    }

    /// True on a tag page, where one tag scopes every result.
    var hasFixedTag: Bool {
        fixedTag != nil
    }

    var isResolvingFixedTag: Bool {
        guard fixedTag != nil else { return false }
        switch tagState {
        case .idle, .loading: return true
        case .ready, .unavailable: return false
        }
    }

    func load() async {
        guard !hasLoaded else { return }

        if let loadTask {
            await loadTask.value
            return
        }

        let bookmarkUpdates: AsyncStream<UInt64>? = if let userPlanStore, let eventNumber {
            await userPlanStore.bookmarkUpdates(eventNumber: eventNumber)
        } else {
            nil
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
        if let bookmarkUpdates {
            observeBookmarkUpdates(bookmarkUpdates)
        }
    }

    private func performLoad() async {
        guard !hasLoaded else { return }

        loadRevision += 1
        let revision = loadRevision
        isLoading = true
        defer {
            if revision == loadRevision {
                isLoading = false
            }
        }

        if let fixtureCircles {
            allCircles = Self.sorted(fixtureCircles.map { circle in
                var circle = circle
                circle.tags = Self.canonicalTagLabels(
                    circle.tags + (circle.enrichment?.tagLabels ?? [])
                )
                return circle
            })
            rebuildSearchDocuments()
            if let userPlanStore, let eventNumber {
                applyBookmarks(
                    (try? await userPlanStore.allBookmarks(eventNumber: eventNumber)) ?? []
                )
            }
            tagState = .ready
            recomputeFacetsAndCircles()
            scheduleSearch()
            hasLoaded = true
            return
        }

        guard let dataSource else {
            return
        }

        async let loadedCircles = dataSource.getCircles()
        async let loadedGenres = dataSource.getGenres()
        async let loadedExtensions = dataSource.getCircleExtensions()
        async let loadedEnrichments = dataSource.getCircleEnrichments()
        async let loadedBookmarks = try? dataSource.userPlanStore.allBookmarks(
            eventNumber: dataSource.comiket.number
        )
        let (circles, genres, extensions, enrichments, bookmarks) = await (
            loadedCircles,
            loadedGenres,
            loadedExtensions,
            loadedEnrichments,
            loadedBookmarks
        )
        guard !Task.isCancelled, revision == loadRevision else { return }

        let genrePairs: [(Int, String)] = genres.compactMap { genre in
            guard let name = genre.name?.nilIfBlank else { return nil }
            return (genre.id, name)
        }
        let genresByID = Dictionary(uniqueKeysWithValues: genrePairs)
        let blocksByID = Dictionary(uniqueKeysWithValues: dataSource.comiket.blocks.map {
            ($0.externalBlockId, $0.name)
        })
        let hallNamesByBlockID = await Self.hallNamesByBlockID(
            circles: circles,
            dataSource: dataSource
        )
        guard !Task.isCancelled, revision == loadRevision else { return }
        let extensionsByCircleID = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })
        let pairedCircles = CatalogCirclePairing.groups(
            circles: circles,
            extensionsByCircleID: extensionsByCircleID
        )
        allCircles = Self.sorted(pairedCircles.compactMap { memberCircles in
            guard let circle = memberCircles.first else { return nil }
            let memberEnrichments = memberCircles.compactMap { enrichments[$0.id] }
            let enrichment: CatalogCircleEnrichment? = memberEnrichments.isEmpty
                ? nil
                : CatalogCircleEnrichment(
                    posts: Self.uniquePosts(memberEnrichments.flatMap(\.posts)),
                    attendanceClaims: memberEnrichments.flatMap(\.attendanceClaims),
                    tags: memberEnrichments.flatMap(\.tags)
                )
            return ExploreCircle(
                circle: circle,
                memberCircles: memberCircles,
                genreName: circle.genreId.flatMap { genresByID[$0] },
                blockName: circle.blockId.flatMap { blocksByID[$0] } ?? "",
                tags: enrichment?.tagLabels ?? [],
                enrichment: enrichment,
                hallName: circle.blockId.flatMap { hallNamesByBlockID[$0] }
            )
        })
        rebuildSearchDocuments()
        applyBookmarks(bookmarks ?? [])
        recomputeFacetsAndCircles()
        scheduleSearch()
        hasLoaded = true
        isLoading = false
        tagState = .ready
    }

    func select(day: Int) {
        guard selectedDay != day else { return }
        selectedDay = day
        selectedDiscoveryTermIDs = []
        recomputeFacetsAndCircles()
    }

    func bookmark(for circle: ExploreCircle) -> MapBookmark? {
        guard !circle.memberCircles.isEmpty else {
            return bookmarksByCatalogCircleID[circle.circle.id]
        }

        var newestBookmark: MapBookmark?
        for memberCircle in circle.memberCircles {
            guard let bookmark = bookmarksByCatalogCircleID[memberCircle.id] else {
                continue
            }
            if let newestBookmark,
               newestBookmark.modifiedAt >= bookmark.modifiedAt
            {
                continue
            }
            newestBookmark = bookmark
        }
        return newestBookmark
    }

    func refreshUserPlan() async {
        guard let userPlanStore,
              let eventNumber,
              let bookmarks = try? await userPlanStore.allBookmarks(eventNumber: eventNumber)
        else { return }

        applyBookmarks(bookmarks)
        recomputeVisibleCircles()
    }

    private func observeBookmarkUpdates(_ updates: AsyncStream<UInt64>) {
        guard bookmarkUpdatesTask == nil else { return }
        bookmarkUpdatesTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled, let self else { return }
                await self.refreshUserPlan()
            }
        }
    }

    private func applyBookmarks(_ bookmarks: [MapBookmark]) {
        bookmarksByCatalogCircleID = bookmarks.reduce(into: [:]) { result, bookmark in
            guard bookmark.isFavorite else { return }
            if let existing = result[bookmark.catalogCircleID],
               existing.modifiedAt >= bookmark.modifiedAt {
                return
            } else {
                result[bookmark.catalogCircleID] = bookmark
            }
        }
    }

    var activeFilters: [ExploreActiveFilter] {
        var filters: [ExploreActiveFilter] = []
        if let selectedGenreID {
            filters.append(ExploreActiveFilter(
                kind: .genre,
                title: genreFacets.first { $0.id == selectedGenreID }?.name
                    ?? String(localized: "Genre"),
                systemImage: "theatermasks"
            ))
        }
        // A tag page's own tag is its scope, not a removable filter.
        if fixedTag == nil, let selectedTag {
            filters.append(ExploreActiveFilter(
                kind: .tag,
                title: selectedTag,
                systemImage: "tag"
            ))
        }
        for term in allDiscoveryTerms where selectedDiscoveryTermIDs.contains(term.id) {
            filters.append(ExploreActiveFilter(
                kind: .discoveryTerm(term.id),
                title: term.title,
                systemImage: "tag"
            ))
        }
        if shinagakiFilter != .all {
            filters.append(ExploreActiveFilter(
                kind: .shinagaki,
                title: String(localized: shinagakiFilter.title),
                systemImage: "doc.richtext"
            ))
        }
        if favoriteFilter != .all {
            filters.append(ExploreActiveFilter(
                kind: .saved,
                title: String(localized: favoriteFilter.title),
                systemImage: "star"
            ))
        }
        if !selectedFavoriteColors.isEmpty {
            filters.append(ExploreActiveFilter(
                kind: .favoriteColors,
                title: BookmarkColor.selectableColors
                    .filter { selectedFavoriteColors.contains($0) }
                    .map { String(localized: $0.displayName) }
                    .formatted(.list(type: .or)),
                systemImage: "paintbrush.pointed"
            ))
        }
        if attendanceFilter != .all {
            filters.append(ExploreActiveFilter(
                kind: .attendance,
                title: String(localized: attendanceFilter.title),
                systemImage: "person.2.crop.square.stack"
            ))
        }
        if spaceFilter != .all {
            filters.append(ExploreActiveFilter(
                kind: .space,
                title: String(localized: spaceFilter.title),
                systemImage: "square.grid.2x2"
            ))
        }
        return filters
    }

    func clear(_ filter: ExploreActiveFilterKind) {
        switch filter {
        case .genre: selectedGenreID = nil
        case .tag: selectedTag = fixedTag
        case .discoveryTerm(let termID): selectedDiscoveryTermIDs.remove(termID)
        case .shinagaki: shinagakiFilter = .all
        case .saved: favoriteFilter = .all
        case .favoriteColors: selectedFavoriteColors = []
        case .attendance: attendanceFilter = .all
        case .space: spaceFilter = .all
        }
    }

    func clearFilters() {
        isClearingFilters = true
        defer {
            isClearingFilters = false
            recomputeVisibleCircles()
        }

        selectedGenreID = nil
        selectedTag = fixedTag
        selectedDiscoveryTermIDs = []
        shinagakiFilter = .all
        favoriteFilter = .all
        selectedFavoriteColors = []
        attendanceFilter = .all
        spaceFilter = .all
    }

    func toggleDiscoveryTerm(_ termID: String) {
        if selectedDiscoveryTermIDs.contains(termID) {
            selectedDiscoveryTermIDs.remove(termID)
        } else {
            selectedDiscoveryTermIDs.insert(termID)
        }
    }

    func waitForDiscoveryIndex() async {
        await discoveryTask?.value
    }

    func waitForSearch() async {
        await searchTask?.value
    }

    func imageData(for circle: ExploreCircle) async -> Data? {
        let cacheKey = NSNumber(value: circle.id)
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached as Data
        }

        guard let dataSource else { return nil }
        let databaseImage = await dataSource.getCircleImage(circleId: circle.id)
        let imageData: Data?

        if let databaseImage {
            imageData = databaseImage
        } else {
            let details = await dataSource.getCircleDetails(circleID: circle.id)
            imageData = await artworkLoader?.bestImageData(
                publicCircleID: details.extensionRecord?.WCId,
                updateID: circle.circle.updateId,
                fallback: nil
            )
        }

        if let imageData {
            imageCache.setObject(
                imageData as NSData,
                forKey: cacheKey,
                cost: imageData.count
            )
        }
        return imageData
    }

    func fullCoverImage(for circle: ExploreCircle) async -> UIImage? {
        for url in circle.preferredCoverURLs {
            guard !Task.isCancelled else { return nil }
            if let image = await RemoteImagePipeline.image(
                for: url,
                category: .shinagaki
            ) {
                return image
            }
        }
        guard let data = await imageData(for: circle), !Task.isCancelled else { return nil }
        return UIImage(data: data)
    }

    private static func uniquePosts(_ posts: [CatalogShinagakiPost]) -> [CatalogShinagakiPost] {
        var seen: Set<String> = []
        return posts.filter { seen.insert($0.id).inserted }
    }

    func coverImage(
        for circle: ExploreCircle,
        targetPixelSize: ExploreArtworkPixelSize
    ) async -> ExploreResolvedCover? {
        guard !Task.isCancelled else { return nil }

        return await Self.resolveCoverImage(
            shinagakiURLs: circle.preferredCoverURLs,
            loadShinagaki: { coverURL in
                await self.thumbnailData(
                    from: coverURL,
                    cacheKey: "shinagaki-\(coverURL.absoluteString)-\(targetPixelSize.cacheKey)",
                    targetPixelSize: targetPixelSize
                )
            },
            loadCircleCover: {
                await self.circleCoverImageData(
                    for: circle,
                    targetPixelSize: targetPixelSize
                )
            }
        )
    }

    static func resolveCoverImage(
        shinagakiURLs: [URL],
        loadShinagaki: (URL) async -> ExploreCoverCandidate?,
        loadCircleCover: () async -> Data?
    ) async -> ExploreResolvedCover? {
        var bestUndersizedShinagaki: ExploreCoverCandidate?
        for url in shinagakiURLs {
            guard !Task.isCancelled else { return nil }
            if let candidate = await loadShinagaki(url) {
                if candidate.coversTarget {
                    return ExploreResolvedCover(
                        data: candidate.data,
                        source: .shinagaki
                    )
                }
                if candidate.targetCoverage
                    > (bestUndersizedShinagaki?.targetCoverage ?? -Double.infinity)
                {
                    bestUndersizedShinagaki = candidate
                }
            }
        }

        guard !Task.isCancelled else { return nil }
        if let bestUndersizedShinagaki {
            return ExploreResolvedCover(
                data: bestUndersizedShinagaki.data,
                source: .shinagaki
            )
        }
        return await loadCircleCover().map {
            ExploreResolvedCover(data: $0, source: .circle)
        }
    }

    static func resolveCoverImageData(
        shinagakiURLs: [URL],
        loadShinagaki: (URL) async -> ExploreCoverCandidate?,
        loadCircleCover: () async -> Data?
    ) async -> Data? {
        await resolveCoverImage(
            shinagakiURLs: shinagakiURLs,
            loadShinagaki: loadShinagaki,
            loadCircleCover: loadCircleCover
        )?.data
    }

    private func circleCoverImageData(
        for circle: ExploreCircle,
        targetPixelSize: ExploreArtworkPixelSize
    ) async -> Data? {
        let cacheKey = "circle-\(circle.id)-\(targetPixelSize.cacheKey)" as NSString
        if let cached = coverThumbnailCache.object(forKey: cacheKey) {
            return cached as Data
        }

        guard let sourceData = await imageData(for: circle),
              !Task.isCancelled,
              let thumbnailData = await Self.downsampledThumbnailData(
                  from: sourceData,
                  targetPixelSize: targetPixelSize
              ),
              !Task.isCancelled
        else { return nil }

        coverThumbnailCache.setObject(
            thumbnailData as NSData,
            forKey: cacheKey,
            cost: thumbnailData.count
        )
        return thumbnailData
    }

    private func thumbnailData(
        from url: URL,
        cacheKey: String,
        targetPixelSize: ExploreArtworkPixelSize
    ) async -> ExploreCoverCandidate? {
        guard !Task.isCancelled else { return nil }

        let cacheKey = cacheKey as NSString
        if let cached = coverThumbnailCache.object(forKey: cacheKey) {
            let data = cached as Data
            return ExploreCoverCandidate(
                data: data,
                targetCoverage: Self.targetCoverage(
                    of: data,
                    for: targetPixelSize
                )
            )
        }

        guard let image = await RemoteImagePipeline.image(
            for: url,
            category: .shinagaki,
            targetPixelSize: CGSize(
                width: targetPixelSize.width,
                height: targetPixelSize.height
            )
        ),
            !Task.isCancelled,
            let thumbnailData = await RemoteImagePipeline.encodedPNGData(for: image)
        else { return nil }

        coverThumbnailCache.setObject(
            thumbnailData as NSData,
            forKey: cacheKey,
            cost: thumbnailData.count
        )
        return ExploreCoverCandidate(
            data: thumbnailData,
            targetCoverage: Self.targetCoverage(
                of: thumbnailData,
                for: targetPixelSize
            )
        )
    }

    nonisolated static func downsampledThumbnailData(
        from data: Data,
        targetPixelSize: ExploreArtworkPixelSize
    ) async -> Data? {
        guard !data.isEmpty else { return nil }

        let task = Task.detached(priority: .userInitiated) { () throws -> Data? in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            guard let sourcePixelSize = sourcePixelSize(from: source) else {
                return nil
            }
            let maximumPixelDimension = thumbnailMaximumPixelDimension(
                sourcePixelSize: sourcePixelSize,
                targetPixelSize: targetPixelSize
            )

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { return nil }
            try Task.checkCancellation()

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                thumbnail,
                [
                    kCGImageDestinationLossyCompressionQuality: 0.88,
                ] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            try Task.checkCancellation()
            return output as Data
        }

        return await withTaskCancellationHandler {
            try? await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func thumbnailMaximumPixelDimension(
        sourcePixelSize: ExploreArtworkPixelSize,
        targetPixelSize: ExploreArtworkPixelSize
    ) -> Int {
        let scale = max(
            Double(targetPixelSize.width) / Double(sourcePixelSize.width),
            Double(targetPixelSize.height) / Double(sourcePixelSize.height)
        )
        let requiredMaximum = Int(ceil(
            Double(max(sourcePixelSize.width, sourcePixelSize.height)) * scale
        ))
        return min(
            max(requiredMaximum, 1),
            max(sourcePixelSize.width, sourcePixelSize.height)
        )
    }

    private nonisolated static func sourcePixelSize(
        from source: CGImageSource
    ) -> ExploreArtworkPixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0,
              rawHeight > 0
        else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if 5...8 ~= orientation {
            return ExploreArtworkPixelSize(width: rawHeight, height: rawWidth)
        }
        return ExploreArtworkPixelSize(width: rawWidth, height: rawHeight)
    }

    private nonisolated static func targetCoverage(
        of data: Data,
        for targetPixelSize: ExploreArtworkPixelSize
    ) -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let pixelSize = sourcePixelSize(from: source)
        else { return 0 }
        return min(
            Double(pixelSize.width) / Double(targetPixelSize.width),
            Double(pixelSize.height) / Double(targetPixelSize.height)
        )
    }

    private func recomputeFacetsAndCircles() {
        let circlesForDay = allCircles.filter { $0.day == selectedDay }
        selectedDayCircleCount = circlesForDay.count
        shinagakiCircleCount = circlesForDay.count { $0.hasShinagaki }
        highConfidenceShinagakiCircleCount = circlesForDay.count {
            $0.enrichment?.hasHighConfidencePost == true
        }

        let genreCounts = Dictionary(grouping: circlesForDay.compactMap { circle -> (Int, String)? in
            guard let id = circle.genreID, let name = circle.genreName else { return nil }
            return (id, name)
        }, by: { $0.0 })
        genreFacets = genreCounts.compactMap { id, values in
            guard let name = values.first?.1 else { return nil }
            return ExploreGenreFacet(id: id, name: name, count: values.count)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        let tagCounts = Dictionary(grouping: circlesForDay.flatMap(\.tags), by: { $0 })
        tagFacets = tagCounts.map { name, values in
            ExploreTagFacet(name: name, count: values.count)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if let selectedGenreID, !genreFacets.contains(where: { $0.id == selectedGenreID }) {
            self.selectedGenreID = nil
        }
        if fixedTag == nil,
           let selectedTag,
           !tagFacets.contains(where: { $0.name == selectedTag })
        {
            self.selectedTag = nil
        }
        recomputeVisibleCircles()
        scheduleDiscoveryRebuild(for: circlesForDay)
    }

    private func rebuildSearchDocuments() {
        searchDocuments = allCircles.map { circle in
            ExploreSearchDocument(
                circleID: circle.id,
                primaryText: JapaneseSearchNormalizer.normalize(circle.searchableText),
                ocrText: JapaneseSearchNormalizer.normalize(circle.ocrSearchableText)
            )
        }
    }

    private func recomputeVisibleCirclesAfterFilterChange() {
        guard !isClearingFilters else { return }
        recomputeVisibleCircles()
    }

    private func recomputeVisibleCircles() {
        #if DEBUG
            var debugWorkCounts = DebugRecomputeWorkCounts()
            debugWorkCounts.totalRecomputeInvocations =
                debugLastRecomputeWorkCounts.totalRecomputeInvocations + 1
            defer { debugLastRecomputeWorkCounts = debugWorkCounts }
        #endif

        let needsBookmark = favoriteFilter != .all || !selectedFavoriteColors.isEmpty
        let filteredCircles = allCircles.filter { circle in
            guard circle.day == selectedDay else { return false }
            if let selectedGenreID, circle.genreID != selectedGenreID { return false }
            if let selectedTag, !circle.tags.contains(selectedTag) { return false }
            switch shinagakiFilter {
            case .all:
                break
            case .available where !circle.hasShinagaki:
                return false
            case .highConfidence where circle.enrichment?.hasHighConfidencePost != true:
                return false
            default:
                break
            }
            if needsBookmark {
                #if DEBUG
                    debugWorkCounts.bookmarkLookups += circle.memberCircles.isEmpty
                        ? 1
                        : circle.memberCircles.count
                #endif
                let bookmark = bookmark(for: circle)
                switch favoriteFilter {
                case .all:
                    break
                case .saved where bookmark == nil:
                    return false
                case .notSaved where bookmark != nil:
                    return false
                default:
                    break
                }
                if !selectedFavoriteColors.isEmpty {
                    guard let bookmark,
                          selectedFavoriteColors.contains(bookmark.color)
                    else { return false }
                }
            }
            switch attendanceFilter {
            case .all:
                break
            case .attending where circle.enrichment?.attendanceClaims.contains(where: {
                $0.status == .attending && [.high, .medium].contains($0.confidence)
            }) != true:
                return false
            case .withdrawn where circle.enrichment?.withdrawalClaims.isEmpty != false:
                return false
            default:
                break
            }
            switch spaceFilter {
            case .all:
                break
            case .combinedAB where !circle.isCombinedAB:
                return false
            case .singleSpace where circle.isCombinedAB:
                return false
            default:
                break
            }
            if !selectedDiscoveryTermIDs.isEmpty {
                switch discoveryMatchMode {
                case .any:
                    guard selectedDiscoveryTermIDs.contains(where: {
                        discoveryIndex.circleIDsByTermID[$0]?.contains(circle.id) == true
                    }) else { return false }
                case .all:
                    guard selectedDiscoveryTermIDs.allSatisfy({
                        discoveryIndex.circleIDsByTermID[$0]?.contains(circle.id) == true
                    }) else { return false }
                }
            }
            return !hasActiveSearch || searchScoresByCircleID[circle.id] != nil
        }

        if sort == .catalog, !hasActiveSearch {
            visibleCircles = filteredCircles
            return
        }

        visibleCircles = filteredCircles.sorted { lhs, rhs in
            if hasActiveSearch {
                let lhsScore = searchScoresByCircleID[lhs.id] ?? 0
                let rhsScore = searchScoresByCircleID[rhs.id] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
            }

            switch sort {
            case .catalog:
                #if DEBUG
                    debugWorkCounts.catalogComparatorCalls += 1
                #endif
                return Self.catalogOrder(lhs, rhs)
            case .latestShinagaki:
                let lhsDate = lhs.enrichment?.latestPostDate ?? .distantPast
                let rhsDate = rhs.enrichment?.latestPostDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                #if DEBUG
                    debugWorkCounts.catalogComparatorCalls += 1
                #endif
                return Self.catalogOrder(lhs, rhs)
            }
        }
    }

    private func scheduleSearch() {
        searchRevision += 1
        let revision = searchRevision
        searchTask?.cancel()

        guard !searchQuery.isEmpty else {
            searchScoresByCircleID = [:]
            hasActiveSearch = false
            recomputeVisibleCircles()
            return
        }

        let documents = searchDocuments
        let query = searchQuery
        searchTask = Task { [documents, query, revision] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                ExploreSearchEngine.search(documents: documents, query: query)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  revision == searchRevision,
                  let result
            else { return }

            searchScoresByCircleID = result.scoresByCircleID
            hasActiveSearch = result.hasKeywords
            recomputeVisibleCircles()
        }
    }

    private func scheduleDiscoveryRebuild(for circles: [ExploreCircle]) {
        discoveryRevision += 1
        let revision = discoveryRevision
        discoveryTask?.cancel()
        isDiscoveryLoading = true

        let documents = circles.map { circle in
            ExploreDiscoveryDocument(
                circleID: circle.id,
                tags: circle.tags
            )
        }
        discoveryTask = Task { [documents] in
            let index = await Task.detached(priority: .userInitiated) {
                ExploreDiscoveryIndexBuilder.build(from: documents, tagLimit: .max)
            }.value
            guard !Task.isCancelled, revision == discoveryRevision else { return }

            discoveryIndex = index
            allDiscoveryTerms = index.terms
            discoveryTerms = Array(
                index.terms.prefix(ExploreDiscoveryIndexBuilder.popularTagLimit)
            )
            selectedDiscoveryTermIDs.formIntersection(index.terms.map(\.id))
            isDiscoveryLoading = false
            recomputeVisibleCircles()
        }
    }

    /// Resolves each block's hall from the catalog layout. A block sits in
    /// one hall, so one sample circle per block is enough, and the query stays
    /// a few hundred rows instead of one per circle.
    private static func hallNamesByBlockID(
        circles: [CirclemsDataSchema.ComiketCircleWC],
        dataSource: CirclemsDataSource
    ) async -> [Int: String] {
        let catalog: (any MapCatalog)? = dataSource.mapCatalog
        guard let catalog else { return [:] }

        var sampleUpdateIDs: [Int: Int] = [:]
        for circle in circles {
            guard let blockID = circle.blockId,
                  let updateID = circle.updateId,
                  (circle.spaceNo ?? 0) > 0,
                  sampleUpdateIDs[blockID] == nil
            else { continue }
            sampleUpdateIDs[blockID] = updateID
        }
        guard !sampleUpdateIDs.isEmpty,
              let locations = try? await catalog.bookmarkLocations(
                  updateIDs: Array(sampleUpdateIDs.values)
              )
        else { return [:] }

        var hallNamesByMapID: [Int: String] = [:]
        for day in dataSource.comiket.days {
            for hall in day.halls where hallNamesByMapID[hall.externalMapId] == nil {
                hallNamesByMapID[hall.externalMapId] = hall.name
            }
        }

        var result: [Int: String] = [:]
        for location in locations {
            // Prefer the exact hall ("東1") from the layout over the map
            // group ("東123") that spans several halls.
            guard let hallName = location.hallName?.nilIfBlank
                ?? hallNamesByMapID[location.mapID]
            else { continue }
            result[location.tableID.blockID] = hallName
        }
        return result
    }

    private static func sorted(_ circles: [ExploreCircle]) -> [ExploreCircle] {
        circles.sorted(by: catalogOrder)
    }

    static func canonicalTagLabels(_ rawTags: [String]) -> [String] {
        var seen: Set<String> = []
        return rawTags.compactMap { rawValue in
            let tag = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag
                .precomposedStringWithCompatibilityMapping
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return seen.insert(key).inserted ? tag : nil
        }
    }

    private static func catalogOrder(
        _ lhs: ExploreCircle,
        _ rhs: ExploreCircle
    ) -> Bool {
        let lhsKey = (
            lhs.circle.blockId ?? .max,
            lhs.circle.spaceNo ?? .max,
            lhs.circle.spaceNoSub ?? .max
        )
        let rhsKey = (
            rhs.circle.blockId ?? .max,
            rhs.circle.spaceNo ?? .max,
            rhs.circle.spaceNoSub ?? .max
        )
        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }
        return lhsKey.2 < rhsKey.2
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
