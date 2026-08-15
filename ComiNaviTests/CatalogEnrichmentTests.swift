import Foundation
import XCTest
@testable import ComiNavi

final class CatalogEnrichmentTests: XCTestCase {
    func testCollectorArchiveDecodesSnakeCaseAndUsesOnlyStrongestPlacementCandidates() throws {
        let data = Data(
            """
            [
              {
                "tweet_id": "100",
                "tweet_url": "https://x.com/test_circle/status/100",
                "text": "C108 お品書き 新刊あります",
                "created_at": "Sat Jul 25 10:30:00 +0000 2026",
                "author_handle": "test_circle",
                "author_name": "Test Circle",
                "author": {
                  "name": "Test Circle",
                  "description": "Illustration and books",
                  "profilePicture": "https://pbs.twimg.com/profile.jpg"
                },
                "media": [
                  {
                    "kind": "photo",
                    "url": "https://pbs.twimg.com/media/menu.jpg",
                    "preview_url": "https://pbs.twimg.com/media/menu-small.jpg"
                  },
                  {
                    "kind": "photo",
                    "url": "https://pbs.twimg.com/media/map.jpg",
                    "preview_url": "https://pbs.twimg.com/media/map-small.jpg"
                  }
                ],
                "post_confidence": "high",
                "post_reasons": ["shinagaki_keyword", "media"],
                "placement_confidence": "high",
                "matching_policy_id": "c108-shinagaki-placement-v2",
                "provenance": [
                  {
                    "sourceId": "x-public-post",
                    "sourceKind": "social_post",
                    "recordId": "100",
                    "url": "https://x.com/test_circle/status/100",
                    "fields": ["text", "media"]
                  }
                ],
                "matched_circles": [
                  {
                    "circle_id": 10,
                    "wc_id": 1010,
                    "score": 75,
                    "reasons": ["placement_in_post_or_profile"],
                    "provenance": [
                      {
                        "source_id": "circlems-webcatalog-c108",
                        "source_kind": "catalog_snapshot",
                        "record_id": "108:10",
                        "url": "https://webcatalog.circle.ms/Circle/Map/23000001/1"
                      }
                    ]
                  },
                  {
                    "circle_id": 20,
                    "wc_id": 2020,
                    "score": 60,
                    "reasons": ["area_in_post_or_profile"]
                  }
                ]
              },
              {
                "tweet_id": "200",
                "tweet_url": "https://x.com/tied/status/200",
                "text": "C108 menu",
                "created_at": null,
                "author_handle": "tied",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "medium",
                "placement_confidence": "medium",
                "matched_circles": [
                  {
                    "circle_id": 30,
                    "wc_id": 3030,
                    "score": 60,
                    "reasons": []
                  },
                  {
                    "circle_id": 31,
                    "wc_id": 3131,
                    "score": 60,
                    "reasons": []
                  }
                ]
              },
              {
                "tweet_id": "300",
                "tweet_url": "https://x.com/unmatched/status/300",
                "text": "C108 unknown booth",
                "created_at": null,
                "author_handle": "unmatched",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "medium",
                "placement_confidence": "unmatched",
                "matched_circles": []
              }
            ]
            """.utf8
        )

        let index = try CatalogEnrichmentIndex(
            data: data,
            ocrSearchTextByPostID: ["100": "画像だけにある頒布物名"]
        )

        XCTAssertEqual(index.selectedPostCount, 3)
        XCTAssertEqual(index.mappedPostCount, 2)
        XCTAssertEqual(index.mappedPublicCircleCount, 3)
        let strongest = try XCTUnwrap(
            index.enrichment(circleID: 999, publicCircleID: 1010)?.primaryPost
        )
        XCTAssertEqual(strongest.id, "100")
        XCTAssertEqual(strongest.authorHandle, "test_circle")
        XCTAssertEqual(strongest.ocrSearchText, "画像だけにある頒布物名")
        XCTAssertEqual(
            strongest.media.map { $0.displayURL.absoluteString },
            [
                "https://pbs.twimg.com/media/menu-small.jpg",
                "https://pbs.twimg.com/media/map-small.jpg",
            ]
        )
        XCTAssertTrue(strongest.isHighConfidence)
        XCTAssertEqual(strongest.matchingPolicyID, "c108-shinagaki-placement-v2")
        XCTAssertEqual(strongest.postReasons, ["shinagaki_keyword", "media"])
        XCTAssertEqual(strongest.provenance.first?.sourceID, "x-public-post")
        XCTAssertEqual(
            strongest.matchedCircleProvenance.first?.recordID,
            "108:10"
        )
        XCTAssertEqual(index.enrichment(circleID: 999, publicCircleID: 1010)?.tagLabels, [])
        XCTAssertNil(index.enrichment(circleID: 20, publicCircleID: 2020))
        XCTAssertNil(
            index.enrichment(circleID: 31, publicCircleID: nil),
            "A match carrying a stable public ID must never be reattached through its mutable seed ID."
        )
    }

