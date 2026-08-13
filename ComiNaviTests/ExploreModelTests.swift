import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ComiNavi

@MainActor
final class ExploreModelTests: XCTestCase {
    func testDaySelectionFiltersTheEntireExploreCollection() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()

        XCTAssertEqual(model.visibleCircles.map(\.id), [1, 2, 3])

        model.select(day: 2)

        XCTAssertEqual(model.visibleCircles.map(\.id), [4])
        XCTAssertEqual(model.genreFacets, [
            ExploreGenreFacet(id: 10, name: "Animation", count: 1),
        ])
    }

    func testGenreAndTagFiltersIntersect() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()

        model.selectedGenreID = 10
        model.selectedTag = "Cute"

        XCTAssertEqual(model.visibleCircles.map(\.id), [2])
    }

    func testFavoriteMutationRefreshesLoadedExploreModel() async throws {
        let store = InMemoryUserPlanStore()
        let model = ExploreModel(
            circles: [fixtures[0]],
            selectedDay: 1,
            userPlanStore: store,
            eventNumber: 108
        )
        await model.load()
        XCTAssertNil(model.bookmark(for: fixtures[0]))

        try await store.upsert(makeBookmark(color: .blue))

        try await waitUntil {
            model.bookmark(for: self.fixtures[0])?.color == .blue
        }
    }

    func testMemoOnlyBookmarkIsNotPresentedAsFavorite() async throws {
        let store = InMemoryUserPlanStore()
        try await store.upsert(makeBookmark(color: .memoOnly))
        let model = ExploreModel(
            circles: [fixtures[0]],
            selectedDay: 1,
            userPlanStore: store,
            eventNumber: 108
        )

        await model.load()

        XCTAssertNil(model.bookmark(for: fixtures[0]))
        model.favoriteFilter = .saved
        XCTAssertTrue(model.visibleCircles.isEmpty)
    }

    func testSwitchingDaysClearsEveryFilterThatIsNoLongerAvailable() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()
        model.selectedGenreID = 20
        model.selectedTag = "Robots"

        model.select(day: 2)

        XCTAssertNil(model.selectedGenreID)
        XCTAssertNil(model.selectedTag)
        XCTAssertEqual(model.visibleCircles.map(\.id), [4])
        XCTAssertEqual(model.selectedDayCircleCount, 1)
    }

    func testSearchMatchesCreatorDescriptionAndTags() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()

        model.searchQuery = "Artist Two"
        XCTAssertEqual(model.visibleCircles.map(\.id), [2])

        model.searchQuery = "Robots"
        XCTAssertEqual(model.visibleCircles.map(\.id), [3])

        model.searchQuery = "Action"
        XCTAssertEqual(model.visibleCircles.map(\.id), [1])
    }

    func testSearchIncludesOCRTextAtLowerWeightThanCatalogMetadata() async {
        let ocrOnlyCircle = makeExploreCircle(
            id: 1,
            day: 1,
            genreID: 10,
            name: "First Circle",
            penName: "First Artist",
            description: "Original goods",
            tags: [],
            enrichment: makeEnrichment(
                postID: "ocr-only",
                handle: "first_artist",
                text: "C108 お品書き",
                ocrSearchText: "限定セットあります",
                date: Date(timeIntervalSince1970: 100),
                postConfidence: .high,
                placementConfidence: .high
            )
        )
        let catalogMatchCircle = makeExploreCircle(
            id: 2,
            day: 1,
            genreID: 10,
            name: "限定セット本舗",
            penName: "Second Artist",
            description: "Original books",
            tags: []
        )
        let model = ExploreModel(
            circles: [ocrOnlyCircle, catalogMatchCircle],
            selectedDay: 1
        )
        await model.load()

        model.searchQuery = "限定セット"

        XCTAssertEqual(model.visibleCircles.map(\.id), [2, 1])
    }

    func testSearchTreatsHiraganaAndKatakanaAsEquivalent() async {
        let circle = makeExploreCircle(
            id: 31,
            day: 1,
            genreID: 10,
            name: "アイスココナステッカー",
            penName: "カタカナ作家",
            description: "オリジナル作品",
            tags: ["ブルーアーカイブ"]
        )
        let model = ExploreModel(circles: [circle], selectedDay: 1)
        await model.load()

        model.searchQuery = "あいすここなすてっかー"
        XCTAssertEqual(model.visibleCircles.map(\.id), [31])

        model.searchQuery = "かたかな作家"
        XCTAssertEqual(model.visibleCircles.map(\.id), [31])

        model.searchQuery = "ぶるーあーかいぶ"
        XCTAssertEqual(model.visibleCircles.map(\.id), [31])
    }

    func testFacetsCountOnlyTheSelectedDay() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()

        XCTAssertEqual(model.genreFacets, [
            ExploreGenreFacet(id: 10, name: "Animation", count: 2),
            ExploreGenreFacet(id: 20, name: "Technology", count: 1),
        ])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: model.tagFacets.map { ($0.name, $0.count) }),
            ["Action": 1, "Cute": 1, "Robots": 1]
        )
    }

    func testDirectCuratedTagsPopulateFacetsSearchAndTagFiltering() async {
        let curatedTag = CatalogEnrichmentTag(
            termID: "work.blue-archive",
            canonicalLabel: "ブルーアーカイブ",
            kind: "work",
            provenance: [],
            matchedAlias: nil,
            evidenceLine: nil,
            mediaPath: nil,
            score: 1_000
        )
        let taggedCircle = makeExploreCircle(
            id: 21,
            day: 1,
            genreID: 10,
            name: "OCR Tagged Circle",
            penName: "Artist",
            description: "New books",
            tags: [],
            enrichment: makeEnrichment(
                postID: "ocr-tagged",
                handle: "ocr_tagged",
                text: "C108 お品書き",
                date: Date(timeIntervalSince1970: 400),
                postConfidence: .high,
                placementConfidence: .high,
                directTags: [curatedTag]
            )
        )
        let otherCircle = makeExploreCircle(
            id: 22,
            day: 1,
            genreID: 10,
            name: "Other Circle",
            penName: "Artist",
            description: "Original work",
            tags: []
        )
        let model = ExploreModel(circles: [taggedCircle, otherCircle], selectedDay: 1)

        await model.load()

        XCTAssertEqual(
            model.tagFacets,
            [ExploreTagFacet(name: "ブルーアーカイブ", count: 1)]
        )
        model.selectedTag = "ブルーアーカイブ"
        XCTAssertEqual(model.visibleCircles.map(\.id), [21])

        model.selectedTag = nil
        model.searchQuery = "ブルーアーカイブ"
        XCTAssertEqual(model.visibleCircles.map(\.id), [21])
    }

    func testTagOnlyOverlayDoesNotMasqueradeAsShinagaki() async {
        let tag = CatalogEnrichmentTag(
            termID: "content.r18",
            canonicalLabel: "R-18",
            kind: "content",
            provenance: [],
            matchedAlias: nil,
            evidenceLine: nil,
            mediaPath: nil,
            score: 1_000
        )
        let circle = makeExploreCircle(
            id: 23,
            day: 1,
            genreID: 10,
            name: "Tagged Circle",
            penName: "Artist",
            description: "New work",
            tags: [],
            enrichment: CatalogCircleEnrichment(posts: [], tags: [tag])
        )
        let model = ExploreModel(circles: [circle], selectedDay: 1)

        await model.load()

        XCTAssertEqual(model.tagFacets, [ExploreTagFacet(name: "R-18", count: 1)])
        XCTAssertEqual(model.shinagakiCircleCount, 0)
        model.shinagakiFilter = .available
        XCTAssertTrue(model.visibleCircles.isEmpty)
    }

    func testCanonicalTagLabelsDeduplicateOnlyTheCuratedSource() {
        XCTAssertEqual(
            ExploreModel.canonicalTagLabels([
                "Cute", " Ｂｌｕｅ　Ａｒｃｈｉｖｅ ", "blue archive",
                "ブルーアーカイブ", "", "Cute",
            ]),
            ["Cute", "Ｂｌｕｅ　Ａｒｃｈｉｖｅ", "ブルーアーカイブ"]
        )
    }

    func testLegacyPostAttachedTagDoesNotReachFacetsSearchOrFilters() async {
        let noisyLegacyTag = CatalogEnrichmentTag(
            termID: "legacy:provider:generic",
            canonicalLabel: "同人誌",
            kind: "format",
            provenance: [],
            matchedAlias: "doujinshi",
            evidenceLine: "generic provider label",
            mediaPath: "legacy.jpg",
            score: 300
        )
        let circle = makeExploreCircle(
            id: 41,
            day: 1,
            genreID: 10,
            name: "Travel Circle",
            penName: "Traveller",
            description: "UK travel photography",
            tags: [],
            enrichment: makeEnrichment(
                postID: "legacy-noise",
                handle: "travel_circle",
                text: "C108 お品書き",
                date: Date(timeIntervalSince1970: 400),
                postConfidence: .high,
                placementConfidence: .high,
                tags: [noisyLegacyTag]
            )
        )
        let model = ExploreModel(circles: [circle], selectedDay: 1)

        await model.load()

        XCTAssertTrue(model.tagFacets.isEmpty)
        XCTAssertTrue(model.allCircles[0].tags.isEmpty)
        model.searchQuery = "同人誌"
        XCTAssertTrue(model.visibleCircles.isEmpty)
        model.searchQuery = ""
        model.selectedTag = "同人誌"
        XCTAssertTrue(model.visibleCircles.isEmpty)
    }

    func testDirectCuratedTagsSurviveEnrichmentMerge() {
        let work = CatalogEnrichmentTag(
            termID: "work.vocaloid",
            canonicalLabel: "VOCALOID",
            kind: "work",
            provenance: [],
            matchedAlias: nil,
            evidenceLine: nil,
            mediaPath: nil,
            score: 1_000
        )
        let character = CatalogEnrichmentTag(
            termID: "character.hatsune-miku",
            canonicalLabel: "初音ミク",
            kind: "character",
            provenance: [],
            matchedAlias: nil,
            evidenceLine: nil,
            mediaPath: nil,
            score: 1_000
        )
        let first = CatalogCircleEnrichment(posts: [], tags: [work])
        let second = CatalogCircleEnrichment(posts: [], tags: [character])

        let merged = first.merging(second)

        XCTAssertEqual(merged.tagLabels, ["VOCALOID", "初音ミク"])
    }

    func testShinagakiFiltersDistinguishAvailableAndHighConfidenceMatches() async {
        let model = ExploreModel(circles: enrichedFixtures, selectedDay: 1)
        await model.load()

        XCTAssertEqual(model.shinagakiCircleCount, 2)
        XCTAssertEqual(model.highConfidenceShinagakiCircleCount, 1)

        model.shinagakiFilter = .available
        XCTAssertEqual(model.visibleCircles.map(\.id), [1, 2])

        model.shinagakiFilter = .highConfidence
        XCTAssertEqual(model.visibleCircles.map(\.id), [2])
    }

    func testSpaceFilterDistinguishesCombinedABFromSingleSpaceCircles() async {
        var combined = fixtures[0]
        let secondHalf = makeExploreCircle(
            id: 5,
            day: 1,
            genreID: 10,
            name: combined.displayName,
            penName: "Artist One",
            description: "Illustration books",
            tags: ["Action"]
        )
        combined.memberCircles = [combined.circle, secondHalf.circle]
        let model = ExploreModel(circles: [combined, fixtures[1]], selectedDay: 1)
        await model.load()

        model.spaceFilter = .combinedAB
        XCTAssertEqual(model.visibleCircles.map(\.id), [1])

        model.spaceFilter = .singleSpace
        XCTAssertEqual(model.visibleCircles.map(\.id), [2])
    }

    func testAttendanceFilterUsesConfirmedAndWithdrawalClaims() async {
        let attending = makeExploreCircle(
            id: 11,
            day: 1,
            genreID: 10,
            name: "Attending",
            penName: "Artist",
            description: "Attending",
            tags: [],
            enrichment: makeEnrichment(
                postID: "attending",
                handle: "attending",
                text: "参加します",
                date: Date(timeIntervalSince1970: 100),
                postConfidence: .high,
                placementConfidence: .high,
                attendanceClaims: [makeAttendanceClaim(id: "attending", status: .attending)]
            )
        )
        let withdrawn = makeExploreCircle(
            id: 12,
            day: 1,
            genreID: 10,
            name: "Withdrawn",
            penName: "Artist",
            description: "Withdrawn",
            tags: [],
            enrichment: makeEnrichment(
                postID: "withdrawn",
                handle: "withdrawn",
                text: "欠席します",
                date: Date(timeIntervalSince1970: 200),
                postConfidence: .high,
                placementConfidence: .high,
                attendanceClaims: [makeAttendanceClaim(id: "withdrawn", status: .withdrawn)]
            )
        )
        let model = ExploreModel(circles: [attending, withdrawn], selectedDay: 1)
        await model.load()

        model.attendanceFilter = .attending
        XCTAssertEqual(model.visibleCircles.map(\.id), [11])

        model.attendanceFilter = .withdrawn
        XCTAssertEqual(model.visibleCircles.map(\.id), [12])
    }

    func testLatestShinagakiSortKeepsCatalogOrderAsStableFallback() async {
        let model = ExploreModel(circles: enrichedFixtures, selectedDay: 1)
        await model.load()

        model.sort = .latestShinagaki

        XCTAssertEqual(model.visibleCircles.map(\.id), [2, 1, 3])
    }

    func testCoverPrefersTheFirstNonVideoShinagakiImage() {
        let videoURL = URL(string: "https://example.com/video.mp4")!
        let imageURL = URL(string: "https://example.com/shinagaki.jpg")!
        let previewURL = URL(string: "https://example.com/shinagaki-preview.jpg")!
        let circle = makeExploreCircle(
            id: 9,
            day: 1,
            genreID: 10,
            name: "Covered Circle",
            penName: "Artist",
            description: "Has a shinagaki",
            tags: [],
            enrichment: makeEnrichment(
                postID: "cover",
                handle: "cover_handle",
                text: "お品書き",
                date: Date(timeIntervalSince1970: 300),
                postConfidence: .high,
                placementConfidence: .high,
                media: [
                    CatalogShinagakiMedia(
                        kind: .video,
                        url: videoURL,
                        previewURL: nil
                    ),
                    CatalogShinagakiMedia(
                        kind: .photo,
                        url: imageURL,
                        previewURL: previewURL
                    ),
                ]
            )
        )

        XCTAssertEqual(circle.preferredCoverURL, previewURL)
        XCTAssertEqual(circle.preferredCoverURLs, [previewURL, imageURL])
    }

    func testCoverScansLaterPostsWhenThePrimaryPostOnlyHasVideo() {
        let videoURL = URL(string: "https://example.com/video.mp4")!
        let imageURL = URL(string: "https://example.com/later-shinagaki.jpg")!
        let previewURL = URL(string: "https://example.com/later-shinagaki-preview.jpg")!
        let videoPost = makeEnrichment(
            postID: "video-only",
            handle: "video_handle",
            text: "Video",
            date: Date(timeIntervalSince1970: 400),
            postConfidence: .high,
            placementConfidence: .high,
            media: [
                CatalogShinagakiMedia(
                    kind: .video,
                    url: videoURL,
                    previewURL: nil
                ),
            ]
        ).posts[0]
        let imagePost = makeEnrichment(
            postID: "later-image",
            handle: "image_handle",
            text: "お品書き",
            date: Date(timeIntervalSince1970: 300),
            postConfidence: .high,
            placementConfidence: .high,
            media: [
                CatalogShinagakiMedia(
                    kind: .photo,
                    url: imageURL,
                    previewURL: previewURL
                ),
            ]
        ).posts[0]
        let circle = makeExploreCircle(
            id: 10,
            day: 1,
            genreID: 10,
            name: "Later Cover Circle",
            penName: "Artist",
            description: "Has a later shinagaki image",
            tags: [],
            enrichment: CatalogCircleEnrichment(posts: [videoPost, imagePost])
        )

        XCTAssertEqual(circle.preferredCoverURL, previewURL)
    }

    func testCoverUsesOriginalImageWhenThereIsNoPreview() {
        let imageURL = URL(string: "https://example.com/full-size-shinagaki.jpg")!
        let circle = makeExploreCircle(
            id: 11,
            day: 1,
            genreID: 10,
            name: "Full-size Cover Circle",
            penName: "Artist",
            description: "Has an original shinagaki image",
            tags: [],
            enrichment: makeEnrichment(
                postID: "original-image",
                handle: "original_handle",
                text: "お品書き",
                date: Date(timeIntervalSince1970: 300),
                postConfidence: .high,
                placementConfidence: .high,
                media: [
                    CatalogShinagakiMedia(
                        kind: .photo,
                        url: imageURL,
                        previewURL: nil
                    ),
                ]
            )
        )

        XCTAssertEqual(circle.preferredCoverURL, imageURL)
    }

    func testCoverIsAbsentWhenShinagakiOnlyContainsVideo() {
        let videoURL = URL(string: "https://example.com/shinagaki.mp4")!
        let circle = makeExploreCircle(
            id: 12,
            day: 1,
            genreID: 10,
            name: "Video-only Circle",
            penName: "Artist",
            description: "Has no still shinagaki image",
            tags: [],
            enrichment: makeEnrichment(
                postID: "video-only-cover",
                handle: "video_only_handle",
                text: "Video",
                date: Date(timeIntervalSince1970: 300),
                postConfidence: .high,
                placementConfidence: .high,
                media: [
                    CatalogShinagakiMedia(
                        kind: .video,
                        url: videoURL,
                        previewURL: nil
                    ),
                ]
            )
        )

        XCTAssertNil(circle.preferredCoverURL)
        XCTAssertTrue(circle.preferredCoverURLs.isEmpty)
    }

    func testCoverRetriesOriginalShinagakiBeforeCircleFallback() async {
        let previewURL = URL(string: "https://example.com/preview.jpg")!
        let originalURL = URL(string: "https://example.com/original.jpg")!
        let originalImage = Data([1, 2, 3])
        var attemptedURLs: [URL] = []

        let resolved = await ExploreModel.resolveCoverImageData(
            shinagakiURLs: [previewURL, originalURL],
            loadShinagaki: { url in
                attemptedURLs.append(url)
                return url == originalURL
                    ? ExploreCoverCandidate(data: originalImage, targetCoverage: 1)
                    : nil
            },
            loadCircleCover: {
                XCTFail("The original Shinagaki should win before circle fallback")
                return Data([9])
            }
        )

        XCTAssertEqual(attemptedURLs, [previewURL, originalURL])
        XCTAssertEqual(resolved, originalImage)
    }

    func testCoverSkipsUndersizedPreviewForSufficientOriginal() async {
        let previewURL = URL(string: "https://example.com/preview.jpg")!
        let originalURL = URL(string: "https://example.com/original.jpg")!
        let previewImage = Data([1])
        let originalImage = Data([2])
        var attemptedURLs: [URL] = []

        let resolved = await ExploreModel.resolveCoverImageData(
            shinagakiURLs: [previewURL, originalURL],
            loadShinagaki: { url in
                attemptedURLs.append(url)
                if url == previewURL {
                    return ExploreCoverCandidate(
                        data: previewImage,
                        targetCoverage: 0.25
                    )
                }
                return ExploreCoverCandidate(
                    data: originalImage,
                    targetCoverage: 1
                )
            },
            loadCircleCover: {
                XCTFail("A sufficient Shinagaki original should win")
                return Data([9])
            }
        )

        XCTAssertEqual(attemptedURLs, [previewURL, originalURL])
        XCTAssertEqual(resolved, originalImage)
    }

    func testCoverKeepsUndersizedShinagakiWhenNoBetterShinagakiLoads() async {
        let previewURL = URL(string: "https://example.com/preview.jpg")!
        let originalURL = URL(string: "https://example.com/original.jpg")!
        let previewImage = Data([1])

        let resolved = await ExploreModel.resolveCoverImageData(
            shinagakiURLs: [previewURL, originalURL],
            loadShinagaki: { url in
                url == previewURL
                    ? ExploreCoverCandidate(data: previewImage, targetCoverage: 0.5)
                    : nil
            },
            loadCircleCover: {
                XCTFail("An available Shinagaki should remain preferred")
                return Data([9])
            }
        )

        XCTAssertEqual(resolved, previewImage)
    }

    func testCoverKeepsTheBestOfMultipleUndersizedShinagakiImages() async {
        let previewURL = URL(string: "https://example.com/preview.jpg")!
        let originalURL = URL(string: "https://example.com/original.jpg")!
        let previewImage = Data([1])
        let originalImage = Data([2])

        let resolved = await ExploreModel.resolveCoverImageData(
            shinagakiURLs: [previewURL, originalURL],
            loadShinagaki: { url in
                url == previewURL
                    ? ExploreCoverCandidate(data: previewImage, targetCoverage: 0.2)
                    : ExploreCoverCandidate(data: originalImage, targetCoverage: 0.85)
            },
            loadCircleCover: {
                XCTFail("An available Shinagaki should remain preferred")
                return Data([9])
            }
        )

        XCTAssertEqual(resolved, originalImage)
    }

    func testCoverFallsBackToCircleImageAfterAllShinagakiURLsFail() async {
        let previewURL = URL(string: "https://example.com/preview.jpg")!
        let originalURL = URL(string: "https://example.com/original.jpg")!
        let circleImage = Data([9, 8, 7])
        var attemptedURLs: [URL] = []

        let resolved = await ExploreModel.resolveCoverImageData(
            shinagakiURLs: [previewURL, originalURL],
            loadShinagaki: { url in
                attemptedURLs.append(url)
                return nil
            },
            loadCircleCover: { circleImage }
        )

        XCTAssertEqual(attemptedURLs, [previewURL, originalURL])
        XCTAssertEqual(resolved, circleImage)
    }

    func testResolvedCoverPreservesShinagakiProvenance() async {
        let shinagakiURL = URL(string: "https://example.com/shinagaki.jpg")!
        let shinagakiImage = Data([1, 2, 3])

        let resolved = await ExploreModel.resolveCoverImage(
            shinagakiURLs: [shinagakiURL],
            loadShinagaki: { _ in
                ExploreCoverCandidate(data: shinagakiImage, targetCoverage: 1)
            },
            loadCircleCover: {
                XCTFail("A loaded Shinagaki should win")
                return Data([9])
            }
        )

        XCTAssertEqual(
            resolved,
            ExploreResolvedCover(data: shinagakiImage, source: .shinagaki)
        )
    }

    func testResolvedCoverMarksCatalogFallbackAsCircleArtwork() async {
        let shinagakiURL = URL(string: "https://example.com/missing.jpg")!
        let circleImage = Data([9, 8, 7])

        let resolved = await ExploreModel.resolveCoverImage(
            shinagakiURLs: [shinagakiURL],
            loadShinagaki: { _ in nil },
            loadCircleCover: { circleImage }
        )

        XCTAssertEqual(
            resolved,
            ExploreResolvedCover(data: circleImage, source: .circle)
        )
    }

    func testCoverThumbnailDownsamplingCoversMixedSourceAspectsWithoutUpscaling() async throws {
        let targetPixelSize = ExploreLayoutMetrics
            .artworkPixelSize(width: 76, displayScale: 3)
        XCTAssertEqual(targetPixelSize, ExploreArtworkPixelSize(width: 228, height: 323))

        let sourceSizes = [
            ExploreArtworkPixelSize(width: 1_200, height: 800),
            ExploreArtworkPixelSize(width: 800, height: 800),
            ExploreArtworkPixelSize(width: 840, height: 1_188),
            ExploreArtworkPixelSize(width: 500, height: 1_200),
        ]

        for sourceSize in sourceSizes {
            let sourceData = try makeImageData(
                width: sourceSize.width,
                height: sourceSize.height
            )
            let downsampledData = await ExploreModel.downsampledThumbnailData(
                from: sourceData,
                targetPixelSize: targetPixelSize
            )
            let thumbnailData = try XCTUnwrap(downsampledData)
            let thumbnailSize = try imagePixelSize(from: thumbnailData)

            XCTAssertGreaterThanOrEqual(
                thumbnailSize.width,
                targetPixelSize.width,
                "Source \(sourceSize.cacheKey) did not cover the target width"
            )
            XCTAssertGreaterThanOrEqual(
                thumbnailSize.height,
                targetPixelSize.height,
                "Source \(sourceSize.cacheKey) did not cover the target height"
            )
            XCTAssertLessThanOrEqual(
                max(thumbnailSize.width, thumbnailSize.height),
                max(sourceSize.width, sourceSize.height)
            )
        }
    }

    func testThumbnailMaximumPixelDimensionUsesAspectFillScale() {
        let target = ExploreArtworkPixelSize(width: 228, height: 325)

        XCTAssertEqual(
            ExploreModel.thumbnailMaximumPixelDimension(
                sourcePixelSize: ExploreArtworkPixelSize(width: 1_200, height: 800),
                targetPixelSize: target
            ),
            488
        )
        XCTAssertEqual(
            ExploreModel.thumbnailMaximumPixelDimension(
                sourcePixelSize: ExploreArtworkPixelSize(width: 500, height: 1_200),
                targetPixelSize: target
            ),
            548
        )
    }

    func testGalleryCoverResolutionTracksRenderedArtworkWidth() {
        XCTAssertEqual(
            ExploreLayoutMetrics.artworkPixelSize(
                width: 390,
                displayScale: 3
            ),
            ExploreArtworkPixelSize(width: 1_170, height: 1_655)
        )
    }

    func testSearchAndDiscoveryIncludeCrawledPostTextAndXHandle() async {
        let model = ExploreModel(circles: enrichedFixtures, selectedDay: 1)
        await model.load()

        model.searchQuery = "rare_handle"
        XCTAssertEqual(model.visibleCircles.map(\.id), [2])

        model.searchQuery = "限定アクキー"
        XCTAssertEqual(model.visibleCircles.map(\.id), [2])
    }

    func testDiscoveryCloudContainsPopularTagsOrderedByCircleCount() {
        let documents = [
            ExploreDiscoveryDocument(
                circleID: 1,
                tags: ["Cute", "Action"]
            ),
            ExploreDiscoveryDocument(
                circleID: 2,
                tags: ["Action"]
            ),
            ExploreDiscoveryDocument(
                circleID: 3,
                tags: ["Robots"]
            ),
        ]

        let index = ExploreDiscoveryIndexBuilder.build(from: documents)

        XCTAssertEqual(index.terms.map(\.id), ["tag:action", "tag:cute", "tag:robots"])
        XCTAssertEqual(index.terms.map(\.count), [2, 1, 1])
        XCTAssertEqual(index.circleIDsByTermID["tag:action"], [1, 2])
        XCTAssertEqual(Set(index.terms.map(\.kind)), [.tag])
        XCTAssertFalse(index.terms.contains { $0.id.hasPrefix("genre:") })
        XCTAssertFalse(index.terms.contains { $0.id.hasPrefix("keyword:") })

        let limited = ExploreDiscoveryIndexBuilder.build(from: documents, tagLimit: 2)
        XCTAssertEqual(limited.terms.map(\.id), ["tag:action", "tag:cute"])
    }

    func testPopularTagsSupportAnyAndAllMatching() async {
        var overlappingFixtures = fixtures
        overlappingFixtures[0].tags = ["Action", "Cute"]
        overlappingFixtures[1].tags = ["Action"]
        let model = ExploreModel(circles: overlappingFixtures, selectedDay: 1)
        await model.load()
        await model.waitForDiscoveryIndex()

        model.toggleDiscoveryTerm("tag:action")
        model.toggleDiscoveryTerm("tag:cute")
        XCTAssertEqual(model.visibleCircles.map(\.id), [1, 2])

        model.discoveryMatchMode = .all
        XCTAssertEqual(model.visibleCircles.map(\.id), [1])
    }

    func testChangingDayClearsDiscoveryInterestsAndRebuildsTheCloud() async {
        let model = ExploreModel(circles: fixtures, selectedDay: 1)
        await model.load()
        await model.waitForDiscoveryIndex()
        model.toggleDiscoveryTerm("tag:cute")

        model.select(day: 2)
        await model.waitForDiscoveryIndex()

        XCTAssertTrue(model.selectedDiscoveryTermIDs.isEmpty)
        XCTAssertEqual(model.visibleCircles.map(\.id), [4])
        XCTAssertTrue(model.discoveryTerms.contains { $0.id == "tag:action" })
        XCTAssertFalse(model.discoveryTerms.contains { $0.id == "tag:cute" })
    }

    func testCircleQueryDecodesDocumentedPaginationAndFlexibleIdentifiers() throws {
        let response = try JSONDecoder().decode(
            CirclemsAPI.CircleQueryResponse.self,
            from: Data(
                """
                {
                  "status": "success",
                  "response": {
                    "count": "2",
                    "maxcount": 2,
                    "list": [
                      { "updateId": "101", "tag": "Action,Cute" },
                      { "updateId": 102, "tag": null }
                    ]
                  }
                }
                """.utf8
            )
        )

        XCTAssertEqual(response.response.count, 2)
        XCTAssertEqual(response.response.maxCount, 2)
        XCTAssertEqual(response.response.list.map(\.updateId), [101, 102])
        XCTAssertEqual(response.response.list.first?.tag, "Action,Cute")
    }

    private var fixtures: [ExploreCircle] {
        [
            makeExploreCircle(
                id: 1,
                day: 1,
                genreID: 10,
                name: "First Circle",
                penName: "Artist One",
                description: "Illustration books",
                tags: ["Action"]
            ),
            makeExploreCircle(
                id: 2,
                day: 1,
                genreID: 10,
                name: "Second Circle",
                penName: "Artist Two",
                description: "Character goods",
                tags: ["Cute"]
            ),
            makeExploreCircle(
                id: 3,
                day: 1,
                genreID: 20,
                name: "Third Circle",
                penName: "Engineer",
                description: "Robots and hardware",
                tags: ["Robots"]
            ),
            makeExploreCircle(
                id: 4,
                day: 2,
                genreID: 10,
                name: "Fourth Circle",
                penName: "Day Two Artist",
                description: "Day two only",
                tags: ["Action"]
            ),
        ]
    }

    private var enrichedFixtures: [ExploreCircle] {
        [
            makeExploreCircle(
                id: 1,
                day: 1,
                genreID: 10,
                name: "First Circle",
                penName: "Artist One",
                description: "Illustration books",
                tags: ["Action"],
                enrichment: makeEnrichment(
                    postID: "older",
                    handle: "older_handle",
                    text: "お品書き",
                    date: Date(timeIntervalSince1970: 100),
                    postConfidence: .medium,
                    placementConfidence: .high
                )
            ),
            makeExploreCircle(
                id: 2,
                day: 1,
                genreID: 10,
                name: "Second Circle",
                penName: "Artist Two",
                description: "Character goods",
                tags: ["Cute"],
                enrichment: makeEnrichment(
                    postID: "newer",
                    handle: "rare_handle",
                    text: "限定アクキーあります",
                    date: Date(timeIntervalSince1970: 200),
                    postConfidence: .high,
                    placementConfidence: .high
                )
            ),
            makeExploreCircle(
                id: 3,
                day: 1,
                genreID: 20,
                name: "Third Circle",
                penName: "Engineer",
                description: "Robots and hardware",
                tags: ["Robots"]
            ),
        ]
    }

    private func makeExploreCircle(
        id: Int,
        day: Int,
        genreID: Int,
        name: String,
        penName: String,
        description: String,
        tags: [String],
        enrichment: CatalogCircleEnrichment? = nil
    ) -> ExploreCircle {
        ExploreCircle(
            circle: CirclemsDataSchema.ComiketCircleWC(
                comiketNo: 108,
                id: id,
                pageNo: 1,
                cutIndex: id,
                day: day,
                blockId: id,
                spaceNo: id,
                spaceNoSub: 0,
                genreId: genreID,
                circleName: name,
                circleKana: nil,
                penName: penName,
                bookName: nil,
                url: nil,
                mailAddr: nil,
                description: description,
                memo: nil,
                updateId: id + 100,
                updateData: nil,
                circlems: nil,
                rss: nil,
                updateFlag: nil
            ),
            genreName: genreID == 10 ? "Animation" : "Technology",
            blockName: "A",
            tags: tags,
            enrichment: enrichment
        )
    }

    private func makeBookmark(color: BookmarkColor) -> MapBookmark {
        MapBookmark(
            eventNumber: 108,
            publicCircleID: 1_001,
            catalogCircleID: fixtures[0].id,
            updateID: fixtures[0].circle.updateId,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 1, spaceNumber: 1),
            subspace: 0,
            color: color,
            memo: color == .memoOnly ? "memo without favorite" : "",
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            syncState: .pendingUpsert
        )
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(300),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for Explore to reflect the favorite mutation")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeEnrichment(
        postID: String,
        handle: String,
        text: String,
        ocrSearchText: String? = nil,
        date: Date,
        postConfidence: CatalogConfidence,
        placementConfidence: CatalogConfidence,
        media: [CatalogShinagakiMedia] = [],
        tags: [CatalogEnrichmentTag] = [],
        directTags: [CatalogEnrichmentTag] = [],
        attendanceClaims: [CatalogAttendanceClaim] = []
    ) -> CatalogCircleEnrichment {
        CatalogCircleEnrichment(
            posts: [CatalogShinagakiPost(
                id: postID,
                postURL: URL(string: "https://x.com/\(handle)/status/\(postID)")!,
                text: text,
                ocrSearchText: ocrSearchText,
                createdAt: date,
                authorHandle: handle,
                authorName: nil,
                authorBio: nil,
                authorProfileImageURL: nil,
                media: media,
                tags: tags,
                postConfidence: postConfidence,
                placementConfidence: placementConfidence,
                matchScore: 75,
                matchReasons: []
            )],
            attendanceClaims: attendanceClaims,
            tags: directTags
        )
    }

    private func makeAttendanceClaim(
        id: String,
        status: CatalogAttendanceStatus
    ) -> CatalogAttendanceClaim {
        CatalogAttendanceClaim(
            id: id,
            status: status,
            confidence: .high,
            reasons: [],
            policyID: "test",
            postURL: URL(string: "https://x.com/test/status/\(id)")!,
            text: id,
            createdAt: Date(timeIntervalSince1970: 100),
            authorHandle: "test",
            authorName: nil,
            matchingPolicyID: "test",
            matchScore: 100,
            matchReasons: [],
            provenance: [],
            matchedCircleProvenance: []
        )
    }

    private func makeImageData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                red: 0.2,
                green: 0.6,
                blue: 0.9,
                alpha: 1
            )
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func imagePixelSize(from data: Data) throws -> ExploreArtworkPixelSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return ExploreArtworkPixelSize(
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
