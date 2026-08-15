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
        case .latestShinagaki: "Latest shinagaki"
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
        case .available: "Has shinagaki"
        case .highConfidence: "High-confidence shinagaki"
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

    var spaceLabel: String {
        guard let number = circle.spaceNo, number > 0 else { return blockName }
        let side = isCombinedAB ? "a+b" : (circle.spaceNoSub == 1 ? "b" : "a")
        return "\(blockName)\(String(format: "%02d", number))\(side)"
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
            recomputeVisibleCircles()
        }
    }
    var selectedTag: String? {
        didSet {
            guard selectedTag != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var selectedDiscoveryTermIDs: Set<String> = [] {
        didSet {
            guard selectedDiscoveryTermIDs != oldValue else { return }
            recomputeVisibleCircles()
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
            recomputeVisibleCircles()
        }
    }
    var favoriteFilter: ExploreFavoriteFilter = .all {
        didSet {
            guard favoriteFilter != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var selectedFavoriteColors: Set<BookmarkColor> = [] {
        didSet {
            guard selectedFavoriteColors != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var attendanceFilter: ExploreAttendanceFilter = .all {
        didSet {
            guard attendanceFilter != oldValue else { return }
            recomputeVisibleCircles()
        }
    }
    var spaceFilter: ExploreSpaceFilter = .all {
        didSet {
            guard spaceFilter != oldValue else { return }
            recomputeVisibleCircles()
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
    private(set) var discoveryTerms: [ExploreDiscoveryTerm] = []
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
    @ObservationIgnored private let artworkLoader: CircleDetailArtworkLoader?
    @ObservationIgnored private let imageCache = NSCache<NSNumber, NSData>()
    @ObservationIgnored private let coverThumbnailCache = NSCache<NSString, NSData>()

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
            if let userPlanStore, let eventNumber {
                applyBookmarks(
                    (try? await userPlanStore.allBookmarks(eventNumber: eventNumber)) ?? []
                )
            }
            tagState = .ready
            recomputeFacetsAndCircles()
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
                enrichment: enrichment
            )
        })
        applyBookmarks(bookmarks ?? [])
        recomputeFacetsAndCircles()
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
        circle.circles.compactMap { bookmarksByCatalogCircleID[$0.id] }.max {
            $0.modifiedAt < $1.modifiedAt
        }
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

    func clearFilters() {
        selectedGenreID = nil
        selectedTag = nil
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
        searchDocuments = allCircles.map { circle in
            ExploreSearchDocument(
                circleID: circle.id,
                primaryText: JapaneseSearchNormalizer.normalize(circle.searchableText),
                ocrText: JapaneseSearchNormalizer.normalize(circle.ocrSearchableText)
            )
        }
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
        scheduleSearch()
        scheduleDiscoveryRebuild(for: circlesForDay)
    }

    private func recomputeVisibleCircles() {
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
            if !selectedFavoriteColors.isEmpty,
               bookmark.map({ selectedFavoriteColors.contains($0.color) }) != true
            {
                return false
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
                let matches = selectedDiscoveryTermIDs.map {
                    discoveryIndex.circleIDsByTermID[$0]?.contains(circle.id) == true
                }
                switch discoveryMatchMode {
                case .any where !matches.contains(true): return false
                case .all where matches.contains(false): return false
                default: break
                }
            }
            return !hasActiveSearch || searchScoresByCircleID[circle.id] != nil
        }
        visibleCircles = filteredCircles.sorted { lhs, rhs in
            if hasActiveSearch {
                let lhsScore = searchScoresByCircleID[lhs.id] ?? 0
                let rhsScore = searchScoresByCircleID[rhs.id] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
            }

            switch sort {
            case .catalog:
                return Self.catalogOrder(lhs, rhs)
            case .latestShinagaki:
                let lhsDate = lhs.enrichment?.latestPostDate ?? .distantPast
                let rhsDate = rhs.enrichment?.latestPostDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
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
                ExploreDiscoveryIndexBuilder.build(from: documents)
            }.value
            guard !Task.isCancelled, revision == discoveryRevision else { return }

            discoveryIndex = index
            discoveryTerms = index.terms
            selectedDiscoveryTermIDs.formIntersection(index.terms.map(\.id))
            isDiscoveryLoading = false
            recomputeVisibleCircles()
        }
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