    func testWithdrawalEvidenceMapsAttendanceTargetsWithoutCreatingShinagaki() throws {
        let data = Data(
            """
            [
              {
                "tweet_id": "2083911737565450341",
                "tweet_url": "https://x.com/rurudo_/status/2083911737565450341",
                "text": "C108は欠席いたします",
                "created_at": "2026-08-04T12:30:00Z",
                "author_handle": "rurudo_",
                "author_name": "rurudo",
                "author": null,
                "media": [],
                "post_reasons": ["event_keyword"],
                "post_confidence": "low",
                "placement_confidence": "unmatched",
                "matching_policy_id": "c108-shinagaki-placement-v3",
                "provenance": [
                  {
                    "sourceId": "x-public-post",
                    "sourceKind": "social_post",
                    "recordId": "2083911737565450341",
                    "url": "https://x.com/rurudo_/status/2083911737565450341"
                  }
                ],
                "attendance": {
                  "status": "withdrawn",
                  "confidence": "high",
                  "reasons": ["event_context", "withdrawal_statement"],
                  "provenance": [
                    {
                      "sourceId": "x-public-post",
                      "sourceKind": "attendance_evidence",
                      "recordId": "2083911737565450341",
                      "url": "https://x.com/rurudo_/status/2083911737565450341"
                    }
                  ],
                  "policyId": "c108-participation-v1"
                },
                "matched_circles": [],
                "attendance_targets": [
                  {
                    "circle_id": 18223,
                    "wc_id": 23009270,
                    "score": 80,
                    "reasons": ["catalog_handle"],
                    "provenance": [
                      {
                        "sourceId": "circlems-webcatalog-c108",
                        "sourceKind": "catalog_snapshot",
                        "recordId": "108:18223"
                      }
                    ]
                  },
                  {
                    "circle_id": 18224,
                    "wc_id": 23009271,
                    "score": 70,
                    "reasons": ["catalog_handle"],
                    "provenance": [
                      {
                        "sourceId": "circlems-webcatalog-c108",
                        "sourceKind": "catalog_snapshot",
                        "recordId": "108:18224"
                      }
                    ]
                  }
                ]
              }
            ]
            """.utf8
        )

        let index = try CatalogEnrichmentIndex(data: data)

        XCTAssertEqual(index.selectedPostCount, 1)
        XCTAssertEqual(index.mappedPostCount, 1)
        XCTAssertEqual(index.mappedPublicCircleCount, 2)

        for publicCircleID in [23009270, 23009271] {
            let enrichment = try XCTUnwrap(
                index.enrichment(circleID: -1, publicCircleID: publicCircleID)
            )
            XCTAssertTrue(enrichment.posts.isEmpty)
            let claim = try XCTUnwrap(enrichment.withdrawalClaims.first)
            XCTAssertEqual(claim.status, .withdrawn)
            XCTAssertEqual(claim.confidence, .high)
            XCTAssertEqual(claim.policyID, "c108-participation-v1")
            XCTAssertEqual(claim.matchingPolicyID, "c108-shinagaki-placement-v3")
            XCTAssertEqual(claim.matchReasons, ["catalog_handle"])
            XCTAssertEqual(claim.provenance.count, 2)
            XCTAssertTrue(
                claim.matchedCircleProvenance.first?.recordID?.hasPrefix("108:") == true
            )
        }
    }

    func testLegacyWithdrawalEvidenceFallsBackToMatchedCircles() throws {
        let data = Data(
            """
            [
              {
                "tweet_id": "legacy-withdrawal",
                "tweet_url": "https://x.com/legacy/status/1",
                "text": "C108は欠席します",
                "created_at": null,
                "author_handle": "legacy",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "low",
                "placement_confidence": "medium",
                "matched_circles": [
                  {
                    "circle_id": 77,
                    "wc_id": 7007,
                    "score": 80,
                    "reasons": ["catalog_handle"]
                  }
                ],
                "attendance": {
                  "status": "withdrawn",
                  "confidence": "medium",
                  "policyId": "legacy-attendance-v1"
                }
              }
            ]
            """.utf8
        )

        let index = try CatalogEnrichmentIndex(data: data)
        let enrichment = try XCTUnwrap(
            index.enrichment(circleID: -1, publicCircleID: 7007)
        )

        XCTAssertTrue(enrichment.posts.isEmpty)
        XCTAssertEqual(enrichment.withdrawalClaims.map(\.id), ["legacy-withdrawal"])
    }

