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
                  }
                ],
                "post_confidence": "high",
                "placement_confidence": "high",
                "matched_circles": [
                  {
                    "circle_id": 10,
                    "wc_id": 1010,
                    "score": 75,
                    "reasons": ["placement_in_post_or_profile"]
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

        let index = try CatalogEnrichmentIndex(data: data)

        XCTAssertEqual(index.selectedPostCount, 3)
        XCTAssertEqual(index.mappedPostCount, 2)
        XCTAssertEqual(index.mappedPublicCircleCount, 3)
        let strongest = try XCTUnwrap(
            index.enrichment(circleID: 999, publicCircleID: 1010)?.primaryPost
        )
        XCTAssertEqual(strongest.id, "100")
        XCTAssertEqual(strongest.authorHandle, "test_circle")
        XCTAssertEqual(strongest.media.first?.displayURL.absoluteString, "https://pbs.twimg.com/media/menu-small.jpg")
        XCTAssertTrue(strongest.isHighConfidence)
        XCTAssertEqual(index.enrichment(circleID: 999, publicCircleID: 1010)?.tagLabels, [])
        XCTAssertNil(index.enrichment(circleID: 20, publicCircleID: 2020))
        XCTAssertEqual(
            index.enrichment(circleID: 31, publicCircleID: nil)?.primaryPost?.id,
            "200",
            "The seed circle ID remains a crawl-mode fallback when a public ID is unavailable."
        )
    }

    func testEmbeddedTagsDecodeMergeDeterministicallyAndFollowStrongestCircleMatches() throws {
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
        XCTAssertEqual(enrichment.tags.map(\.canonicalLabel), ["Fate", "ブルーアーカイブ"])
        XCTAssertEqual(enrichment.tags.map(\.termID), ["source-b:fate", "anilist:media:1"])

        let blueArchive = try XCTUnwrap(
            enrichment.tags.first { $0.termID == "anilist:media:1" }
        )
        XCTAssertEqual(blueArchive.kind, "future-work-kind")
        XCTAssertEqual(blueArchive.matchedAlias, "ブルアカ")
        XCTAssertEqual(blueArchive.evidenceLine, "ブルアカ 新刊")
        XCTAssertEqual(blueArchive.provenance.first?.sourceID, "anilist")
        XCTAssertTrue(enrichment.searchableText.contains("ブルーアーカイブ"))
        XCTAssertNil(
            index.enrichment(circleID: 20, publicCircleID: 2020),
            "Tags must follow the same strongest placement match as their post."
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
        XCTAssertEqual(
            Set(index.enrichment(circleID: 77, publicCircleID: nil)?.posts.map(\.id) ?? []),
            ["public-match", "colliding-seed"],
            "The seed-local ID remains the fallback when no public ID is available."
        )
    }
}