    func testEmbeddedLegacyTagsDecodeButNeverBecomeVisibleOrSearchable() throws {
        let data = Data(
            """
            [
              {
                "tweet_id": "tagged-1",
                "tweet_url": "https://x.com/tagged/status/tagged-1",
                "text": "C108 お品書き",
                "created_at": null,
                "author_handle": "tagged",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 10,
                    "wc_id": 1010,
                    "score": 80,
                    "reasons": ["placement_in_post_or_profile"]
                  },
                  {
                    "circle_id": 20,
                    "wc_id": 2020,
                    "score": 60,
                    "reasons": []
                  }
                ],
                "enrichment": {
                  "schemaVersion": 1,
                  "tweetId": "tagged-1",
                  "generatedAt": "2026-07-31T00:00:00Z",
                  "lexiconId": "anilist-trending",
                  "ocr": [],
                  "tags": [
                    {
                      "termId": "anilist:media:1",
                      "canonicalLabel": "Blue Archive",
                      "kind": "work",
                      "provenance": [],
                      "matchedAlias": "Blue Archive",
                      "evidenceLine": "BLUE ARCHIVE",
                      "mediaPath": "menu-1.jpg",
                      "score": 100
                    },
                    {
                      "termId": "source-a:fate",
                      "canonicalLabel": "Ｆａｔｅ",
                      "kind": "work",
                      "provenance": [],
                      "matchedAlias": "Ｆａｔｅ",
                      "evidenceLine": "Ｆａｔｅ",
                      "mediaPath": "menu-1.jpg",
                      "score": 100
                    }
                  ],
                  "futureField": {"isIgnored": true}
                }
              },
              {
                "tweet_id": "tagged-2",
                "tweet_url": "https://x.com/tagged/status/tagged-2",
                "text": "別のお品書き",
                "created_at": null,
                "author_handle": "tagged",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 10,
                    "wc_id": 1010,
                    "score": 80,
                    "reasons": []
                  }
                ],
                "enrichment": {
                  "schemaVersion": 2,
                  "tweetId": "tagged-2",
                  "ocr": [],
                  "tags": [
                    {
                      "termId": "anilist:media:1",
                      "canonicalLabel": "ブルーアーカイブ",
                      "kind": "future-work-kind",
                      "provenance": [
                        {
                          "sourceId": "anilist",
                          "recordId": "1",
                          "url": "https://anilist.co/anime/1"
                        }
                      ],
                      "matchedAlias": "ブルアカ",
                      "evidenceLine": "ブルアカ 新刊",
                      "mediaPath": "menu-2.jpg",
                      "score": 300
                    },
                    {
                      "termId": "source-b:fate",
                      "canonicalLabel": "Fate",
                      "kind": "work",
                      "provenance": [],
                      "matchedAlias": "Fate",
                      "evidenceLine": "Fate",
                      "mediaPath": "menu-2.jpg",
                      "score": 200
                    }
                  ]
                }
              }
            ]
            """.utf8
        )

        let index = try CatalogEnrichmentIndex(data: data)
        let enrichment = try XCTUnwrap(
            index.enrichment(circleID: 10, publicCircleID: 1010)
        )

        XCTAssertEqual(enrichment.posts.count, 2)
        XCTAssertTrue(enrichment.posts.allSatisfy(\.tags.isEmpty))
        XCTAssertTrue(enrichment.tags.isEmpty)
        XCTAssertTrue(enrichment.tagLabels.isEmpty)
        XCTAssertFalse(enrichment.searchableText.contains("ブルーアーカイブ"))
        XCTAssertFalse(enrichment.searchableText.contains("ブルアカ"))
        XCTAssertFalse(enrichment.searchableText.contains("Fate"))
        XCTAssertNil(
            index.enrichment(circleID: 20, publicCircleID: 2020),
            "Legacy post tags must not create an enrichment for a weaker placement match."
        )
    }

    func testPublicCircleIDPreventsSeedCircleIDCollision() throws {
        let data = Data(
            """
            [
              {
                "tweet_id": "public-match",
                "tweet_url": "https://x.com/public_match/status/1",
                "text": "Stable public match",
                "created_at": null,
                "author_handle": "public_match",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 77,
                    "wc_id": 1001,
                    "score": 80,
                    "reasons": []
                  }
                ]
              },
              {
                "tweet_id": "colliding-seed",
                "tweet_url": "https://x.com/colliding_seed/status/2",
                "text": "Same seed ID, different public circle",
                "created_at": null,
                "author_handle": "colliding_seed",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 77,
                    "wc_id": 2002,
                    "score": 80,
                    "reasons": []
                  }
                ]
              },
              {
                "tweet_id": "legacy-seed-only",
                "tweet_url": "https://x.com/legacy_seed/status/3",
                "text": "Legacy match without a public circle ID",
                "created_at": null,
                "author_handle": "legacy_seed",
                "author_name": null,
                "author": null,
                "media": [],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 88,
                    "score": 80,
                    "reasons": []
                  }
                ]
              }
            ]
            """.utf8
        )

        let index = try CatalogEnrichmentIndex(data: data)

        XCTAssertEqual(
            index.enrichment(circleID: 77, publicCircleID: 1001)?.posts.map(\.id),
            ["public-match"],
            "A stable public ID must not be combined with posts sharing only a seed-local ID."
        )
        XCTAssertNil(
            index.enrichment(circleID: 77, publicCircleID: nil),
            "Stable public matches must not be duplicated into the seed-ID fallback index."
        )
        XCTAssertEqual(
            index.enrichment(circleID: 88, publicCircleID: nil)?.primaryPost?.id,
            "legacy-seed-only",
            "A legacy match may use the seed ID only when no stable public ID exists."
        )
    }
}
