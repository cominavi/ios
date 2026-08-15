@testable import ComiNavi
import CryptoKit
import Observation
import XCTest

final class CominaviServiceClientTests: XCTestCase {
    func testGeneratedPushDeviceOperationsUseV2WireContract() async throws {
        let transport = PushDeviceTransportStub()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "service-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "service-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )

        try await client.registerPushToken(Data(repeating: 0xab, count: 32))
        try await client.disablePushDevice()

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertTrue(requests.allSatisfy {
            $0.url?.path.hasPrefix("/api/v2/me/devices/") == true
        })
        XCTAssertEqual(requests[0].url?.path, requests[1].url?.path)
        XCTAssertEqual(requests.map {
            $0.value(forHTTPHeaderField: "Authorization")
        }, ["Bearer service-access", "Bearer service-access"])
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(body["token"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertNotNil(body["bundleID"] as? String)
        XCTAssertNotNil(body["locale"] as? String)
        XCTAssertNotNil(body["timeZone"] as? String)
    }

    func testGeneratedCatalogOperationsAndStreamingAuthorizationUseV2Contract() async throws {
        let fixture = try fixtureObject(named: "sanitized-catalog-v1")
        let listData = try jsonData(fixture["catalogList"])
        let manifestData = try jsonData(fixture["catalogVersion"])
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/catalogs": (200, listData),
            "GET /api/v2/catalogs/108": (200, manifestData),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let catalogs = try await client.catalogs()
        let manifest = try await client.catalog(comiketNo: 108)
        let authorized = try await client.authorizedCatalogRequest(
            method: "GET",
            path: manifest.artifact.url,
            headers: [
                "Range": "bytes=128-",
                "If-Range": manifest.expectedETag,
            ],
            invalidatedAccessToken: nil
        )

        XCTAssertEqual(catalogs, [manifest])
        XCTAssertEqual(manifest.artifact.url, "/api/v2/catalogs/108/versions/c108-v1-aaaaaaaaaaaaaaaaaaaaaaaa/artifact")
        XCTAssertEqual(authorized.request.url?.path, manifest.artifact.url)
        XCTAssertEqual(authorized.request.httpMethod, "GET")
        XCTAssertEqual(authorized.request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(authorized.request.timeoutInterval, 120)
        XCTAssertEqual(authorized.request.value(forHTTPHeaderField: "Range"), "bytes=128-")
        XCTAssertEqual(authorized.request.value(forHTTPHeaderField: "If-Range"), manifest.expectedETag)
        XCTAssertEqual(
            authorized.request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )
        let catalogRequests = await transport.requests
        XCTAssertEqual(catalogRequests.map { $0.url?.path }, [
            "/api/v2/catalogs", "/api/v2/catalogs/108",
        ])
    }

    func testSynchronizesFavoritesAndReadsPublicRealtimeSnapshot() async throws {
        let transport = CominaviServiceTransportStub()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in
                try await transport.response(for: request)
            },
            circlemsEnvironmentProvider: { .production },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "service-jwt",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                authVersion: 1,
                refreshToken: String(repeating: "r", count: 43),
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: fixtureProfile(
                    id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    name: "Circle.ms利用者"
                )
            )),
            authenticationFlowCanceller: {}
        )
        let bookmark = MapBookmark(
            eventNumber: 108,
            publicCircleID: 23_000_001,
            catalogCircleID: 100,
            updateID: 100,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 1, spaceNumber: 1),
            subspace: 0,
            color: .magenta,
            memo: "",
            modifiedAt: Date(),
            syncState: .synced
        )

        let favoriteSnapshot = try await client.favoriteSnapshot(eventNumber: 108)
        _ = try await client.replaceFavorites(
            eventNumber: 108,
            baseRevision: favoriteSnapshot.revision,
            mutationID: UUID(),
            favorites: [CominaviFavorite(
                publicCircleID: bookmark.publicCircleID,
                color: bookmark.color,
                notificationsEnabled: true
            )]
        )
        let updatePage = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 40
        )
        try await client.revokeSession()

        XCTAssertEqual(updatePage.updates.first?.cursor, 41)
        XCTAssertEqual(updatePage.updates.first?.stateValue, "sold_out")
        XCTAssertFalse(updatePage.hasMore)
        let requests = await transport.requests()
        XCTAssertEqual(
            requests[2].url?.query,
            "afterCursor=40&publicationRevision=none"
        )
        XCTAssertEqual(requests[2].cachePolicy, .useProtocolCachePolicy)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/v2/me/favorites/108",
            "/api/v2/me/favorites/108",
            "/api/v2/events/108/updates",
            "/api/v2/auth/logout",
        ])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            [
                "Bearer service-jwt",
                "Bearer service-jwt",
                nil,
                "Bearer service-jwt",
            ]
        )
        let mutation = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mutation) as? [String: Any]
        )
        let favorites = try XCTUnwrap(object["favorites"] as? [[String: Any]])
        XCTAssertEqual(favorites.first?["wcID"] as? Int, 23_000_001)
        XCTAssertEqual(favorites.first?["color"] as? Int, BookmarkColor.magenta.rawValue)
        XCTAssertEqual(favorites.first?["notificationsEnabled"] as? Bool, true)
    }

    func testRealtimeSnapshotDecodesAndValidatesCuratedTagOverlay() async throws {
        let overlay = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "character.hatsune-miku",
                    label: "初音ミク",
                    kind: .character
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["character.hatsune-miku"]
                ),
            ]
        )
        let response = try realtimeResponse(
            tagOverlay: overlay,
            tagOverlayStatus: .current
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 0,
            tagRevision: CominaviCircleTagOverlay.absentRevision
        )

        XCTAssertEqual(page.tagOverlay, overlay)
        XCTAssertEqual(page.tagOverlayStatus, .current)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.first?.url?.query,
            "afterCursor=0&publicationRevision=none&tagRevision=none"
        )
    }

    func testRealtimeSnapshotAcceptsPublicationResetWithHistoricalBaselineCursors()
        async throws
    {
        let revision = String(repeating: "b", count: 64)
        let response = try realtimeResponse(
            tagOverlay: nil,
            publicationRevision: revision,
            publicationGeneration: 2,
            publicationCursor: 10,
            resetRequired: true,
            updates: [
                realtimeUpdateObject(
                    cursor: 10,
                    stateKind: "attendance",
                    stateValue: "absent"
                ),
                realtimeUpdateObject(
                    cursor: 10,
                    stateKind: "shinagaki",
                    stateValue: "published"
                ),
            ]
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 0,
            publicationRevision: CominaviRealtimeUpdatePage.absentPublicationRevision,
            tagRevision: nil
        )

        XCTAssertTrue(page.resetRequired)
        XCTAssertEqual(page.publicationRevision, revision)
        XCTAssertEqual(page.updates.map(\.cursor), [10, 10])
    }

    func testRealtimeSnapshotAcceptsZeroCursorForFreshPublicationReset()
        async throws
    {
        let revision = String(repeating: "d", count: 64)
        let response = try realtimeResponse(
            tagOverlay: nil,
            publicationRevision: revision,
            publicationGeneration: 1,
            publicationCursor: 0,
            resetRequired: true,
            updates: [realtimeUpdateObject(
                cursor: 0,
                stateKind: "shinagaki",
                stateValue: "published"
            )]
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 0,
            publicationRevision: CominaviRealtimeUpdatePage.absentPublicationRevision,
            tagRevision: nil
        )

        XCTAssertTrue(page.resetRequired)
        XCTAssertEqual(page.publicationCursor, 0)
        XCTAssertEqual(page.updates.map(\.cursor), [0])
    }

    func testRealtimeSnapshotRejectsZeroCursorForIncrementalPage() async throws {
        let response = try realtimeResponse(
            tagOverlay: nil,
            updates: [realtimeUpdateObject(
                cursor: 0,
                stateKind: "shinagaki",
                stateValue: "published"
            )]
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.realtimeUpdates(
                eventNumber: 108,
                afterCursor: 0,
                publicationRevision: CominaviRealtimeUpdatePage.absentPublicationRevision,
                tagRevision: nil
            )
            XCTFail("An incremental update must advance beyond the current cursor")
        } catch CominaviServiceError.invalidResponse {}
    }

    func testRealtimeSnapshotRejectsResetBaselineThatDoesNotReachPublicationCursor()
        async throws
    {
        let response = try realtimeResponse(
            tagOverlay: nil,
            publicationRevision: String(repeating: "c", count: 64),
            publicationGeneration: 2,
            publicationCursor: 10,
            resetRequired: true,
            updates: [realtimeUpdateObject(
                cursor: 2,
                stateKind: "attendance",
                stateValue: "absent"
            )]
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.realtimeUpdates(
                eventNumber: 108,
                afterCursor: 0,
                publicationRevision: CominaviRealtimeUpdatePage.absentPublicationRevision,
                tagRevision: nil
            )
            XCTFail("A reset response must not contain cursors before publicationCursor")
        } catch CominaviServiceError.invalidResponse {}
    }

    func testRealtimeSnapshotRejectsSemanticallyInvalidTagOverlay() async throws {
        let unsorted = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(id: "work.z", label: "Z", kind: .work),
                CominaviCircleTagTerm(id: "work.a", label: "A", kind: .work),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["work.a", "work.z"]
                ),
            ]
        )
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (
                200,
                try realtimeResponse(
                    tagOverlay: unsorted,
                    tagOverlayStatus: .current
                )
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.realtimeUpdates(
                eventNumber: 108,
                afterCursor: 0,
                tagRevision: CominaviCircleTagOverlay.absentRevision
            )
            XCTFail("Unsorted overlay terms must be rejected")
        } catch CominaviServiceError.invalidResponse {}
    }

    func testRealtimeSnapshotDecodesAbsentTagOverlayStatus() async throws {
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (
                200,
                try realtimeResponse(tagOverlay: nil, tagOverlayStatus: .absent)
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 0,
            tagRevision: CominaviCircleTagOverlay.absentRevision
        )

        XCTAssertNil(page.tagOverlay)
        XCTAssertEqual(page.tagOverlayStatus, .absent)
    }

    func testRealtimeSnapshotSendsCanonicalRevisionAndAcceptsUnchangedCurrentStatus() async throws {
        let revision = String(repeating: "a", count: 64)
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (
                200,
                try realtimeResponse(tagOverlay: nil, tagOverlayStatus: .current)
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 40,
            tagRevision: revision
        )

        XCTAssertNil(page.tagOverlay)
        XCTAssertEqual(page.tagOverlayStatus, .current)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.first?.url?.query,
            "afterCursor=40&publicationRevision=none&tagRevision=\(revision)"
        )
    }

    func testRealtimeSnapshotRejectsMissingStatusForTagAwareRequest() async throws {
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (
                200,
                try realtimeResponse(tagOverlay: nil)
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.realtimeUpdates(
                eventNumber: 108,
                afterCursor: 0,
                tagRevision: CominaviCircleTagOverlay.absentRevision
            )
            XCTFail("A tag-aware response must include its authority status")
        } catch CominaviServiceError.invalidResponse {}
    }

    func testLegacyRealtimeSnapshotRejectsUnexpectedTagAuthorityFields() async throws {
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/events/108/updates": (
                200,
                try realtimeResponse(tagOverlay: nil, tagOverlayStatus: .unavailable)
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.realtimeUpdates(eventNumber: 108, afterCursor: 0)
            XCTFail("Legacy responses must remain wire-identical")
        } catch CominaviServiceError.invalidResponse {}
    }

    func testTagOverlayRevisionMatchesBackendCanonicalFixture() throws {
        let overlay = CominaviCircleTagOverlay(
            schemaVersion: 1,
            revision: "6e08e047e6306d2f51a3db7c03675c603a13db8550387ed0fa8488af003d3ef5",
            catalogPayloadSHA256: "8ba603" + String(repeating: "0", count: 58),
            taxonomyRevision: "cominavi-c108-v1",
            matchingPolicyRevision: "keyword-evidence-v1",
            evaluatedCircleCount: 22_854,
            taggedCircleCount: 2,
            terms: [
                CominaviCircleTagTerm(
                    id: "character.hatsune_miku",
                    label: "初音ミク",
                    kind: .character
                ),
                CominaviCircleTagTerm(id: "content.bl", label: "BL", kind: .content),
                CominaviCircleTagTerm(id: "content.r18", label: "R-18", kind: .content),
                CominaviCircleTagTerm(id: "theme.yuri", label: "百合", kind: .theme),
                CominaviCircleTagTerm(
                    id: "work.arknights",
                    label: "アークナイツ",
                    kind: .work
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 101,
                    tagIDs: ["content.r18", "work.arknights"]
                ),
                CominaviCircleTagAssignment(
                    wcID: 202,
                    tagIDs: [
                        "character.hatsune_miku",
                        "content.bl",
                        "theme.yuri",
                    ]
                ),
            ]
        )

        XCTAssertEqual(overlay.semanticRevision, overlay.revision)
        XCTAssertNoThrow(try overlay.validate())
    }

    func testTagOverlayRejectsBlankLabels() {
        let overlay = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(id: "content.r18", label: " \n ", kind: .content),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )

        XCTAssertThrowsError(try overlay.validate())
    }

    func testTagOverlayRejectsControlCharactersInLabels() {
        let overlay = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "content.r18",
                    label: "R-18\u{007f}",
                    kind: .content
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(wcID: 23_000_001, tagIDs: ["content.r18"]),
            ]
        )

        XCTAssertThrowsError(try overlay.validate())
    }

    func testTagOverlayLabelLimitCountsUnicodeScalars() {
        let accepted = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "character.non_bmp_boundary",
                    label: String(repeating: "😀", count: 200),
                    kind: .character
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["character.non_bmp_boundary"]
                ),
            ]
        )
        let rejected = makeTagOverlay(
            terms: [
                CominaviCircleTagTerm(
                    id: "character.non_bmp_boundary",
                    label: String(repeating: "😀", count: 201),
                    kind: .character
                ),
            ],
            circles: [
                CominaviCircleTagAssignment(
                    wcID: 23_000_001,
                    tagIDs: ["character.non_bmp_boundary"]
                ),
            ]
        )

        XCTAssertNoThrow(try accepted.validate())
        XCTAssertThrowsError(try rejected.validate())
    }

    private func makeTagOverlay(
        terms: [CominaviCircleTagTerm],
        circles: [CominaviCircleTagAssignment]
    ) -> CominaviCircleTagOverlay {
        let unsigned = CominaviCircleTagOverlay(
            schemaVersion: 1,
            revision: String(repeating: "0", count: 64),
            catalogPayloadSHA256: String(repeating: "b", count: 64),
            taxonomyRevision: "cominavi-circle-tags-v1",
            matchingPolicyRevision: "precision-v1",
            evaluatedCircleCount: 22_854,
            taggedCircleCount: circles.count,
            terms: terms,
            circles: circles
        )
        return CominaviCircleTagOverlay(
            schemaVersion: unsigned.schemaVersion,
            revision: unsigned.semanticRevision,
            catalogPayloadSHA256: unsigned.catalogPayloadSHA256,
            taxonomyRevision: unsigned.taxonomyRevision,
            matchingPolicyRevision: unsigned.matchingPolicyRevision,
            evaluatedCircleCount: unsigned.evaluatedCircleCount,
            taggedCircleCount: unsigned.taggedCircleCount,
            terms: unsigned.terms,
            circles: unsigned.circles
        )
    }

    private func realtimeResponse(
        tagOverlay: CominaviCircleTagOverlay?,
        tagOverlayStatus: CominaviRealtimeUpdatePage.TagOverlayStatus? = nil,
        publicationRevision: String = CominaviRealtimeUpdatePage.absentPublicationRevision,
        publicationGeneration: Int = 0,
        publicationCursor: Int = 0,
        resetRequired: Bool = false,
        updates: [[String: Any]] = []
    ) throws -> Data {
        var object: [String: Any] = [
            "eventNumber": 108,
            "hasMore": false,
            "publicationRevision": publicationRevision,
            "publicationGeneration": publicationGeneration,
            "publicationCursor": publicationCursor,
            "resetRequired": resetRequired,
            "updates": updates,
        ]
        if let tagOverlay {
            object["tagOverlay"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(tagOverlay)
            )
        }
        if let tagOverlayStatus {
            object["tagOverlayStatus"] = tagOverlayStatus.rawValue
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func realtimeUpdateObject(
        cursor: Int,
        stateKind: String,
        stateValue: String
    ) -> [String: Any] {
        [
            "cursor": cursor,
            "eventKey": "twitterapi:\(cursor):\(stateKind):\(stateValue)",
            "updateKind": stateKind == "shinagaki"
                ? "shinagaki_published"
                : "attendance_absent",
            "stateKind": stateKind,
            "stateValue": stateValue,
            "confidence": "high",
            "occurredAt": "2026-08-15T03:00:00Z",
            "sourceRevision": 1,
            "post": [
                "id": "post-\(cursor)",
                "url": "https://x.com/circle/status/\(cursor)",
                "text": "update \(stateValue)",
                "author": [
                    "xUserID": "9",
                    "handle": "circle",
                    "name": "Circle",
                    "profileImageURL": NSNull(),
                ],
                "media": [],
            ],
            "circles": [[
                "eventNumber": 108,
                "wcID": 23_000_001,
                "circleID": 100,
                "circleName": "Circle",
                "day": 1,
                "areaName": "西",
                "blockName": "ア",
                "spaceNo": 1,
                "spaceNoSub": 0,
                "location": "1日目 西 ア01a",
            ]],
        ]
    }

    func testFrozenDirectProfileFixtureDecodesProviderContextAndRelativeAvatar() async throws {
        let fixture = try fixtureData(named: "profile-v1")
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/me": (200, fixture),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let profile = try await client.fetchProfile()

        XCTAssertEqual(profile.id, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(profile.revision, 3)
        XCTAssertEqual(profile.avatarURL?.relativeString, "/api/v2/users/0123456789abcdef0123456789abcdef/avatar")
        XCTAssertEqual(profile.identities[0].provider, "google")
        XCTAssertEqual(profile.identities[0].email, "fixture@example.com")
        XCTAssertEqual(profile.identities[1].environment, "production")
        XCTAssertEqual(profile.identities[1].providerUserID, "42")
    }

    func testAvatarMutationsUseRawProfileRevisionWireContract() async throws {
        let jpeg = Data([
            0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10,
            0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
        ])
        let uploadResponse = Data(#"""
        {
            "user": {
                "id": "0123456789abcdef0123456789abcdef",
                "displayName": "Galvin",
                "avatarURL": "/api/v2/users/0123456789abcdef0123456789abcdef/avatar",
                "revision": 4,
                "identities": []
            }
        }
        """#.utf8)
        let deleteResponse = Data(#"""
        {
            "user": {
                "id": "0123456789abcdef0123456789abcdef",
                "displayName": "Galvin",
                "revision": 5,
                "identities": []
            }
        }
        """#.utf8)
        let transport = StaticCominaviTransport(responses: [
            "PUT /api/v2/me/avatar": (200, uploadResponse),
            "DELETE /api/v2/me/avatar": (200, deleteResponse),
        ])
        let client = try makeAuthenticatedClient(transport: transport)
        let requestID = try XCTUnwrap(UUID(
            uuidString: "33333333-3333-4333-8333-333333333333"
        ))
        let deleteRequestID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ))

        _ = try await client.uploadAvatar(
            jpeg,
            contentType: "image/jpeg",
            baseRevision: 3,
            requestID: requestID
        )
        _ = try await client.deleteAvatar(
            baseRevision: 4,
            requestID: deleteRequestID
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/v2/me/avatar" })
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Length"), "12")
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "If-Match") },
            [#""profile:3""#, #""profile:4""#]
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Idempotency-Key"),
            requestID.uuidString.lowercased()
        )
        XCTAssertEqual(requests[0].httpBody, jpeg)
        XCTAssertNil(requests[1].httpBody)
    }

    func testFrozenAuthProviderFixtureDecodesAndSendsExactLogoutContract() async throws {
        let fixture = try fixtureObject(named: "auth-providers-v1")
        let circlems = try XCTUnwrap(fixture["circlems"] as? [String: Any])
        let logout = try XCTUnwrap(fixture["logout"] as? [String: Any])
        let requestObject = try XCTUnwrap(logout["request"] as? [String: Any])
        let responseData = try jsonData(logout["response"])
        let authenticationData = try jsonData(circlems["authCompleteResponse"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let authentication = try decoder.decode(
            CominaviAuthenticationSession.self,
            from: authenticationData
        )
        let requestIDString = try XCTUnwrap(requestObject["requestId"] as? String)
        let requestID = try XCTUnwrap(UUID(uuidString: requestIDString))
        let profile = try XCTUnwrap(authentication.user)
        let store = MutableCominaviSessionStore(
            session: authentication,
            boundUserID: profile.id
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/logout": (200, responseData),
        ])
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeLogoutRequestID: { requestID }
        )

        try await client.revokeSession()

        XCTAssertEqual(authentication.authVersion, 1)
        XCTAssertEqual(authentication.refreshToken?.utf8.count, 43)
        XCTAssertNil(store.pendingLogout)
        XCTAssertNil(store.session)
        XCTAssertNil(store.boundUserID)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-cominavi-access-token"
        )
        XCTAssertEqual(requests[0].httpBody, try jsonData(requestObject))
    }

    func testFrozenPlanRESTFixtureDrivesListCreatePreviewAndAccept() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        let create = try jsonData(fixture["create"])
        let list = try jsonData(fixture["list"])
        let preview = try jsonData(fixture["preview"])
        let accept = try jsonData(fixture["accept"])
        let token = "Abcdef12_-XY"
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/plans": (200, list),
            "POST /api/v2/plans": (201, create),
            "GET /api/v2/invitations/\(token)": (200, preview),
            "POST /api/v2/invitations/\(token)/accept": (200, accept),
        ])
        let client = try makeAuthenticatedClient(transport: transport)
        let createRequestID = try XCTUnwrap(UUID(
            uuidString: "11111111-1111-4111-8111-111111111112"
        ))
        let acceptRequestID = try XCTUnwrap(UUID(
            uuidString: "11111111-1111-4111-8111-111111111113"
        ))

        let plans = try await client.fetchPlans()
        XCTAssertTrue(plans.isEmpty)
        let created = try await client.createPlan(
            requestID: createRequestID,
            name: "買い物リスト",
            comiketNo: 108
        )
        XCTAssertEqual(created.plan.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(created.receipt.resultRevision, 1)
        let bootstrap = try XCTUnwrap(created.syncBootstrap)
        let bytes = try XCTUnwrap(Data(base64URLString: bootstrap.document))
        let document = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        XCTAssertEqual(document.planID, created.plan.id)
        XCTAssertEqual(document.comiketNo, 108)

        let invitation = try await client.previewInvitation(token: token)
        XCTAssertEqual(invitation.planID, created.plan.id)
        let accepted = try await client.acceptInvitation(
            token: token,
            requestID: acceptRequestID
        )
        XCTAssertEqual(accepted.plan.role, .editor)
        XCTAssertEqual(accepted.receipt.resultStatus, .active)

        let requests = await transport.requests
        let bodies = try requests.compactMap(\.httpBody).map {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: $0) as? [String: Any]
            )
        }
        XCTAssertTrue(bodies.contains {
            $0["requestId"] as? String
                == "11111111-1111-4111-8111-111111111112"
        })
        XCTAssertTrue(bodies.contains {
            $0["requestId"] as? String
                == "11111111-1111-4111-8111-111111111113"
        })
    }

    func testGeneratedPlanDetailMutationsSnapshotAndWebSocketUseV2WireContract() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        let create = try XCTUnwrap(fixture["create"] as? [String: Any])
        let basePlan = try XCTUnwrap(create["plan"] as? [String: Any])
        let snapshot = try jsonData(create["syncBootstrap"])
        let planID = "11111111-1111-4111-8111-111111111111"
        let renameID = try XCTUnwrap(UUID(
            uuidString: "66666666-6666-4666-8666-666666666661"
        ))
        let archiveID = try XCTUnwrap(UUID(
            uuidString: "66666666-6666-4666-8666-666666666662"
        ))
        let reopenID = try XCTUnwrap(UUID(
            uuidString: "66666666-6666-4666-8666-666666666663"
        ))

        func mutationResponse(
            requestID: UUID,
            revision: Int,
            name: String,
            status: String
        ) throws -> Data {
            var plan = basePlan
            plan["name"] = name
            plan["status"] = status
            plan["revision"] = revision
            return try jsonData([
                "plan": plan,
                "receipt": [
                    "requestId": requestID.uuidString.lowercased(),
                    "replayed": false,
                    "resultRevision": revision,
                    "resultStatus": status,
                ],
            ])
        }

        let detailTransport = StaticCominaviTransport(responses: [
            "GET /api/v2/plans/\(planID)": (
                200,
                try jsonData(["plan": basePlan])
            ),
        ])
        let detailClient = try makeAuthenticatedClient(transport: detailTransport)
        let fetchedPlan = try await detailClient.fetchPlan(id: planID)
        XCTAssertEqual(fetchedPlan.id, planID)

        let renameTransport = StaticCominaviTransport(responses: [
            "PATCH /api/v2/plans/\(planID)": (
                200,
                try mutationResponse(
                    requestID: renameID,
                    revision: 2,
                    name: "改名後",
                    status: "active"
                )
            ),
        ])
        let renameClient = try makeAuthenticatedClient(transport: renameTransport)
        let renamedPlan = try await renameClient.renamePlan(
            id: planID,
            requestID: renameID,
            baseRevision: 1,
            name: "改名後"
        )
        XCTAssertEqual(renamedPlan.plan.name, "改名後")

        let archiveTransport = StaticCominaviTransport(responses: [
            "DELETE /api/v2/plans/\(planID)": (
                200,
                try mutationResponse(
                    requestID: archiveID,
                    revision: 3,
                    name: "改名後",
                    status: "archived"
                )
            ),
        ])
        let archiveClient = try makeAuthenticatedClient(transport: archiveTransport)
        let archivedPlan = try await archiveClient.archivePlan(
            id: planID,
            requestID: archiveID,
            baseRevision: 2
        )
        XCTAssertEqual(archivedPlan.plan.lifecycle, .archived)

        let reopenTransport = StaticCominaviTransport(responses: [
            "PATCH /api/v2/plans/\(planID)": (
                200,
                try mutationResponse(
                    requestID: reopenID,
                    revision: 4,
                    name: "改名後",
                    status: "active"
                )
            ),
            "GET /api/v2/plans/\(planID)/sync": (200, snapshot),
        ])
        let reopenClient = try makeAuthenticatedClient(transport: reopenTransport)
        let reopenedPlan = try await reopenClient.reopenPlan(
            id: planID,
            requestID: reopenID,
            baseRevision: 3
        )
        XCTAssertEqual(reopenedPlan.plan.lifecycle, .active)
        let syncBootstrap = try await reopenClient.fetchSyncBootstrap(planID: planID)
        XCTAssertFalse(syncBootstrap.heads.isEmpty)
        let webSocket = try await reopenClient.sharedPlanSyncWebSocketRequest(planID: planID)
        XCTAssertEqual(webSocket.url?.scheme, "wss")
        XCTAssertEqual(webSocket.url?.path, "/api/v2/plans/\(planID)/sync")
        XCTAssertEqual(
            webSocket.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )

        let renameRequests = await renameTransport.requests
        let renameRequest = try XCTUnwrap(renameRequests.first)
        let renameBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(renameRequest.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(renameRequest.url?.path, "/api/v2/plans/\(planID)")
        XCTAssertEqual(renameBody["baseRevision"] as? Int, 1)
        XCTAssertEqual(renameBody["name"] as? String, "改名後")
        XCTAssertNil(renameBody["archived"])

        let reopenRequests = await reopenTransport.requests
        let reopenRequest = try XCTUnwrap(reopenRequests.first)
        let reopenBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(reopenRequest.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(reopenBody["archived"] as? Bool, false)
        XCTAssertNil(reopenBody["name"])
    }

    func testFrozenSharedPlanAndNotificationFixturesHaveCanonicalDigests() throws {
        let planDigest = SHA256.hash(data: try fixtureData(named: "shared-plan-rest-v1"))
            .map { String(format: "%02x", $0) }
            .joined()
        let notificationDigest = SHA256.hash(
            data: try fixtureData(named: "notification-inbox-v1")
        )
        .map { String(format: "%02x", $0) }
        .joined()

        XCTAssertEqual(
            planDigest,
            "509eaa16e3158e89d2b4be086d6356b37905c0e265cec6320f80d84db45bdbc5"
        )
        XCTAssertEqual(
            notificationDigest,
            "5ab99e55ab6d406ce6782fe6360845e21b63b8caca7dbc0a04a5663c58478701"
        )
    }

    func testFrozenAdministrativePlanRoutesDecodeAndSerializeLiteralContracts() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        let members = try XCTUnwrap(fixture["members"] as? [String: Any])
        let firstMembers = try XCTUnwrap(members["firstPage"] as? [String: Any])
        let revocation = try XCTUnwrap(fixture["memberRevocation"] as? [String: Any])
        let reinstatement = try XCTUnwrap(
            fixture["memberReinstatement"] as? [String: Any]
        )
        let transfer = try XCTUnwrap(fixture["ownershipTransfer"] as? [String: Any])
        let invitations = try XCTUnwrap(fixture["invitations"] as? [String: Any])
        let invitationList = try XCTUnwrap(
            invitations["listAsOwner"] as? [String: Any]
        )
        let invitationCreate = try XCTUnwrap(invitations["create"] as? [String: Any])
        let invitationRevoke = try XCTUnwrap(invitations["revoke"] as? [String: Any])
        let planID = "11111111-1111-4111-8111-111111111111"
        let editorID = "00000000000000000000000000000002"
        let invitationID = "55555555-5555-4555-8555-555555555555"
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/plans/\(planID)/members": (
                200,
                try jsonData(firstMembers["response"])
            ),
            "DELETE /api/v2/plans/\(planID)/members/\(editorID)": (
                200,
                try jsonData(revocation["response"])
            ),
            "POST /api/v2/plans/\(planID)/members/\(editorID)/reinstate": (
                200,
                try jsonData(reinstatement["response"])
            ),
            "POST /api/v2/plans/\(planID)/transfer-ownership": (
                200,
                try jsonData(transfer["response"])
            ),
            "GET /api/v2/plans/\(planID)/invitations": (
                200,
                try jsonData(invitationList["response"])
            ),
            "POST /api/v2/plans/\(planID)/invitations": (
                201,
                try jsonData(invitationCreate["response"])
            ),
            "DELETE /api/v2/plans/\(planID)/invitations/\(invitationID)": (
                200,
                try jsonData(invitationRevoke["response"])
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)
        let revokeRequestID = try XCTUnwrap(UUID(
            uuidString: "22222222-2222-4222-8222-222222222221"
        ))
        let reinstateRequestID = try XCTUnwrap(UUID(
            uuidString: "22222222-2222-4222-8222-222222222222"
        ))
        let transferRequestID = try XCTUnwrap(UUID(
            uuidString: "33333333-3333-4333-8333-333333333331"
        ))
        let createRequestID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444441"
        ))
        let revokeInvitationRequestID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444442"
        ))
        let expiresAt = try fixtureDate("2026-08-16T12:13:00.000Z")

        let memberPage = try await client.fetchMembers(planID: planID, limit: 1, cursor: nil)
        XCTAssertEqual(memberPage.items.first?.membershipStatus, .active)
        XCTAssertEqual(memberPage.items.first?.role, .owner)
        XCTAssertNotNil(memberPage.nextCursor)
        let revoked = try await client.revokeMember(
            planID: planID,
            userID: editorID,
            requestID: revokeRequestID,
            baseRevision: 1
        )
        XCTAssertEqual(revoked.receipt.resultRevision, 2)
        let reinstated = try await client.reinstateMember(
            planID: planID,
            userID: editorID,
            requestID: reinstateRequestID,
            baseRevision: 2
        )
        XCTAssertEqual(reinstated.receipt.resultRevision, 3)
        let transferred = try await client.transferOwnership(
            planID: planID,
            newOwnerUserID: editorID,
            requestID: transferRequestID,
            baseRevision: 3
        )
        XCTAssertEqual(transferred.plan.role, .editor)
        let invitationPage = try await client.fetchInvitations(
            planID: planID,
            limit: 50,
            cursor: nil
        )
        XCTAssertEqual(invitationPage.items.count, 2)
        XCTAssertTrue(invitationPage.items.allSatisfy(\.currentUserCanRevoke))
        let created = try await client.createInvitation(
            planID: planID,
            requestID: createRequestID,
            baseRevision: 4,
            expiresAt: expiresAt
        )
        XCTAssertEqual(created.invitationID, invitationID)
        XCTAssertEqual(created.token, "AQEBAQEBAQEB")
        XCTAssertEqual(created.receipt.resultRevision, 5)
        let revokedInvitation = try await client.revokeInvitation(
            planID: planID,
            invitationID: invitationID,
            requestID: revokeInvitationRequestID,
            baseRevision: 5
        )
        XCTAssertEqual(revokedInvitation.receipt.resultRevision, 6)

        let requests = await transport.requests
        let firstComponents = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(requests.first?.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(
            firstComponents.percentEncodedPath,
            "/api/v2/plans/\(planID)/members"
        )
        XCTAssertEqual(firstComponents.percentEncodedQuery, "limit=1")
        let expectedBodies: [String: Any] = [
            "DELETE /api/v2/plans/\(planID)/members/\(editorID)": revocation["request"] as Any,
            "POST /api/v2/plans/\(planID)/members/\(editorID)/reinstate": reinstatement["request"] as Any,
            "POST /api/v2/plans/\(planID)/transfer-ownership": transfer["request"] as Any,
            "POST /api/v2/plans/\(planID)/invitations": invitationCreate["request"] as Any,
            "DELETE /api/v2/plans/\(planID)/invitations/\(invitationID)": invitationRevoke["request"] as Any,
        ]
        for request in requests where request.httpBody != nil {
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            let requestFixture = try XCTUnwrap(expectedBodies[key] as? [String: Any])
            let expected = try XCTUnwrap(requestFixture["body"])
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary,
                expected as? NSDictionary,
                key
            )
        }
    }

    func testFrozenNextMemberPagePreservesOpaqueCursor() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        let members = try XCTUnwrap(fixture["members"] as? [String: Any])
        let first = try XCTUnwrap(members["firstPage"] as? [String: Any])
        let next = try XCTUnwrap(members["nextPage"] as? [String: Any])
        let firstResponse = try XCTUnwrap(first["response"] as? [String: Any])
        let cursor = try XCTUnwrap(firstResponse["nextCursor"] as? String)
        let planID = "11111111-1111-4111-8111-111111111111"
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/plans/\(planID)/members": (200, try jsonData(next["response"])),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.fetchMembers(planID: planID, limit: 1, cursor: cursor)

        XCTAssertEqual(page.items.first?.userID, "00000000000000000000000000000002")
        XCTAssertNil(page.nextCursor)
        let recordedRequests = await transport.requests
        let request = try XCTUnwrap(recordedRequests.first)
        let queryItems = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems)
        XCTAssertEqual(queryItems.first(where: { $0.name == "cursor" })?.value, cursor)
    }

    func testFrozenInvitationReplayAndOwnerErrorsRemainTyped() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        let invitations = try XCTUnwrap(fixture["invitations"] as? [String: Any])
        let creation = try XCTUnwrap(invitations["create"] as? [String: Any])
        let errors = try XCTUnwrap(fixture["errors"] as? [String: Any])
        let ownerError = try XCTUnwrap(errors["ownerRequired"] as? [String: Any])
        let planID = "11111111-1111-4111-8111-111111111111"
        let editorID = "00000000000000000000000000000002"
        let requestID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444441"
        ))
        let expiresAt = try fixtureDate("2026-08-16T12:13:00.000Z")
        let replayTransport = StaticCominaviTransport(responses: [
            "POST /api/v2/plans/\(planID)/invitations": (
                try XCTUnwrap(creation["lostResponseReplayHTTPStatus"] as? Int),
                try jsonData(creation["lostResponseReplay"])
            ),
        ])
        let replayClient = try makeAuthenticatedClient(transport: replayTransport)

        do {
            _ = try await replayClient.createInvitation(
                planID: planID,
                requestID: requestID,
                baseRevision: 4,
                expiresAt: expiresAt
            )
            XCTFail("A replay cannot reveal a previously returned capability")
        } catch let CominaviServiceError.invitationTokenAlreadyReturned(
            message,
            invitationID
        ) {
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(invitationID, "55555555-5555-4555-8555-555555555555")
        }

        let ownerTransport = StaticCominaviTransport(responses: [
            "DELETE /api/v2/plans/\(planID)/members/\(editorID)": (
                try XCTUnwrap(ownerError["httpStatus"] as? Int),
                try jsonData(ownerError["response"])
            ),
        ])
        let ownerClient = try makeAuthenticatedClient(transport: ownerTransport)
        do {
            _ = try await ownerClient.revokeMember(
                planID: planID,
                userID: editorID,
                requestID: UUID(),
                baseRevision: 6
            )
            XCTFail("Editor authority must not be treated as an untyped server error")
        } catch let CominaviServiceError.planOwnerRequired(code, message) {
            XCTAssertEqual(code, "plan_owner_required")
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testFrozenNotificationListAndBodylessMonotonicReadContract() async throws {
        let fixture = try fixtureObject(named: "notification-inbox-v1")
        let list = try XCTUnwrap(fixture["list"] as? [String: Any])
        let read = try XCTUnwrap(fixture["read"] as? [String: Any])
        let eventID = String(repeating: "f", count: 64)
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/me/notifications": (200, try jsonData(list["response"])),
            "PUT /api/v2/me/notifications/\(eventID)/read": (
                200,
                try jsonData(read["response"])
            ),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.fetchNotifications(limit: 2, cursor: nil)
        XCTAssertEqual(page.items.count, 2)
        guard case .operation(let operation) = page.items[0].payload else {
            return XCTFail("The operation event must remain typed")
        }
        XCTAssertEqual(operation.operationType, .circleMemoSplice)
        guard case .conflict(let conflict) = page.items[1].payload else {
            return XCTFail("The conflict event must remain typed")
        }
        XCTAssertEqual(conflict.path.last, "wantedQuantity")
        let first = try await client.markNotificationRead(id: eventID)
        let replay = try await client.markNotificationRead(id: eventID)
        XCTAssertEqual(first, replay)

        let requests = await transport.requests
        let listComponents = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(requests[0].url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(listComponents.percentEncodedQuery, "limit=2")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(requests[1].httpBody)
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertNil(requests[2].httpBody)
        XCTAssertEqual(requests[1].url?.path, requests[2].url?.path)
    }

    func testCirclemsFavoriteImportUsesProtectedSanitizedCursorContract() async throws {
        let body = try jsonData([
            "eventNumber": 108,
            "items": [[
                "wcID": 23_000_001,
                "updateID": 100,
                "circleName": "サークルA",
                "color": 2,
                "memo": "確認メモ",
            ]],
            "nextCursor": "opaque-cursor",
        ])
        let transport = StaticCominaviTransport(responses: [
            "GET /api/v2/me/circlems-favorites/108": (200, body),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let page = try await client.circlemsFavoriteImportPage(
            eventNumber: 108,
            cursor: "prior cursor"
        )

        XCTAssertEqual(page.items.first?.wcID, 23_000_001)
        XCTAssertEqual(page.items.first?.circleName, "サークルA")
        XCTAssertEqual(page.nextCursor, "opaque-cursor")
        let requests = await transport.requests
        let components = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(requests.first?.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.path, "/api/v2/me/circlems-favorites/108")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "cursor", value: "prior cursor"),
        ])
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )
    }

    func testManualCirclemsFavoriteSyncUsesProtectedServerEndpoint() async throws {
        let body = try jsonData([
            "eventNumber": 108,
            "revision": 7,
            "favoriteCount": 3,
            "addedCount": 1,
            "updatedCount": 1,
            "unchangedCount": 1,
            "skippedMemoOnlyCount": 0,
        ])
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/me/circlems-favorites/108/sync": (200, body),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let result = try await client.syncCirclemsFavorites(eventNumber: 108)

        XCTAssertEqual(result.eventNumber, 108)
        XCTAssertEqual(result.revision, 7)
        XCTAssertEqual(result.favoriteCount, 3)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.unchangedCount, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.url?.path,
            "/api/v2/me/circlems-favorites/108/sync"
        )
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )
    }

    func testGeneratedXFollowingImportUsesServiceSessionAndMapsDomainPayload() async throws {
        let response = Data(
            #"{"twitterUserName":"cominavi","importedAt":"2026-08-11T08:00:00Z","nextAllowedAt":"2026-08-11T09:00:00Z","followings":[{"id":"42","userName":"circle","name":"Circle","url":"https://x.com/circle","profilePicture":null}],"source":"cache"}"#.utf8
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/imports/x-followings": (200, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        let payload = try await client.importXFollowings(userName: "cominavi")

        XCTAssertEqual(payload.twitterUserName, "cominavi")
        XCTAssertEqual(payload.source, .cache)
        XCTAssertEqual(payload.followings.first?.url.absoluteString, "https://x.com/circle")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].timeoutInterval, 10 * 60)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )
        let body = try XCTUnwrap(requests[0].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["userName"] as? String, "cominavi")
    }

    func testStreamingXFollowingImportConsumesProgressAndCompletionEvents() async throws {
        let streamBody = Data(
            """
            :

            event: message
            data: {"page":1,"fetchedCount":1,"maximumCount":5000,"followings":[{"id":"x-1","userName":"circle","name":"Circle","url":"https://x.com/circle"}]}

            event: done
            data: {"twitterUserName":"cominavi","importedAt":"2026-08-11T08:00:00.000Z","nextAllowedAt":"2026-08-11T14:00:00.000Z","followings":[{"id":"x-1","userName":"circle","name":"Circle","url":"https://x.com/circle"}],"source":"twitterapi.io"}

            """.utf8
        )
        let streamingTransport = StaticCominaviStreamingTransport(
            status: 200,
            data: streamBody,
            contentType: "text/event-stream"
        )
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { _ in throw URLError(.unsupportedURL) },
            streamingTransport: { request in
                try await streamingTransport.response(for: request)
            },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "fixture-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "fixture-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )
        let recorder = StreamingFollowingProgressRecorder()

        let payload = try await client.importXFollowings(
            userName: "cominavi",
            onProgress: { progress in
                await recorder.append(progress)
            }
        )

        XCTAssertEqual(payload.twitterUserName, "cominavi")
        XCTAssertEqual(payload.source, .twitterAPI)
        XCTAssertEqual(payload.followings.map(\.id), ["x-1"])
        let progressValues = await recorder.values()
        XCTAssertEqual(progressValues.map(\.fetchedCount), [1])
        XCTAssertEqual(progressValues.first?.followings.map(\.id), ["x-1"])
        let requests = await streamingTransport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/api/v2/imports/x-followings/stream")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access"
        )
        XCTAssertEqual(requests[0].timeoutInterval, 10 * 60)
    }

    func testStreamingXFollowingImportPreservesTypedEventError() async throws {
        let nextAllowedAt = "2026-08-11T09:00:00.000Z"
        let streamBody = Data(
            """
            event: error
            data: {"defined":true,"code":"UNPROCESSABLE_CONTENT","status":422,"message":"Too many followings.","data":{"error":"twitter_following_limit_exceeded","nextAllowedAt":"\(nextAllowedAt)"}}

            """.utf8
        )
        let streamingTransport = StaticCominaviStreamingTransport(
            status: 200,
            data: streamBody,
            contentType: "text/event-stream"
        )
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { _ in throw URLError(.unsupportedURL) },
            streamingTransport: { request in
                try await streamingTransport.response(for: request)
            },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "fixture-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "fixture-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )

        do {
            _ = try await client.importXFollowings(userName: "cominavi") { _ in }
            XCTFail("Expected a typed streaming import error")
        } catch FollowingImportAPIError.server(let code, let message, let nextAllowedAt) {
            XCTAssertEqual(code, "twitter_following_limit_exceeded")
            XCTAssertEqual(message, "Too many followings.")
            XCTAssertEqual(nextAllowedAt, try fixtureDate("2026-08-11T09:00:00Z"))
        }
    }

    func testStreamingXFollowingImportMapsMalformedCompletionToActionableError() async throws {
        let streamBody = Data(
            """
            event: done
            data: {"twitterUserName":"cominavi","importedAt":"not-a-date","nextAllowedAt":"2026-08-11T14:00:00.000Z","followings":[],"source":"twitterapi.io"}

            """.utf8
        )
        let streamingTransport = StaticCominaviStreamingTransport(
            status: 200,
            data: streamBody,
            contentType: "text/event-stream"
        )
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { _ in throw URLError(.unsupportedURL) },
            streamingTransport: { request in
                try await streamingTransport.response(for: request)
            },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "fixture-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "fixture-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )

        do {
            _ = try await client.importXFollowings(userName: "cominavi") { _ in }
            XCTFail("A malformed completion must be rejected")
        } catch FollowingImportAPIError.invalidResponse {
            XCTAssertEqual(
                FollowingImportAPIError.invalidResponse.localizedDescription,
                "The import service returned an invalid response."
            )
        }
    }

    func testGeneratedXFollowingImportPreservesCooldownError() async throws {
        let nextAllowedAt = "2026-08-11T09:00:00Z"
        let response = Data(
            #"{"error":"following_import_rate_limited","message":"Try later.","nextAllowedAt":"2026-08-11T09:00:00Z"}"#.utf8
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/imports/x-followings": (429, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.importXFollowings(userName: "cominavi")
            XCTFail("A cooldown response must remain typed")
        } catch FollowingImportAPIError.server(let code, let message, let date) {
            XCTAssertEqual(code, "following_import_rate_limited")
            XCTAssertEqual(message, "Try later.")
            XCTAssertEqual(date, try fixtureDate(nextAllowedAt))
        }
    }

    func testGeneratedXFollowingImportPreservesFollowingLimitError() async throws {
        let response = Data(
            #"{"error":"twitter_following_limit_exceeded","message":"This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts."}"#.utf8
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/imports/x-followings": (422, response),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.importXFollowings(userName: "cominavi")
            XCTFail("A following-limit response must remain typed")
        } catch FollowingImportAPIError.server(let code, let message, let date) {
            XCTAssertEqual(code, "twitter_following_limit_exceeded")
            XCTAssertEqual(
                message,
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts."
            )
            XCTAssertNil(date)
        }
    }

    func testTypedRevisionConflictDecodesCurrentRevisionAndCurrentPlan() async throws {
        let fixture = try fixtureObject(named: "shared-plan-rest-v1")
        var plan = try XCTUnwrap(fixture["create"] as? [String: Any])["plan"] as? [String: Any]
        plan?["revision"] = 2
        plan?["name"] = "別端末の名前"
        let body = try jsonData([
            "error": "plan_revision_conflict",
            "message": "stale revision",
            "details": [
                "currentRevision": 2,
                "currentPlan": try XCTUnwrap(plan),
            ],
        ])
        let transport = StaticCominaviTransport(responses: [
            "PATCH /api/v2/plans/11111111-1111-4111-8111-111111111111": (409, body),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.renamePlan(
                id: "11111111-1111-4111-8111-111111111111",
                requestID: UUID(),
                baseRevision: 1,
                name: "端末の名前"
            )
            XCTFail("A stale CAS must throw a typed conflict")
        } catch let CominaviServiceError.revisionConflict(
            code, message, currentRevision, currentPlan
        ) {
            XCTAssertEqual(code, "plan_revision_conflict")
            XCTAssertEqual(message, "stale revision")
            XCTAssertEqual(currentRevision, 2)
            XCTAssertEqual(currentPlan?.revision, 2)
            XCTAssertEqual(currentPlan?.name, "別端末の名前")
        }
    }

    func testUnknownFavoriteCircleDecodesAffectedWCIDsAsTerminalRejection() async throws {
        let body = Data(
            #"{"error":"unknown_circle","message":"One or more favorites are not in the current service catalog.","details":{"wcIDs":[9902,9904]}}"#.utf8
        )
        let transport = StaticCominaviTransport(responses: [
            "PUT /api/v2/me/favorites/108": (422, body),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.replaceFavorites(
                eventNumber: 108,
                baseRevision: 1,
                mutationID: UUID(),
                favorites: [CominaviFavorite(
                    publicCircleID: 9_902,
                    color: .orange,
                    notificationsEnabled: true
                )]
            )
            XCTFail("An unknown WCID must be a typed terminal rejection")
        } catch let CominaviServiceError.favoriteMutationRejected(
            code,
            message,
            invalidPublicCircleIDs
        ) {
            XCTAssertEqual(code, "unknown_circle")
            XCTAssertEqual(
                message,
                "One or more favorites are not in the current service catalog."
            )
            XCTAssertEqual(invalidPublicCircleIDs, [9_902, 9_904])
        }
    }

    func testGeneratedFavoriteRevisionConflictPreservesCurrentRevision() async throws {
        let body = Data(
            #"{"error":"favorite_revision_conflict","message":"stale favorite revision","details":{"currentRevision":4}}"#.utf8
        )
        let transport = StaticCominaviTransport(responses: [
            "PUT /api/v2/me/favorites/108": (409, body),
        ])
        let client = try makeAuthenticatedClient(transport: transport)

        do {
            _ = try await client.replaceFavorites(
                eventNumber: 108,
                baseRevision: 3,
                mutationID: UUID(),
                favorites: []
            )
            XCTFail("A stale favorite revision must remain a typed conflict")
        } catch let CominaviServiceError.revisionConflict(
            code, message, currentRevision, currentPlan
        ) {
            XCTAssertEqual(code, "favorite_revision_conflict")
            XCTAssertEqual(message, "stale favorite revision")
            XCTAssertEqual(currentRevision, 4)
            XCTAssertNil(currentPlan)
        }
    }

    func testGeneratedFavoriteRequestRefreshesExactlyOnceAfter401() async throws {
        let transport = GeneratedFavoriteRefreshTransport()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "stale-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "one-time-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )

        let snapshot = try await client.favoriteSnapshot(eventNumber: 108)

        XCTAssertEqual(snapshot.revision, 7)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/api/v2/me/favorites/108",
                "/api/v2/auth/refresh",
                "/api/v2/me/favorites/108",
            ]
        )
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer stale-access", nil, "Bearer fresh-access"]
        )
        let refreshCount = await transport.refreshCount
        let favoriteCount = await transport.favoriteCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(favoriteCount, 2)
    }

    func testRefreshTokenRotationIsSingleFlightForConcurrentProtectedRequests() async throws {
        let profile = try fixtureData(named: "profile-v1")
        let transport = RefreshSingleFlightTransport(profile: profile)
        let expired = CominaviAuthenticationSession(
            accessToken: "expired-access",
            expiresAt: Date(timeIntervalSinceNow: -60),
            refreshToken: "one-time-refresh",
            refreshExpiresAt: Date(timeIntervalSinceNow: 3_600)
        )
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: FixedCominaviSessionStore(session: expired)
        )

        async let first = client.fetchProfile()
        async let second = client.fetchProfile()
        _ = try await (first, second)

        let refreshCount = await transport.refreshCount
        let profileCount = await transport.profileCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(profileCount, 2)
    }


    func testRefresh401RevokesLiveAuthorityEvenWhenReauthMarkerWriteFails() async throws {
        let profile = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "利用者A")
        let store = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "expired-a-access",
                expiresAt: Date(timeIntervalSinceNow: -60),
                refreshToken: "consumed-a-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile
            ),
            boundUserID: profile.id
        )
        store.failReauthenticationMarkerWrites = true
        let error = Data(#"{"error":"invalid_refresh","message":"refresh rejected"}"#.utf8)
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/refresh": (401, error),
        ])
        let invalidations = AuthenticationInvalidationRecorder()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationInvalidationHandler: { error in
                await invalidations.record(error)
            }
        )

        do {
            _ = try await client.fetchProfile()
            XCTFail("A definitive refresh rejection must fail closed")
        } catch CominaviServiceError.authenticationStorageUnavailable {}

        let recorded = await invalidations.values
        XCTAssertEqual(recorded, ["notLoggedIn", "authenticationStorageUnavailable"])
        XCTAssertNil(store.session)
        XCTAssertTrue(store.isLoggedOut, "The fallback marker must fail closed on relaunch")

        do {
            _ = try await client.fetchProfile()
            XCTFail("No protected request may reuse the invalidated access token")
        } catch CominaviServiceError.authenticationStorageUnavailable {}
        let rejectedRefreshRequests = await transport.requests
        XCTAssertEqual(rejectedRefreshRequests.count, 1)
    }

    func testReauthenticationTombstoneSurvivesRelaunchAndBlocksForeignCircleBridge() async throws {
        let profile = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "利用者A")
        let store = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "expired-a-access",
                expiresAt: Date(timeIntervalSinceNow: -60),
                refreshToken: "consumed-a-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile
            ),
            boundUserID: profile.id
        )
        let refreshError = Data(#"{"error":"invalid_refresh","message":"refresh rejected"}"#.utf8)
        let firstTransport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/refresh": (401, refreshError),
        ])
        let first = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await firstTransport.response(for: request) },
            sessionStore: store
        )
        do {
            _ = try await first.fetchProfile()
            XCTFail("The consumed refresh token must require explicit authentication")
        } catch CominaviServiceError.notLoggedIn {}

        let relaunchedTransport = StaticCominaviTransport(responses: [:])
        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await relaunchedTransport.response(for: request) },
            sessionStore: store
        )
        do {
            _ = try await relaunched.fetchProfile()
            XCTFail("A relaunch must not exchange an unrelated Circle.ms credential")
        } catch CominaviServiceError.notLoggedIn {}
        let relaunchedRequests = await relaunchedTransport.requests
        XCTAssertTrue(relaunchedRequests.isEmpty)
    }

    func testLogoutDeleteFailureLeavesDurableTombstoneAndBlocksRelaunchSession() async throws {
        let profile = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "利用者A")
        let refreshToken = String(repeating: "a", count: 43)
        let store = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "a-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: refreshToken,
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile
            ),
            boundUserID: profile.id
        )
        store.failSessionDeletion = true
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { _ in throw URLError(.notConnectedToInternet) },
            sessionStore: store,
            authenticationFlowCanceller: {}
        )

        try await client.revokeSession()
        XCTAssertTrue(store.isLoggedOut)
        XCTAssertNotNil(store.pendingLogout)
        XCTAssertNotNil(store.session)

        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { _ in throw URLError(.notConnectedToInternet) },
            sessionStore: store,
            authenticationFlowCanceller: {}
        )
        do {
            _ = try await relaunched.fetchProfile()
            XCTFail("A logout tombstone must make the undeleted session unusable")
        } catch CominaviServiceError.logoutPending {}
    }

    @MainActor
    func testOfflineLogoutColdRelaunchCancelsSubmittedFlowsAndEventuallyAdvancesEpoch()
        async throws
    {
        let userID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let predecessorRefreshToken = String(repeating: "p", count: 43)
        let profile = fixtureProfile(
            id: userID,
            name: "利用者A",
            identities: [
                CominaviProfileIdentity(
                    provider: "google",
                    providerUserID: "google-a"
                ),
                CominaviProfileIdentity(
                    provider: "circlems",
                    environment: "production",
                    providerUserID: "42"
                ),
                CominaviProfileIdentity(
                    provider: "apple",
                    providerUserID: "apple-a"
                ),
            ]
        )
        let circleRequestID = UUID()
        let circleClientID = UUID()
        let circleReceipt = CirclemsCredentialReceipt(
            requestID: circleRequestID,
            clientInstanceID: circleClientID,
            provider: "circlems",
            environment: "production",
            subject: "42",
            credentialRevision: 4
        )
        let googleRequestID = UUID()
        let appleRequestID = UUID()
        let sessionStore = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "predecessor-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                authVersion: 7,
                refreshToken: predecessorRefreshToken,
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile,
                circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker(
                    flowRequestID: circleRequestID,
                    credentialReceipt: circleReceipt
                ),
                googleAuthenticationCompletion: GoogleAuthenticationCompletionMarker(
                    flowRequestID: googleRequestID,
                    publicUserID: userID
                ),
                appleAuthenticationCompletion: AppleAuthenticationCompletionMarker(
                    flowRequestID: appleRequestID,
                    publicUserID: userID
                )
            ),
            boundUserID: userID
        )
        let googleStorage = InMemoryGoogleAuthenticationFlowStore()
        let googleFlow = GoogleAuthenticationFlow(
            requestID: googleRequestID,
            nonce: String(repeating: "n", count: 43),
            entryContext: .special,
            createdAt: Date(),
            entryGrant: String(repeating: "g", count: 43),
            entryGrantExpiresAt: Date(timeIntervalSinceNow: 300),
            idToken: "header.payload.signature",
            submissionAttemptedAt: Date()
        )
        try googleStorage.save(googleFlow)
        let appleStorage = InMemoryAppleAuthenticationFlowStore()
        let appleFlow = AppleAuthenticationFlow(
            requestID: appleRequestID,
            nonce: String(repeating: "a", count: 43),
            entryContext: .special,
            createdAt: Date(),
            entryGrant: String(repeating: "e", count: 43),
            entryGrantExpiresAt: Date(timeIntervalSinceNow: 300),
            identityToken: "header.payload.signature",
            authorizationCode: "pre-logout-code",
            submissionAttemptedAt: Date()
        )
        try appleStorage.save(appleFlow)
        let circleStorage = InMemoryCirclemsAuthorizationFlowStore()
        var circleFlow = CirclemsAuthorizationFlow(
            requestID: circleRequestID,
            clientInstanceID: circleClientID,
            purpose: .authenticate,
            environment: .production,
            codeVerifier: String(repeating: "v", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "v", count: 43)),
            expectedPublicUserID: nil,
            createdAt: Date()
        )
        circleFlow.authorizationURL = try XCTUnwrap(
            URL(string: "https://cominavi.net/oauth/provider")
        )
        circleFlow.startExpiresAt = Date(timeIntervalSinceNow: 600)
        circleFlow.completionCode = "pre-logout-completion"
        circleFlow.completionExpiresAt = Date(timeIntervalSinceNow: 120)
        circleFlow.submissionAttemptedAt = Date()
        circleStorage.save(circleFlow)

        let clearProviderFlows: CominaviServiceClient.AuthenticationFlowCanceller = {
            try GoogleAuthenticationFlowCoordinator(storage: googleStorage).clear()
            try AppleAuthenticationFlowCoordinator(storage: appleStorage).clear()
            try CirclemsAuthorizationFlowCoordinator(storage: circleStorage).clear()
        }
        let logoutRequestID = try XCTUnwrap(UUID(
            uuidString: "12345678-1234-4123-8123-123456789abc"
        ))
        let transport = LogoutEpochReplayTransport(startingAuthVersion: 7)
        let first = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: sessionStore,
            circlemsAuthorizationFlowStorage: circleStorage,
            googleAuthenticationFlowStorage: googleStorage,
            appleAuthenticationFlowStorage: appleStorage,
            authenticationFlowCanceller: clearProviderFlows,
            makeLogoutRequestID: { logoutRequestID }
        )

        // The first request is offline, but local logout and capability
        // cancellation complete because the exact command is durable.
        try await first.revokeSession()
        let firstPendingLogout = await first.hasPendingLogout()
        XCTAssertTrue(firstPendingLogout)
        XCTAssertNil(sessionStore.session)
        XCTAssertEqual(sessionStore.pendingLogout?.requestID, logoutRequestID)
        XCTAssertNil(try googleStorage.load())
        XCTAssertNil(try appleStorage.load())
        XCTAssertNil(circleStorage.load())

        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: sessionStore,
            circlemsAuthorizationFlowStorage: circleStorage,
            googleAuthenticationFlowStorage: googleStorage,
            appleAuthenticationFlowStorage: appleStorage,
            authenticationFlowCanceller: clearProviderFlows,
            makeLogoutRequestID: { XCTFail("must replay the durable ID"); return UUID() }
        )
        let storedCircleCompletion = await relaunched.storedCirclemsAuthorizationCompletion()
        let storedGoogleCompletion = await relaunched.storedGoogleAuthenticationCompletion()
        let storedAppleCompletion = await relaunched.storedAppleAuthenticationCompletion()
        XCTAssertNil(storedCircleCompletion)
        XCTAssertNil(storedGoogleCompletion)
        XCTAssertNil(storedAppleCompletion)

        do {
            _ = try await relaunched.authenticateWithGoogle(googleFlow)
            XCTFail("A submitted pre-logout Google proof must never restore the session")
        } catch CominaviServiceError.logoutPending {}
        do {
            _ = try await relaunched.authenticateWithApple(appleFlow)
            XCTFail("A submitted pre-logout Apple proof must never restore the session")
        } catch CominaviServiceError.logoutPending {}
        do {
            _ = try await relaunched.completeCirclemsAuthentication(circleFlow)
            XCTFail("A submitted pre-logout Circle.ms code must never restore the session")
        } catch CominaviServiceError.logoutPending {}

        try await relaunched.resumePendingLogout()
        let finalPendingLogout = await relaunched.hasPendingLogout()
        let finalAuthVersion = await transport.authVersion
        let commitCount = await transport.commitCount
        XCTAssertFalse(finalPendingLogout)
        XCTAssertNil(sessionStore.pendingLogout)
        XCTAssertNil(sessionStore.boundUserID)
        XCTAssertEqual(finalAuthVersion, 8)
        XCTAssertEqual(commitCount, 1)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer predecessor-access", "Bearer predecessor-access"]
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8),
            #"{"refreshToken":"\#(predecessorRefreshToken)","requestId":"12345678-1234-4123-8123-123456789abc"}"#
        )

        let freshGoogle = try GoogleAuthenticationFlowCoordinator(
            storage: googleStorage,
            makeRequestID: UUID.init,
            makeNonce: { String(repeating: "f", count: 43) }
        ).prepare(entryContext: .special)
        let freshApple = try AppleAuthenticationFlowCoordinator(
            storage: appleStorage,
            makeRequestID: UUID.init,
            makeNonce: { String(repeating: "z", count: 43) }
        ).prepare(entryContext: .special)
        let freshCircle = try CirclemsAuthorizationFlowCoordinator(
            storage: circleStorage
        ).prepare(
            purpose: .authenticate,
            environment: .production,
            clientInstanceID: UUID(),
            expectedPublicUserID: nil
        )
        XCTAssertNotEqual(freshGoogle.requestID, googleFlow.requestID)
        XCTAssertNotEqual(freshApple.requestID, appleFlow.requestID)
        XCTAssertNotEqual(freshCircle.requestID, circleFlow.requestID)
        do {
            _ = try await relaunched.startCirclemsAuthentication(freshCircle)
            XCTFail("The test transport has no Circle.ms start response")
        } catch CominaviServiceError.invalidResponse {}
        let requestsAfterFreshStart = await transport.requests
        XCTAssertEqual(requestsAfterFreshStart.last?.url?.path, "/api/v2/auth/circlems/start")
        let freshStartObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(requestsAfterFreshStart.last?.httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            freshStartObject["requestId"] as? String,
            freshCircle.requestID.uuidString.lowercased()
        )
    }

    func testCommittedLogoutResponseLossColdRelaunchReplaysExactPredecessorCommand()
        async throws
    {
        let userID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let predecessorRefreshToken = String(repeating: "p", count: 43)
        let logoutRequestID = try XCTUnwrap(UUID(
            uuidString: "87654321-4321-4321-8321-cba987654321"
        ))
        let store = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "predecessor-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                authVersion: 3,
                refreshToken: predecessorRefreshToken,
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: fixtureProfile(id: userID, name: "利用者A")
            ),
            boundUserID: userID
        )
        let transport = LogoutEpochReplayTransport(
            startingAuthVersion: 3,
            commitBeforeFirstFailure: true
        )
        let first = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeLogoutRequestID: { logoutRequestID }
        )

        try await first.revokeSession()
        let pendingAfterLostResponse = await first.hasPendingLogout()
        let versionAfterLostResponse = await transport.authVersion
        XCTAssertTrue(pendingAfterLostResponse)
        XCTAssertEqual(versionAfterLostResponse, 4)
        XCTAssertEqual(store.pendingLogout?.requestID, logoutRequestID)

        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeLogoutRequestID: { XCTFail("must not mint a replay ID"); return UUID() }
        )
        try await relaunched.resumePendingLogout()

        let requests = await transport.requests
        let commitCount = await transport.commitCount
        let finalVersion = await transport.authVersion
        let stillPending = await relaunched.hasPendingLogout()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer predecessor-access", "Bearer predecessor-access"]
        )
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(finalVersion, 4)
        XCTAssertFalse(stillPending)
        XCTAssertNil(store.pendingLogout)
    }

    func testLogoutFencesSuspendedGoogleResponseAndRevokesProtectedPredecessor()
        async throws
    {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let predecessor = CominaviAuthenticationSession(
            accessToken: "predecessor-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: 5,
            refreshToken: String(repeating: "p", count: 43),
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: fixtureProfile(id: predecessorUserID, name: "利用者A")
        )
        let replacementProfile = fixtureProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            name: "Google利用者",
            identities: [CominaviProfileIdentity(provider: "google")]
        )
        let replacement = CominaviAuthenticationSession(
            accessToken: "replacement-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: 6,
            refreshToken: String(repeating: "r", count: 43),
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: replacementProfile
        )
        let logoutRequestID = try XCTUnwrap(UUID(
            uuidString: "99999999-9999-4999-8999-999999999999"
        ))
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/google",
            providerResponse: try JSONEncoder.iso8601.encode(replacement),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 6
        )
        let store = MutableCominaviSessionStore(
            session: predecessor,
            boundUserID: predecessorUserID
        )
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeLogoutRequestID: { logoutRequestID }
        )
        let flow = GoogleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "n", count: 43),
            entryContext: .special,
            createdAt: Date(),
            entryGrant: String(repeating: "g", count: 43),
            entryGrantExpiresAt: Date(timeIntervalSinceNow: 300),
            idToken: "header.payload.signature",
            submissionAttemptedAt: Date()
        )

        let providerTask = Task { try await client.authenticateWithGoogle(flow) }
        await transport.waitUntilProviderRequestIsSuspended()

        // beginExplicitIdentityTransition removed only the actor's runtime
        // session. Logout must recover A's protected predecessor and revoke it.
        try await client.revokeSession()
        XCTAssertNil(store.session)
        XCTAssertNil(store.boundUserID)
        XCTAssertNil(store.pendingLogout)

        await transport.resumeProviderResponse()
        do {
            _ = try await providerTask.value
            XCTFail("A pre-logout provider response must not restore a session")
        } catch CominaviServiceError.notLoggedIn {}

        XCTAssertNil(store.session)
        let googleRequests = await transport.requests
        XCTAssertEqual(
            googleRequests.map { $0.url?.path },
            ["/api/v2/auth/google", "/api/v2/auth/logout"]
        )
    }

    func testLogoutFencesSuspendedAppleResponseAndClearsProtectedFlow()
        async throws
    {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let replacementProfile = fixtureProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            name: "Apple利用者",
            identities: [CominaviProfileIdentity(provider: "apple")]
        )
        let replacement = CominaviAuthenticationSession(
            accessToken: "replacement-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: 6,
            refreshToken: String(repeating: "r", count: 43),
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: replacementProfile
        )
        let logoutRequestID = UUID()
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/apple",
            providerResponse: try JSONEncoder.iso8601.encode(replacement),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 6
        )
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: predecessorUserID, authVersion: 5),
            boundUserID: predecessorUserID
        )
        let flowStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = AppleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "n", count: 43),
            entryContext: .special,
            createdAt: Date(),
            entryGrant: String(repeating: "g", count: 43),
            entryGrantExpiresAt: Date(timeIntervalSinceNow: 300),
            identityToken: "header.payload.signature",
            authorizationCode: "single-use-code",
            submissionAttemptedAt: Date()
        )
        try flowStorage.save(flow)
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            appleAuthenticationFlowStorage: flowStorage,
            authenticationFlowCanceller: { try flowStorage.clear() },
            makeLogoutRequestID: { logoutRequestID }
        )

        let providerTask = Task { try await client.authenticateWithApple(flow) }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await providerTask.value
            XCTFail("A pre-logout Apple response must not restore a session")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(try flowStorage.load())
        XCTAssertNil(store.session)
        XCTAssertNil(store.boundUserID)
        let requestPaths = await transport.requests.map(\.url?.path)
        XCTAssertEqual(requestPaths, ["/api/v2/auth/apple", "/api/v2/auth/logout"])
    }

    func testLogoutFencesSuspendedCircleCompletionAndRevokesProtectedPredecessor()
        async throws
    {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let predecessor = CominaviAuthenticationSession(
            accessToken: "predecessor-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: 8,
            refreshToken: String(repeating: "p", count: 43),
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: fixtureProfile(id: predecessorUserID, name: "利用者A")
        )
        let requestID = UUID()
        let clientInstanceID = UUID()
        let replacementProfile = circlemsProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            environment: "production",
            subject: "84"
        )
        let completion = try circlemsCompletionEnvelope(
            session: CominaviAuthenticationSession(
                accessToken: "replacement-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                authVersion: 9,
                refreshToken: String(repeating: "r", count: 43),
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: replacementProfile
            ),
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            environment: "production",
            subject: "84",
            credentialRevision: 1
        )
        let logoutRequestID = UUID()
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/circlems/complete",
            providerResponse: completion,
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 9,
            circleStartResponse: try circlemsStartData(
                authorizationURL: "https://auth1.circle.ms/OAuth2/"
            )
        )
        let store = MutableCominaviSessionStore(
            session: predecessor,
            boundUserID: predecessorUserID
        )
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: store,
            circlemsAuthorizationFlowStorage: flowStorage,
            authenticationFlowCanceller: {},
            makeLogoutRequestID: { logoutRequestID }
        )
        let verifier = String(repeating: "v", count: 43)
        var flow = CirclemsAuthorizationFlow(
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            purpose: .authenticate,
            environment: .production,
            codeVerifier: verifier,
            codeChallenge: CirclemsPKCE.challenge(for: verifier),
            expectedPublicUserID: nil,
            createdAt: Date()
        )
        flowStorage.save(flow)
        flow = try await client.startCirclemsAuthentication(flow).flow
        flow.completionCode = "opaque-completion"
        flow.completionExpiresAt = Date(timeIntervalSinceNow: 120)
        flow.submissionAttemptedAt = Date()

        let providerTask = Task { try await client.completeCirclemsAuthentication(flow) }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await providerTask.value
            XCTFail("A pre-logout Circle.ms completion must not restore a session")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(store.session)
        XCTAssertNil(store.boundUserID)
        let circleRequests = await transport.requests
        XCTAssertEqual(
            circleRequests.map { $0.url?.path },
            [
                "/api/v2/auth/circlems/start",
                "/api/v2/auth/circlems/complete",
                "/api/v2/auth/logout",
            ]
        )
    }

    func testLogoutFencesSuspendedCircleAuthenticationStartBeforeFlowOrBrowserPublication()
        async throws
    {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let logoutRequestID = UUID()
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let flow = CirclemsAuthorizationFlow(
            requestID: UUID(),
            clientInstanceID: UUID(),
            purpose: .authenticate,
            environment: .production,
            codeVerifier: String(repeating: "v", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "v", count: 43)),
            expectedPublicUserID: nil,
            createdAt: Date()
        )
        flowStorage.save(flow)
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: predecessorUserID, authVersion: 12),
            boundUserID: predecessorUserID
        )
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/circlems/start",
            providerResponse: try circlemsStartData(
                authorizationURL: "https://auth1.circle.ms/OAuth2/"
            ),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 13
        )
        let browser = InvocationCounter()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: store,
            circlemsAuthorizationFlowStorage: flowStorage,
            authenticationFlowCanceller: { flowStorage.clear() },
            makeLogoutRequestID: { logoutRequestID }
        )

        let start = Task {
            let publication = try await client.startCirclemsAuthentication(flow)
            await browser.record()
            return publication
        }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await start.value
            XCTFail("A response released after logout must not publish or open Circle.ms")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(flowStorage.load())
        let browserCount = await browser.count
        let requestPaths = await transport.requests.map(\.url?.path)
        XCTAssertEqual(browserCount, 0)
        XCTAssertEqual(
            requestPaths,
            ["/api/v2/auth/circlems/start", "/api/v2/auth/logout"]
        )
    }

    func testLogoutFencesSuspendedCircleLinkStartBeforeFlowOrBrowserPublication()
        async throws
    {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let logoutRequestID = UUID()
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let flow = CirclemsAuthorizationFlow(
            requestID: UUID(),
            clientInstanceID: UUID(),
            purpose: .link,
            environment: .testing,
            codeVerifier: String(repeating: "l", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "l", count: 43)),
            expectedPublicUserID: predecessorUserID,
            createdAt: Date()
        )
        flowStorage.save(flow)
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: predecessorUserID, authVersion: 20),
            boundUserID: predecessorUserID
        )
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/me/identities/circlems/start",
            providerResponse: try circlemsStartData(
                authorizationURL: "https://auth1-sandbox.circle.ms/OAuth2/"
            ),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 21
        )
        let browser = InvocationCounter()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .testing },
            sessionStore: store,
            circlemsAuthorizationFlowStorage: flowStorage,
            authenticationFlowCanceller: { flowStorage.clear() },
            makeLogoutRequestID: { logoutRequestID }
        )

        let start = Task {
            let publication = try await client.startCirclemsLink(flow)
            await browser.record()
            return publication
        }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await start.value
            XCTFail("A link response released after logout must not publish or open Circle.ms")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(flowStorage.load())
        let browserCount = await browser.count
        let requestPaths = await transport.requests.map(\.url?.path)
        XCTAssertEqual(browserCount, 0)
        XCTAssertEqual(
            requestPaths,
            ["/api/v2/me/identities/circlems/start", "/api/v2/auth/logout"]
        )
    }

    func testLogoutFencesSuspendedGoogleGrantBeforeProviderPublication() async throws {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let logoutRequestID = UUID()
        let invitationToken = "AbCdEf0123_-"
        let flowStorage = InMemoryGoogleAuthenticationFlowStore()
        let flow = GoogleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "n", count: 43),
            entryContext: .invitation,
            createdAt: Date()
        )
        try flowStorage.save(flow)
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: predecessorUserID, authVersion: 30),
            boundUserID: predecessorUserID
        )
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/google/entry-grant",
            providerResponse: Data(
                #"{"entryGrant":"ggggggggggggggggggggggggggggggggggggggggggg","expiresAt":"2099-08-10T12:05:00Z"}"#.utf8
            ),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 31
        )
        let provider = InvocationCounter()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            googleAuthenticationFlowStorage: flowStorage,
            authenticationFlowCanceller: { try flowStorage.clear() },
            makeLogoutRequestID: { logoutRequestID }
        )

        let grant = Task {
            let publication = try await client.googleEntryGrant(
                for: flow,
                invitationToken: invitationToken
            )
            await provider.record()
            return publication
        }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await grant.value
            XCTFail("A grant released after logout must not unlock the provider SDK")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(try flowStorage.load())
        let providerCount = await provider.count
        let requestPaths = await transport.requests.map(\.url?.path)
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(
            requestPaths,
            ["/api/v2/auth/google/entry-grant", "/api/v2/auth/logout"]
        )
    }

    func testLogoutFencesSuspendedAppleGrantBeforeProviderPublication() async throws {
        let predecessorUserID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let logoutRequestID = UUID()
        let flowStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = AppleAuthenticationFlow(
            requestID: UUID(),
            nonce: String(repeating: "n", count: 43),
            entryContext: .invitation,
            createdAt: Date()
        )
        try flowStorage.save(flow)
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: predecessorUserID, authVersion: 40),
            boundUserID: predecessorUserID
        )
        let transport = SuspendedProviderAuthenticationTransport(
            providerPath: "/api/v2/auth/apple/entry-grant",
            providerResponse: Data(
                #"{"entryGrant":"ggggggggggggggggggggggggggggggggggggggggggg","expiresAt":"2099-08-10T12:05:00.000Z"}"#.utf8
            ),
            logoutRequestID: logoutRequestID,
            logoutAuthVersion: 41
        )
        let provider = InvocationCounter()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            appleAuthenticationFlowStorage: flowStorage,
            authenticationFlowCanceller: { try flowStorage.clear() },
            makeLogoutRequestID: { logoutRequestID }
        )

        let grant = Task {
            let publication = try await client.appleEntryGrant(
                for: flow,
                invitationToken: "AbCdEf0123_-"
            )
            await provider.record()
            return publication
        }
        await transport.waitUntilProviderRequestIsSuspended()
        try await client.revokeSession()
        await transport.resumeProviderResponse()

        do {
            _ = try await grant.value
            XCTFail("A grant released after logout must not unlock Sign in with Apple")
        } catch CominaviServiceError.notLoggedIn {}
        XCTAssertNil(try flowStorage.load())
        let providerCount = await provider.count
        let requestPaths = await transport.requests.map(\.url?.path)
        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(
            requestPaths,
            ["/api/v2/auth/apple/entry-grant", "/api/v2/auth/logout"]
        )
    }

    @MainActor
    func testProfileLogoutCoordinatorStartsRevokeBeforeCleanupAndSurvivesTerminationAtAwait()
        async throws
    {
        let probe = SuspendedProfileLogoutProbe()
        let coordinator = ProfileLogoutCoordinator(
            revokeSession: { try await probe.revokeSession() },
            clearLocalUserData: { await probe.clearLocalUserData() }
        )
        let task = Task { try await coordinator.perform() }

        await probe.waitUntilRevokeIsSuspended()
        let eventsAtFirstSuspension = await probe.events
        XCTAssertEqual(eventsAtFirstSuspension, ["revoke"])

        // Models view/task termination at the first suspension. No local
        // cleanup can run before the durable revoke boundary returns.
        task.cancel()
        await probe.resumeRevoke()
        do {
            try await task.value
            XCTFail("Cancellation must stop cleanup after the durable boundary")
        } catch is CancellationError {}
        let eventsAfterCancellation = await probe.events
        XCTAssertEqual(eventsAfterCancellation, ["revoke"])
    }

    func testAuthenticationStorageReadFailureCannotStartCircleBridge() async throws {
        let store = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        store.storageIsAvailable = false
        let transport = StaticCominaviTransport(responses: [:])
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store
        )

        do {
            _ = try await client.fetchProfile()
            XCTFail("Credential read errors must fail closed, not look like a fresh install")
        } catch CominaviServiceError.authenticationStorageUnavailable {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }





    @MainActor
    func testPendingProfileMutationRelaunchReplaysExactRequestIDAndPayload() async throws {
        let suite = "profile-relaunch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "旧表示名")
        defaults.set(try JSONEncoder().encode(initial), forKey: "profile")
        let persistence = InMemoryCominaviProfileMutationStore()
        let service = ProfileMutationServiceStub(
            profile: initial,
            firstUpdateFailure: .transient
        )
        let first = CominaviProfileStore(
            service: service,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: initial.id,
            mutationPersistence: persistence
        )

        do {
            try await first.saveDisplayName("新しい表示名")
            XCTFail("The first transient response must leave a durable mutation")
        } catch is URLError {}
        XCTAssertTrue(first.hasPendingMutation)

        let relaunched = CominaviProfileStore(
            service: service,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: initial.id,
            mutationPersistence: persistence
        )
        XCTAssertTrue(relaunched.hasPendingMutation)
        await relaunched.load()

        let attempts = await service.updateAttempts
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].requestID, attempts[1].requestID)
        XCTAssertEqual(attempts[0].baseRevision, attempts[1].baseRevision)
        XCTAssertEqual(attempts[0].displayName, attempts[1].displayName)
        XCTAssertEqual(relaunched.profile?.displayName, "新しい表示名")
        XCTAssertFalse(relaunched.hasPendingMutation)
    }

    @MainActor
    func testCachedProfileRequiresMatchingProtectedUserBinding() throws {
        let suite = "profile-binding-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let userA = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "利用者A")
        defaults.set(try JSONEncoder().encode(userA), forKey: "profile")

        let mismatched = CominaviProfileStore(
            service: ProfileMutationServiceStub(profile: userA),
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        XCTAssertNil(mismatched.profile)
        XCTAssertFalse(mismatched.isIdentityVerified)

        defaults.set(try JSONEncoder().encode(userA), forKey: "profile")
        let matchingOffline = CominaviProfileStore(
            service: ProfileMutationServiceStub(profile: userA),
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: userA.id
        )
        XCTAssertEqual(matchingOffline.profile?.id, userA.id)
        XCTAssertTrue(matchingOffline.isIdentityVerified)

        let reauthenticationRequired = CominaviProfileStore(
            service: ProfileMutationServiceStub(profile: userA),
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: userA.id,
            initialRequiresReauthentication: true
        )
        XCTAssertEqual(reauthenticationRequired.profile?.id, userA.id)
        XCTAssertFalse(reauthenticationRequired.isIdentityVerified)
        XCTAssertTrue(reauthenticationRequired.requiresReauthentication)
    }

    @MainActor
    func testCachedBoundProfileRemainsVerifiedWhenOfflineRevalidationFails() async throws {
        let suite = "profile-offline-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached = fixtureProfile(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            name: "オフライン利用者"
        )
        defaults.set(try JSONEncoder().encode(cached), forKey: "profile")
        let store = CominaviProfileStore(
            service: ProfileMutationServiceStub(
                profile: cached,
                fetchError: URLError(.notConnectedToInternet)
            ),
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: cached.id
        )

        await store.load()

        XCTAssertEqual(store.profile, cached)
        XCTAssertTrue(store.isIdentityVerified)
        XCTAssertFalse(store.requiresReauthentication)
        XCTAssertNil(store.issueMessage)
    }

    @MainActor
    func testProfileRevisionConflictReconcilesAuthorityAndNextEditUsesFreshRevision() async throws {
        let suite = "profile-conflict-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "端末の表示名")
        var authoritative = cached
        authoritative.displayName = "別端末の表示名"
        authoritative.revision = 2
        defaults.set(try JSONEncoder().encode(cached), forKey: "profile")
        let service = ProfileMutationServiceStub(
            profile: authoritative,
            firstUpdateFailure: .revisionConflict
        )
        let store = CominaviProfileStore(
            service: service,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: cached.id
        )

        do {
            try await store.saveDisplayName("競合した表示名")
            XCTFail("A stale profile mutation must surface its conflict")
        } catch CominaviServiceError.revisionConflict {}
        XCTAssertEqual(store.profile?.revision, 2)
        XCTAssertEqual(store.profile?.displayName, "別端末の表示名")
        XCTAssertFalse(store.hasPendingMutation)

        try await store.saveDisplayName("解決後の表示名")
        let attempts = await service.updateAttempts
        XCTAssertEqual(attempts.map(\.baseRevision), [1, 2])
        XCTAssertNotEqual(attempts[0].requestID, attempts[1].requestID)
        XCTAssertEqual(store.profile?.displayName, "解決後の表示名")
    }

    @MainActor
    func testProfileMutationPersistenceFailureSendsNothingAndPendingCanBeDiscarded() async throws {
        let suite = "profile-persist-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "旧表示名")
        defaults.set(try JSONEncoder().encode(initial), forKey: "profile")
        let service = ProfileMutationServiceStub(profile: initial)
        let failingPersistence = FailingCominaviProfileMutationStore()
        let store = CominaviProfileStore(
            service: service,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: initial.id,
            mutationPersistence: failingPersistence
        )

        do {
            try await store.saveDisplayName("保存できない変更")
            XCTFail("Network send must follow durable local persistence")
        } catch SharedPlanError.persistenceFailed {}
        let unsentAttempts = await service.updateAttempts
        XCTAssertTrue(unsentAttempts.isEmpty)
        XCTAssertFalse(store.hasPendingMutation)

        let durablePersistence = InMemoryCominaviProfileMutationStore()
        let transientService = ProfileMutationServiceStub(
            profile: initial,
            firstUpdateFailure: .transient
        )
        let pendingStore = CominaviProfileStore(
            service: transientService,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: initial.id,
            mutationPersistence: durablePersistence
        )
        do {
            try await pendingStore.saveDisplayName("破棄する変更")
        } catch is URLError {}
        XCTAssertTrue(pendingStore.hasPendingMutation)
        let pendingObservation = LockedBoolean(false)
        withObservationTracking {
            _ = pendingStore.hasPendingMutation
        } onChange: {
            pendingObservation.value = true
        }
        try pendingStore.discardPendingMutation()
        XCTAssertFalse(pendingStore.hasPendingMutation)
        XCTAssertTrue(pendingObservation.value)
        XCTAssertNil(durablePersistence.load(userID: initial.id))
    }

    @MainActor
    func testAccountSwitchDetachesPriorUsersPendingProfileMutation() async throws {
        let suite = "profile-account-switch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let userA = fixtureProfile(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "利用者A")
        let userB = fixtureProfile(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", name: "利用者B")
        defaults.set(try JSONEncoder().encode(userA), forKey: "profile")
        let persistence = InMemoryCominaviProfileMutationStore()
        let service = ProfileMutationServiceStub(
            profile: userA,
            firstUpdateFailure: .transient
        )
        let store = CominaviProfileStore(
            service: service,
            defaults: defaults,
            storageKey: "profile",
            expectedUserID: userA.id,
            mutationPersistence: persistence
        )
        do {
            try await store.saveDisplayName("Aの未送信名")
        } catch is URLError {}
        XCTAssertTrue(store.hasPendingMutation)
        XCTAssertNotNil(persistence.load(userID: userA.id))

        await service.setProfile(userB)
        await store.load()

        XCTAssertEqual(store.profile?.id, userB.id)
        XCTAssertFalse(store.hasPendingMutation)
        XCTAssertNotNil(persistence.load(userID: userA.id), "A's recovery record is retained")
        try await store.saveDisplayName("Bの新しい名前")
        XCTAssertEqual(store.profile?.displayName, "Bの新しい名前")
    }

    @MainActor
    func testCirclemsPKCEFlowPersistsBeforeBrowserAndSurvivesColdCallbackReplay() throws {
        let storage = InMemoryCirclemsAuthorizationFlowStore()
        let verifier = String(repeating: "v", count: 43)
        let coordinator = CirclemsAuthorizationFlowCoordinator(
            storage: storage,
            makePKCE: { (verifier, CirclemsPKCE.challenge(for: verifier)) }
        )
        let clientInstanceID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ))
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let prepared = try coordinator.prepare(
            purpose: .authenticate,
            environment: .production,
            clientInstanceID: clientInstanceID,
            expectedPublicUserID: nil,
            now: now
        )

        XCTAssertEqual(storage.load(), prepared, "verifier must be durable before start")
        XCTAssertEqual(prepared.codeVerifier, verifier)
        XCTAssertEqual(prepared.codeChallenge, CirclemsPKCE.challenge(for: verifier))
        XCTAssertEqual(prepared.codeChallenge.utf8.count, 43)

        let started = try coordinator.recordStart(
            CirclemsAuthorizationStart(
                authorizationURL: try XCTUnwrap(URL(string: "https://auth1.circle.ms/OAuth2/")),
                expiresAt: now.addingTimeInterval(600)
            ),
            for: prepared,
            now: now
        )
        let callback = try XCTUnwrap(URL(
            string: "cominavi://oauth/circlems/landing?status=succeeded&completionCode=one-time-code"
        ))
        let completed = try coordinator.recordCallback(
            callback,
            callbackScheme: "cominavi",
            for: started,
            now: now.addingTimeInterval(30)
        )
        let replayed = try CirclemsAuthorizationFlowCoordinator(storage: storage)
            .recordCallback(
                callback,
                callbackScheme: "cominavi",
                for: started,
                now: now.addingTimeInterval(31)
            )
        let submitted = try coordinator.recordSubmissionAttempt(
            for: replayed,
            now: now.addingTimeInterval(31)
        )
        let expiredCapabilityReplay = try CirclemsAuthorizationFlowCoordinator(
            storage: storage
        ).load(now: now.addingTimeInterval(300))
        let resubmitted = try coordinator.recordSubmissionAttempt(
            for: submitted,
            now: now.addingTimeInterval(300)
        )

        XCTAssertEqual(completed.requestID, prepared.requestID)
        XCTAssertEqual(completed.codeVerifier, verifier)
        XCTAssertEqual(completed.completionCode, "one-time-code")
        XCTAssertEqual(replayed, completed)
        XCTAssertEqual(expiredCapabilityReplay, submitted)
        XCTAssertEqual(resubmitted, submitted)
        XCTAssertEqual(
            try CirclemsAuthorizationFlowCoordinator(storage: storage)
                .load(now: now.addingTimeInterval(31)),
            submitted
        )
    }

    func testCirclemsCallbackRejectsProviderTokensAndUnknownOrDuplicateParameters() throws {
        let forbidden = ["access_token", "refresh_token", "token_type", "expires_in"]
        for key in forbidden {
            let url = try XCTUnwrap(URL(
                string: "cominavi://oauth/circlems/landing?status=succeeded&completionCode=c&\(key)=secret"
            ))
            XCTAssertThrowsError(
                try CirclemsAuthorizationCallbackParser.parse(url, callbackScheme: "cominavi")
            )
        }
        for query in [
            "status=succeeded&completionCode=c&extra=value",
            "status=succeeded&completionCode=one&completionCode=duplicate",
            "status=failed&error=provider_message",
        ] {
            let url = try XCTUnwrap(URL(
                string: "cominavi://oauth/circlems/landing?\(query)"
            ))
            XCTAssertThrowsError(
                try CirclemsAuthorizationCallbackParser.parse(url, callbackScheme: "cominavi")
            )
        }
    }

    @MainActor
    func testCirclemsCallbackMismatchRetainsFlowWhileCancellationClearsIt() throws {
        let storage = InMemoryCirclemsAuthorizationFlowStore()
        let verifier = String(repeating: "v", count: 43)
        let coordinator = CirclemsAuthorizationFlowCoordinator(
            storage: storage,
            makePKCE: { (verifier, CirclemsPKCE.challenge(for: verifier)) }
        )
        let clientInstanceID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ))
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let prepared = try coordinator.prepare(
            purpose: .authenticate,
            environment: .testing,
            clientInstanceID: clientInstanceID,
            expectedPublicUserID: nil,
            now: now
        )
        let started = try coordinator.recordStart(
            CirclemsAuthorizationStart(
                authorizationURL: try XCTUnwrap(URL(string: "https://auth1-sandbox.circle.ms/OAuth2/")),
                expiresAt: now.addingTimeInterval(600)
            ),
            for: prepared,
            now: now
        )
        let mismatch = try XCTUnwrap(URL(
            string: "cominavi://oauth/circlems/landing?status=succeeded&completionCode=opaque&extra=attacker"
        ))
        XCTAssertThrowsError(try coordinator.recordCallback(
            mismatch,
            callbackScheme: "cominavi",
            for: started,
            now: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(storage.load(), started)

        try coordinator.clear() // user cancellation is an explicit terminal action
        XCTAssertNil(storage.load())
    }

    func testCirclemsCompletionUsesFrozenLiteralWireAndNeverSendsProviderTokens() async throws {
        let requestID = try XCTUnwrap(UUID(
            uuidString: "22222222-2222-4222-8222-222222222222"
        ))
        let clientInstanceID = try XCTUnwrap(UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ))
        let verifier = String(repeating: "v", count: 43)
        let profile = circlemsProfile(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            environment: "production",
            subject: "42"
        )
        let startJSON = try circlemsStartData(
            authorizationURL: "https://auth1.circle.ms/OAuth2/"
        )
        let completionJSON = try circlemsCompletionEnvelope(
            session: CominaviAuthenticationSession(
                accessToken: "service-access",
                expiresAt: Date(timeIntervalSince1970: 4_089_744_900),
                refreshToken: "service-refresh",
                refreshExpiresAt: Date(timeIntervalSince1970: 4_092_336_000),
                user: profile
            ),
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            environment: "production",
            subject: "42",
            credentialRevision: 3
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/circlems/start": (200, startJSON),
            "POST /api/v2/auth/circlems/complete": (200, completionJSON),
        ])
        let sessionStore = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: sessionStore,
            circlemsAuthorizationFlowStorage: flowStorage
        )
        var flow = CirclemsAuthorizationFlow(
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            purpose: .authenticate,
            environment: .production,
            codeVerifier: verifier,
            codeChallenge: CirclemsPKCE.challenge(for: verifier),
            expectedPublicUserID: nil,
            createdAt: Date()
        )

        flowStorage.save(flow)
        flow = try await client.startCirclemsAuthentication(flow).flow
        flow.completionCode = "opaque-completion"
        flow.completionExpiresAt = Date(timeIntervalSinceNow: 120)
        flow.submissionAttemptedAt = Date()
        let result = try await client.completeCirclemsAuthentication(flow)

        XCTAssertEqual(result.session.user?.id, profile.id)
        XCTAssertEqual(sessionStore.session?.user?.id, profile.id)
        XCTAssertEqual(
            sessionStore.session?.circlemsAuthorizationCompletion?.flowRequestID,
            requestID
        )
        XCTAssertEqual(
            sessionStore.session?.circlemsAuthorizationCompletion?
                .credentialReceipt.credentialRevision,
            3
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/v2/auth/circlems/start",
            "/api/v2/auth/circlems/complete",
        ])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [nil, nil])
        let startBody = try XCTUnwrap(String(
            data: try XCTUnwrap(requests[0].httpBody),
            encoding: .utf8
        ))
        XCTAssertEqual(
            startBody,
            #"{"clientInstanceID":"44444444-4444-4444-8444-444444444444","codeChallenge":"\#(flow.codeChallenge)","environment":"production","requestId":"22222222-2222-4222-8222-222222222222"}"#
        )
        let completionBody = try XCTUnwrap(String(
            data: try XCTUnwrap(requests[1].httpBody),
            encoding: .utf8
        ))
        XCTAssertEqual(
            completionBody,
            #"{"clientInstanceID":"44444444-4444-4444-8444-444444444444","codeVerifier":"\#(verifier)","completionCode":"opaque-completion","requestId":"22222222-2222-4222-8222-222222222222"}"#
        )
        for forbidden in ["accessToken", "refreshToken", "access_token", "refresh_token"] {
            XCTAssertFalse(startBody.contains(forbidden))
            XCTAssertFalse(completionBody.contains(forbidden))
        }

        // Simulate process death immediately after the session+receipt blob
        // commits but before the separate flow/scrub cleanup completes.
        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: sessionStore
        )
        let persisted = await relaunched.storedCirclemsAuthorizationCompletion()
        XCTAssertEqual(persisted?.marker.flowRequestID, requestID)
        XCTAssertEqual(persisted?.profile.id, profile.id)
        try await relaunched.clearCirclemsAuthorizationCompletion(
            flowRequestID: requestID
        )
        XCTAssertNil(sessionStore.session?.circlemsAuthorizationCompletion)
        let requestsAfterLocalRecovery = await transport.requests
        XCTAssertEqual(requestsAfterLocalRecovery.count, 2)
    }

    @MainActor
    func testCirclemsCompletionLostResponseColdRelaunchAfterExpiryRetriesExactBody() async throws {
        let requestID = try XCTUnwrap(UUID(
            uuidString: "33333333-3333-4333-8333-333333333333"
        ))
        let clientInstanceID = try XCTUnwrap(UUID(
            uuidString: "55555555-5555-4555-8555-555555555555"
        ))
        let profile = circlemsProfile(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            environment: "sandbox",
            subject: "77"
        )
        let response = try circlemsCompletionEnvelope(
            session: CominaviAuthenticationSession(
                accessToken: "service-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "service-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile
            ),
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            environment: "sandbox",
            subject: "77",
            credentialRevision: 9
        )
        let transport = CirclemsCompletionReplayTransport(responseBody: response)
        let sessionStore = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .testing },
            sessionStore: sessionStore
        )
        var flow = CirclemsAuthorizationFlow(
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            purpose: .authenticate,
            environment: .testing,
            codeVerifier: String(repeating: "z", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "z", count: 43)),
            expectedPublicUserID: nil,
            createdAt: Date()
        )
        flow.authorizationURL = try XCTUnwrap(URL(string: "https://cominavi.net/oauth/provider"))
        flow.startExpiresAt = Date(timeIntervalSinceNow: 600)
        flow.completionCode = "same-opaque-code"
        flow.completionExpiresAt = Date(timeIntervalSinceNow: -180)
        flow.submissionAttemptedAt = Date(timeIntervalSinceNow: -300)
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        flowStorage.save(flow)

        do {
            _ = try await client.completeCirclemsAuthentication(flow)
            XCTFail("The first committed response is intentionally lost")
        } catch is URLError {}
        let relaunchedFlow = try XCTUnwrap(
            CirclemsAuthorizationFlowCoordinator(storage: flowStorage).load()
        )
        let relaunchedClient = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .testing },
            sessionStore: sessionStore
        )
        let replayed = try await relaunchedClient.completeCirclemsAuthentication(relaunchedFlow)

        let requests = await transport.requests
        let commitCount = await transport.commitCount
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(relaunchedFlow, flow)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].httpBody?.count, requests[1].httpBody?.count)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(replayed.credentialReceipt.credentialRevision, 9)
    }

    func testCirclemsLinkCompletionRequiresCurrentBoundSessionBeforeSending() async throws {
        let requestID = UUID()
        let clientInstanceID = UUID()
        var flow = CirclemsAuthorizationFlow(
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            purpose: .link,
            environment: .production,
            codeVerifier: String(repeating: "q", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "q", count: 43)),
            expectedPublicUserID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            createdAt: Date()
        )
        flow.authorizationURL = try XCTUnwrap(URL(string: "https://cominavi.net/oauth/provider"))
        flow.startExpiresAt = Date(timeIntervalSinceNow: 600)
        flow.completionCode = "opaque"
        flow.completionExpiresAt = Date(timeIntervalSinceNow: 120)
        flow.submissionAttemptedAt = Date()
        let transport = StaticCominaviTransport(responses: [:])
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .production },
            sessionStore: MutableCominaviSessionStore(session: nil, boundUserID: nil)
        )

        do {
            _ = try await client.completeCirclemsLink(flow)
            XCTFail("Logout between callback and completion must block the link")
        } catch CominaviServiceError.notLoggedIn {}
        let sentRequests = await transport.requests
        XCTAssertTrue(sentRequests.isEmpty)
    }

    func testGoogleEntryGrantAndAuthenticationReplayExactCanonicalRequest() async throws {
        let requestID = try XCTUnwrap(UUID(
            uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        ))
        let profile = fixtureProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            name: "Google利用者",
            identities: [CominaviProfileIdentity(provider: "google")]
        )
        let responseSession = CominaviAuthenticationSession(
            accessToken: "service-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            refreshToken: "service-refresh",
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: profile
        )
        let sessionData = try JSONEncoder.iso8601.encode(responseSession)
        let grantData = try JSONEncoder.iso8601.encode(CominaviGoogleEntryGrant(
            entryGrant: "ggggggggggggggggggggggggggggggggggggggggggg",
            expiresAt: Date(timeIntervalSinceNow: 300)
        ))
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/google/entry-grant": (200, grantData),
            "POST /api/v2/auth/google": (200, sessionData),
        ])
        let sessionStore = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        sessionStore.failNextNonNilSessionSave = true
        let flowStorage = InMemoryGoogleAuthenticationFlowStore()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: sessionStore,
            googleAuthenticationFlowStorage: flowStorage
        )
        var flow = GoogleAuthenticationFlow(
            requestID: requestID,
            nonce: String(repeating: "n", count: 43),
            entryContext: .invitation,
            createdAt: Date()
        )
        try flowStorage.save(flow)
        var publication = try await client.googleEntryGrant(
            for: flow,
            invitationToken: "AbCdEf0123_-"
        )
        publication = try await client.recordGoogleIDToken(
            "header.payload.signature",
            publication: publication
        )
        flow = publication.flow

        do {
            _ = try await client.authenticateWithGoogle(flow)
            XCTFail("The first durable session write is intentionally failed")
        } catch CominaviServiceError.authenticationStorageUnavailable {}
        let completed = try await client.authenticateWithGoogle(flow)

        XCTAssertEqual(completed.user?.id, profile.id)
        XCTAssertEqual(
            sessionStore.session?.googleAuthenticationCompletion,
            GoogleAuthenticationCompletionMarker(
                flowRequestID: requestID,
                publicUserID: profile.id
            )
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
        let body = try XCTUnwrap(String(
            data: try XCTUnwrap(requests[1].httpBody),
            encoding: .utf8
        ))
        XCTAssertEqual(
            body,
            #"{"entryGrant":"ggggggggggggggggggggggggggggggggggggggggggg","idToken":"header.payload.signature","nonce":"nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn","requestId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#
        )
        let grantBody = try XCTUnwrap(String(
            data: try XCTUnwrap(requests[0].httpBody),
            encoding: .utf8
        ))
        XCTAssertEqual(
            grantBody,
            #"{"inviteToken":"AbCdEf0123_-","nonce":"nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"}"#
        )
    }

    func testGoogleCompletionMarkerClearsWithoutChangingSessionFamily() async throws {
        let requestID = UUID()
        let profile = fixtureProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            name: "Google利用者",
            identities: [CominaviProfileIdentity(provider: "google")]
        )
        let store = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: profile,
                googleAuthenticationCompletion: GoogleAuthenticationCompletionMarker(
                    flowRequestID: requestID,
                    publicUserID: profile.id
                )
            ),
            boundUserID: profile.id
        )
        let client = CominaviServiceClient(
            sessionStore: store
        )

        try await client.clearGoogleAuthenticationCompletion(flowRequestID: requestID)

        XCTAssertNil(store.session?.googleAuthenticationCompletion)
        XCTAssertEqual(store.session?.refreshToken, "refresh")
        XCTAssertEqual(store.boundUserID, profile.id)
    }

    func testCirclemsLinkStartAndCompletionUseCurrentServiceBearer() async throws {
        let requestID = try XCTUnwrap(UUID(
            uuidString: "66666666-6666-4666-8666-666666666666"
        ))
        let clientInstanceID = try XCTUnwrap(UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        ))
        let userID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let initial = fixtureProfile(id: userID, name: "Google利用者")
        let linked = circlemsProfile(id: userID, environment: "sandbox", subject: "88")
        let startJSON = try circlemsStartData(
            authorizationURL: "https://auth1-sandbox.circle.ms/OAuth2/"
        )
        let completionJSON = try circlemsLinkCompletionEnvelope(
            profile: linked,
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            environment: "sandbox",
            subject: "88",
            credentialRevision: 4
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/me/identities/circlems/start": (200, startJSON),
            "POST /api/v2/me/identities/circlems/complete": (200, completionJSON),
        ])
        let sessionStore = MutableCominaviSessionStore(
            session: CominaviAuthenticationSession(
                accessToken: "service-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "service-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
                user: initial
            ),
            boundUserID: userID
        )
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            circlemsEnvironmentProvider: { .testing },
            sessionStore: sessionStore,
            circlemsAuthorizationFlowStorage: flowStorage
        )
        var flow = CirclemsAuthorizationFlow(
            requestID: requestID,
            clientInstanceID: clientInstanceID,
            purpose: .link,
            environment: .testing,
            codeVerifier: String(repeating: "l", count: 43),
            codeChallenge: CirclemsPKCE.challenge(for: String(repeating: "l", count: 43)),
            expectedPublicUserID: userID,
            createdAt: Date()
        )

        flowStorage.save(flow)
        flow = try await client.startCirclemsLink(flow).flow
        flow.completionCode = "link-completion"
        flow.completionExpiresAt = Date(timeIntervalSinceNow: 120)
        flow.submissionAttemptedAt = Date()
        let result = try await client.completeCirclemsLink(flow)

        XCTAssertEqual(result.profile.identities.first?.providerUserID, "88")
        XCTAssertEqual(
            sessionStore.session?.circlemsAuthorizationCompletion?.flowRequestID,
            requestID
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer service-access", "Bearer service-access",
        ])
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/v2/me/identities/circlems/start",
            "/api/v2/me/identities/circlems/complete",
        ])
        let bodies = try requests.map {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody))
                    as? [String: Any]
            )
        }
        XCTAssertEqual(
            bodies[0]["clientInstanceID"] as? String,
            "77777777-7777-4777-8777-777777777777"
        )
        XCTAssertEqual(bodies[1]["completionCode"] as? String, "link-completion")
        XCTAssertTrue(bodies.allSatisfy { $0["accessToken"] == nil })
        XCTAssertTrue(bodies.allSatisfy { $0["refreshToken"] == nil })
    }

    func testFrozenAppleFixtureDecodesAndSendsExactProtectedRequest() async throws {
        let fixture = try fixtureObject(named: "auth-providers-v1")
        let apple = try XCTUnwrap(fixture["apple"] as? [String: Any])
        let requestObject = try XCTUnwrap(apple["request"] as? [String: Any])
        let literalResponse = try jsonData(apple["authResponse"])
        XCTAssertEqual(literalResponse, try jsonData(apple["exactReplayResponse"]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            CominaviAuthenticationSession.self,
            from: literalResponse
        )
        XCTAssertEqual(decoded.authVersion, 1)
        XCTAssertEqual(decoded.refreshToken?.utf8.count, 43)
        XCTAssertEqual(decoded.user?.identities.first?.provider, "apple")

        let requestID = try XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(requestObject["requestId"] as? String)
        ))
        let profile = try XCTUnwrap(decoded.user)
        let response = CominaviAuthenticationSession(
            tokenType: "Bearer",
            accessToken: decoded.accessToken,
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: decoded.authVersion,
            refreshToken: decoded.refreshToken,
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: profile
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/apple": (200, try JSONEncoder.iso8601.encode(response)),
        ])
        let sessionStore = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        let flowStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = AppleAuthenticationFlow(
            requestID: requestID,
            nonce: try XCTUnwrap(requestObject["nonce"] as? String),
            entryContext: .invitation,
            createdAt: Date(),
            entryGrant: try XCTUnwrap(requestObject["entryGrant"] as? String),
            entryGrantExpiresAt: Date(timeIntervalSinceNow: 300),
            identityToken: try XCTUnwrap(requestObject["identityToken"] as? String),
            authorizationCode: try XCTUnwrap(requestObject["authorizationCode"] as? String),
            displayName: requestObject["displayName"] as? String,
            submissionAttemptedAt: Date()
        )
        try flowStorage.save(flow)
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: sessionStore,
            appleAuthenticationFlowStorage: flowStorage,
            authenticationFlowCanceller: {}
        )

        let authentication = try await client.authenticateWithApple(flow)

        XCTAssertEqual(authentication.user?.id, profile.id)
        XCTAssertEqual(
            sessionStore.session?.appleAuthenticationCompletion,
            AppleAuthenticationCompletionMarker(
                flowRequestID: requestID,
                publicUserID: profile.id
            )
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpBody, try jsonData(requestObject))
        XCTAssertEqual(
            String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8),
            #"{"authorizationCode":"fixture-single-use-authorization-code","displayName":"Private Apple User","entryGrant":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","identityToken":"fixture-apple-identity-token","nonce":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC","requestId":"44444444-4444-4444-8444-444444444444"}"#
        )
    }

    func testSubmittedAppleGrantIsImmutableDuringLostResponseAndRelaunchReplay()
        async throws
    {
        let now = Date()
        let nonce = String(repeating: "n", count: 43)
        let originalGrant = String(repeating: "g", count: 43)
        let originalExpiry = now.addingTimeInterval(300)
        let flow = AppleAuthenticationFlow(
            requestID: UUID(),
            nonce: nonce,
            entryContext: .special,
            createdAt: now,
            entryGrant: originalGrant,
            entryGrantExpiresAt: originalExpiry,
            identityToken: "header.payload.signature",
            authorizationCode: "single-use-code",
            displayName: "Apple 利用者",
            submissionAttemptedAt: now
        )
        let flowStorage = InMemoryAppleAuthenticationFlowStore()
        try flowStorage.save(flow)
        let sessionStore = MutableCominaviSessionStore(session: nil, boundUserID: nil)
        let profile = fixtureProfile(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            name: "Apple 利用者",
            identities: [CominaviProfileIdentity(provider: "apple")]
        )
        let response = CominaviAuthenticationSession(
            accessToken: "service-access",
            expiresAt: now.addingTimeInterval(3_600),
            authVersion: 1,
            refreshToken: String(repeating: "r", count: 43),
            refreshExpiresAt: now.addingTimeInterval(86_400),
            user: profile
        )
        let transport = SuspendedResponseLossReplayTransport(
            path: "/api/v2/auth/apple",
            responseData: try JSONEncoder.iso8601.encode(response)
        )
        let first = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: sessionStore,
            appleAuthenticationFlowStorage: flowStorage
        )

        let firstAttempt = Task { try await first.authenticateWithApple(flow) }
        await transport.waitUntilFirstResponseIsSuspended()
        var callback = URLComponents()
        callback.scheme = "cominavi"
        callback.host = "auth"
        callback.path = "/apple/grant"
        callback.queryItems = [
            URLQueryItem(name: "entryGrant", value: String(repeating: "x", count: 43)),
            URLQueryItem(
                name: "expiresAt",
                value: ISO8601DateFormatter().string(from: now.addingTimeInterval(420))
            ),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        do {
            try await first.recordPendingAppleEntryGrantCallback(
                XCTUnwrap(callback.url)
            )
            XCTFail("A submitted request body must be immutable")
        } catch AppleAuthenticationFlowError.committedOrUnknown {}
        XCTAssertEqual(try flowStorage.load(), flow)

        await transport.resumeFirstResponseAsLost()
        do {
            _ = try await firstAttempt.value
            XCTFail("The first committed response is intentionally lost")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: sessionStore,
            appleAuthenticationFlowStorage: flowStorage
        )
        let protectedReplay = try XCTUnwrap(try flowStorage.load())
        let authentication = try await relaunched.authenticateWithApple(protectedReplay)

        XCTAssertEqual(authentication.user?.id, profile.id)
        XCTAssertEqual(protectedReplay.entryGrant, originalGrant)
        XCTAssertEqual(protectedReplay.entryGrantExpiresAt, originalExpiry)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertTrue(
            String(data: try XCTUnwrap(requests[1].httpBody), encoding: .utf8)?
                .contains(#""entryGrant":"ggggggggggggggggggggggggggggggggggggggggggg""#)
                == true
        )
    }

    func testFrozenAppleInvitationGrantSendsExactNonceAndInviteToken() async throws {
        let fixture = try fixtureObject(named: "auth-providers-v1")
        let apple = try XCTUnwrap(fixture["apple"] as? [String: Any])
        let requestObject = try XCTUnwrap(apple["entryGrantRequest"] as? [String: Any])
        let fixtureResponse = try jsonData(apple["entryGrantResponse"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let literalGrant = try decoder.decode(
            CominaviAppleEntryGrant.self,
            from: fixtureResponse
        )
        XCTAssertEqual(
            literalGrant.entryGrant,
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        )

        let response = CominaviAppleEntryGrant(
            entryGrant: literalGrant.entryGrant,
            expiresAt: Date(timeIntervalSinceNow: 300)
        )
        let transport = StaticCominaviTransport(responses: [
            "POST /api/v2/auth/apple/entry-grant": (
                200,
                try JSONEncoder.iso8601.encode(response)
            ),
        ])
        let flowStorage = InMemoryAppleAuthenticationFlowStore()
        let flow = AppleAuthenticationFlow(
            requestID: UUID(),
            nonce: try XCTUnwrap(requestObject["nonce"] as? String),
            entryContext: .invitation,
            createdAt: Date()
        )
        try flowStorage.save(flow)
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: MutableCominaviSessionStore(session: nil, boundUserID: nil),
            appleAuthenticationFlowStorage: flowStorage,
            authenticationFlowCanceller: { try flowStorage.clear() }
        )

        let publication = try await client.appleEntryGrant(
            for: flow,
            invitationToken: try XCTUnwrap(requestObject["inviteToken"] as? String)
        )

        XCTAssertEqual(publication.flow.entryGrant, literalGrant.entryGrant)
        XCTAssertEqual(try flowStorage.load(), publication.flow)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpBody, try jsonData(requestObject))
        XCTAssertEqual(
            String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8),
            #"{"inviteToken":"AbCdEf0123_-","nonce":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}"#
        )
    }

    func testFrozenAccountDeletionFixturePersistsBeforeDeleteAndAccepts202() async throws {
        let fixture = try fixtureObject(named: "auth-providers-v1")
        let deletion = try XCTUnwrap(fixture["accountDeletion"] as? [String: Any])
        let requestObject = try XCTUnwrap(deletion["request"] as? [String: Any])
        let responseData = try jsonData(deletion["acceptedResponse"])
        XCTAssertEqual(deletion["acceptedHTTPStatus"] as? Int, 202)
        XCTAssertEqual(deletion["exactReplayHTTPStatus"] as? Int, 202)
        XCTAssertEqual(responseData, try jsonData(deletion["exactReplayResponse"]))
        let requestID = try XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(requestObject["requestId"] as? String)
        ))
        let userID = "fedcba9876543210fedcba9876543210"
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: userID, authVersion: 4),
            boundUserID: userID
        )
        let transport = StaticCominaviTransport(responses: [
            "DELETE /api/v2/me": (202, responseData),
        ])
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeAccountDeletionRequestID: { requestID }
        )

        let result = try await client.requestAccountDeletion()

        XCTAssertEqual(result.status, "deletion_pending")
        XCTAssertEqual(result.requestId, requestID.uuidString.lowercased())
        XCTAssertEqual(result.deletedOwnedPlanIDs, [
            "01234567-89ab-4cde-8fab-0123456789ab",
        ])
        XCTAssertNil(store.pendingAccountDeletion)
        XCTAssertEqual(store.pendingAccountDeletionCleanup?.requestID, requestID)
        XCTAssertEqual(store.pendingAccountDeletionCleanup?.publicUserID, userID)
        XCTAssertNil(store.session)
        XCTAssertNil(store.boundUserID)
        XCTAssertTrue(store.isLoggedOut)
        let deletionPendingBeforeCleanup = await client.hasPendingAccountDeletion()
        XCTAssertTrue(deletionPendingBeforeCleanup)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpBody, try jsonData(requestObject))
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer predecessor-access"
        )

        try await client.acknowledgeAccountDeletionLocalCleanup(requestID: requestID)
        XCTAssertNil(store.pendingAccountDeletionCleanup)
        let deletionPendingAfterCleanup = await client.hasPendingAccountDeletion()
        XCTAssertFalse(deletionPendingAfterCleanup)
    }

    func testAccountDeletionResponseLossRelaunchReplaysExactPredecessorRequest() async throws {
        let requestID = try XCTUnwrap(UUID(
            uuidString: "55555555-5555-4555-8555-555555555555"
        ))
        let userID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: userID, authVersion: 5),
            boundUserID: userID
        )
        let response = CominaviAccountDeletionResult(
            status: "deletion_pending",
            requestId: requestID.uuidString.lowercased(),
            deletedOwnedPlanIDs: ["01234567-89ab-4cde-8fab-0123456789ab"]
        )
        let transport = AccountDeletionReplayTransport(
            response: try JSONEncoder().encode(response)
        )
        let first = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeAccountDeletionRequestID: { requestID }
        )

        do {
            _ = try await first.requestAccountDeletion()
            XCTFail("The committed response is intentionally lost")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(store.pendingAccountDeletion?.requestID, requestID)
        XCTAssertNil(store.session)

        let relaunched = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeAccountDeletionRequestID: {
                XCTFail("must replay the protected deletion request")
                return UUID()
            }
        )
        let replay = try await relaunched.resumePendingAccountDeletion()

        XCTAssertEqual(replay, response)
        XCTAssertNil(store.pendingAccountDeletion)
        XCTAssertEqual(store.pendingAccountDeletionCleanup?.requestID, requestID)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer predecessor-access", "Bearer predecessor-access"]
        )
        let commitCount = await transport.commitCount
        XCTAssertEqual(commitCount, 1)

        // Termination after the 202 but before local file cleanup must retain
        // the public-user pointer and must never issue a third DELETE.
        let afterAcknowledgementRelaunch = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {},
            makeAccountDeletionRequestID: {
                XCTFail("must not create a second deletion transaction")
                return UUID()
            }
        )
        let redundantResume = try await afterAcknowledgementRelaunch
            .resumePendingAccountDeletion()
        XCTAssertNil(redundantResume)
        let retainedCleanupReceipt = await afterAcknowledgementRelaunch
            .accountDeletionCleanupReceipt()
        XCTAssertEqual(retainedCleanupReceipt?.publicUserID, userID)
        let requestsAfterRelaunch = await transport.requests
        XCTAssertEqual(requestsAfterRelaunch.count, 2)
        try await afterAcknowledgementRelaunch.acknowledgeAccountDeletionLocalCleanup(
            requestID: requestID
        )
        XCTAssertNil(store.pendingAccountDeletionCleanup)
    }

    func testAccountDeletionPersistenceFailureSendsNothingAndFailsClosed() async throws {
        let userID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let store = MutableCominaviSessionStore(
            session: predecessorSession(userID: userID, authVersion: 2),
            boundUserID: userID
        )
        store.failAccountDeletionSave = true
        let transport = StaticCominaviTransport(responses: [:])
        let client = try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: store,
            authenticationFlowCanceller: {}
        )

        do {
            _ = try await client.requestAccountDeletion()
            XCTFail("A non-durable deletion must not be reported or sent")
        } catch CominaviServiceError.authenticationStorageUnavailable {}

        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(store.requiresExplicitAuthentication)
    }

    @MainActor
    func testCirclemsCompletionReceiptScrubsLegacyCredentialAfterFlowTTL() throws {
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let flowStorage = InMemoryCirclemsAuthorizationFlowStore()
        let verifier = String(repeating: "r", count: 43)
        let flowCoordinator = CirclemsAuthorizationFlowCoordinator(
            storage: flowStorage,
            makePKCE: { (verifier, CirclemsPKCE.challenge(for: verifier)) }
        )
        let clientInstanceID = UUID()
        let prepared = try flowCoordinator.prepare(
            purpose: .authenticate,
            environment: .production,
            clientInstanceID: clientInstanceID,
            expectedPublicUserID: nil,
            now: now
        )
        let started = try flowCoordinator.recordStart(
            CirclemsAuthorizationStart(
                authorizationURL: try XCTUnwrap(URL(string: "https://auth1.circle.ms/OAuth2/")),
                expiresAt: now.addingTimeInterval(600)
            ),
            for: prepared,
            now: now
        )
        _ = try flowCoordinator.recordCallback(
            try XCTUnwrap(URL(
                string: "cominavi://oauth/circlems/landing?status=succeeded&completionCode=opaque"
            )),
            callbackScheme: "cominavi",
            for: started,
            now: now
        )
        XCTAssertNil(
            try flowCoordinator.load(now: now.addingTimeInterval(121)),
            "the short-lived callback record may expire while the app is down"
        )

        let transfer = makeCirclemsTransfer(requestID: prepared.requestID)
        let legacyStore = FaultInjectingCirclemsUserStore(user: User(
            accessToken: "legacy-access",
            accessTokenExpiresAt: now.addingTimeInterval(3_600),
            refreshToken: "legacy-refresh",
            userId: 42,
            nickname: "旧端末利用者",
            preferenceR18Enabled: false,
            circlemsCredentialTransfer: transfer
        ))
        let receipt = CirclemsCredentialReceipt(
            requestID: prepared.requestID,
            clientInstanceID: clientInstanceID,
            provider: "circlems",
            environment: "production",
            subject: "42",
            credentialRevision: 12
        )
        let migration = CirclemsCredentialTransferCoordinator(storage: legacyStore)
        try migration.scrubBackendOwnedCredential(receipt)

        XCTAssertNil(legacyStore.user)
        XCTAssertEqual(
            try legacyStore.loadCredentialRevision(environment: "production", subject: "42"),
            12
        )
    }

    private func makeAuthenticatedClient(
        transport: StaticCominaviTransport
    ) throws -> CominaviServiceClient {
        try CominaviServiceClient(
            baseURL: XCTUnwrap(URL(string: "https://cominavi.net")),
            transport: { request in try await transport.response(for: request) },
            sessionStore: FixedCominaviSessionStore(session: CominaviAuthenticationSession(
                accessToken: "fixture-access",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                refreshToken: "fixture-refresh",
                refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
            ))
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData(named: name)) as? [String: Any]
        )
    }

    private func jsonData(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(value), options: [.sortedKeys])
    }

    private func fixtureDate(_ value: String) throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Date.self, from: Data("\"\(value)\"".utf8))
    }

    private func circlemsStartData(
        authorizationURL: String,
        expiresAt: Date = Date(timeIntervalSinceNow: 600)
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "authorizationURL": authorizationURL,
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
        ], options: [.sortedKeys])
    }

    private func fixtureProfile(
        id: String,
        name: String,
        identities: [CominaviProfileIdentity] = []
    ) -> CominaviUserProfile {
        CominaviUserProfile(
            id: id,
            displayName: name,
            avatarURL: nil,
            revision: 1,
            identities: identities,
            displayNameExplicitlyEdited: false,
            avatarExplicitlyEdited: false
        )
    }

    private func predecessorSession(
        userID: String,
        authVersion: Int
    ) -> CominaviAuthenticationSession {
        CominaviAuthenticationSession(
            accessToken: "predecessor-access",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            authVersion: authVersion,
            refreshToken: String(repeating: "p", count: 43),
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
            user: fixtureProfile(id: userID, name: "利用者A")
        )
    }

}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct FixedCominaviSessionStore: CominaviAuthenticationSessionPersisting {
    let session: CominaviAuthenticationSession
    func load() -> CominaviAuthenticationSession? { session }
    func save(_ session: CominaviAuthenticationSession?) -> Bool { true }
}

private final class MutableCominaviSessionStore: @unchecked Sendable,
    CominaviAuthenticationSessionPersisting
{
    private let lock = NSLock()
    private var storedSession: CominaviAuthenticationSession?
    private var storedBoundUserID: String?
    private var reauthenticationMarker = false
    private var logoutMarker = false
    private var logoutTransaction: CominaviLogoutTransaction?
    private var accountDeletionTransaction: CominaviAccountDeletionTransaction?
    private var accountDeletionCleanupReceipt: CominaviAccountDeletionCleanupReceipt?
    private var shouldFailNextNonNilSessionSave = false
    private var shouldFailReauthenticationMarkerWrites = false
    private var shouldFailSessionDeletion = false
    private var isStorageAvailable = true
    private var shouldFailAccountDeletionSave = false

    init(session: CominaviAuthenticationSession?, boundUserID: String?) {
        storedSession = session
        storedBoundUserID = boundUserID
    }

    var failNextNonNilSessionSave: Bool {
        get { lock.withLock { shouldFailNextNonNilSessionSave } }
        set { lock.withLock { shouldFailNextNonNilSessionSave = newValue } }
    }

    var failReauthenticationMarkerWrites: Bool {
        get { lock.withLock { shouldFailReauthenticationMarkerWrites } }
        set { lock.withLock { shouldFailReauthenticationMarkerWrites = newValue } }
    }

    var failSessionDeletion: Bool {
        get { lock.withLock { shouldFailSessionDeletion } }
        set { lock.withLock { shouldFailSessionDeletion = newValue } }
    }

    var storageIsAvailable: Bool {
        get { lock.withLock { isStorageAvailable } }
        set { lock.withLock { isStorageAvailable = newValue } }
    }

    var session: CominaviAuthenticationSession? { lock.withLock { storedSession } }
    var boundUserID: String? { lock.withLock { storedBoundUserID } }
    var requiresExplicitAuthentication: Bool {
        lock.withLock {
            reauthenticationMarker || logoutMarker || accountDeletionTransaction != nil
                || accountDeletionCleanupReceipt != nil
        }
    }
    var isLoggedOut: Bool { lock.withLock { logoutMarker } }
    var pendingLogout: CominaviLogoutTransaction? { lock.withLock { logoutTransaction } }
    var pendingAccountDeletion: CominaviAccountDeletionTransaction? {
        lock.withLock { accountDeletionTransaction }
    }
    var pendingAccountDeletionCleanup: CominaviAccountDeletionCleanupReceipt? {
        lock.withLock { accountDeletionCleanupReceipt }
    }
    var failAccountDeletionSave: Bool {
        get { lock.withLock { shouldFailAccountDeletionSave } }
        set { lock.withLock { shouldFailAccountDeletionSave = newValue } }
    }

    func load() -> CominaviAuthenticationSession? { session }

    func save(_ session: CominaviAuthenticationSession?) -> Bool {
        lock.withLock {
            if session == nil, shouldFailSessionDeletion { return false }
            if session != nil, shouldFailNextNonNilSessionSave {
                shouldFailNextNonNilSessionSave = false
                return false
            }
            storedSession = session
            return true
        }
    }

    func loadBoundUserID() -> String? { boundUserID }

    func saveBoundUserID(_ userID: String?) -> Bool {
        lock.withLock {
            storedBoundUserID = userID
            return true
        }
    }

    func loadState() -> CominaviAuthenticationStorageState {
        lock.withLock {
            CominaviAuthenticationStorageState(
                session: storedSession,
                boundUserID: storedBoundUserID,
                pendingLogout: logoutTransaction,
                pendingAccountDeletion: accountDeletionTransaction,
                pendingAccountDeletionCleanup: accountDeletionCleanupReceipt,
                requiresExplicitAuthentication: reauthenticationMarker || logoutMarker
                    || accountDeletionTransaction != nil
                    || accountDeletionCleanupReceipt != nil,
                isLoggedOut: logoutMarker,
                isAvailable: isStorageAvailable
            )
        }
    }

    func loadPendingLogout() -> CominaviLogoutTransaction? { pendingLogout }

    func savePendingLogout(_ transaction: CominaviLogoutTransaction?) -> Bool {
        lock.withLock {
            logoutTransaction = transaction
            logoutMarker = transaction != nil
            return true
        }
    }

    func loadPendingAccountDeletion() -> CominaviAccountDeletionTransaction? {
        pendingAccountDeletion
    }

    func savePendingAccountDeletion(
        _ transaction: CominaviAccountDeletionTransaction?
    ) -> Bool {
        lock.withLock {
            if transaction != nil, shouldFailAccountDeletionSave { return false }
            accountDeletionTransaction = transaction
            return true
        }
    }

    func loadPendingAccountDeletionCleanup() -> CominaviAccountDeletionCleanupReceipt? {
        pendingAccountDeletionCleanup
    }

    func savePendingAccountDeletionCleanup(
        _ receipt: CominaviAccountDeletionCleanupReceipt?
    ) -> Bool {
        lock.withLock {
            accountDeletionCleanupReceipt = receipt
            return true
        }
    }

    func saveLogoutTombstone(_ present: Bool) -> Bool {
        lock.withLock {
            logoutMarker = present
            if !present { logoutTransaction = nil }
            return true
        }
    }

    func saveReauthenticationTombstone(_ present: Bool) -> Bool {
        lock.withLock {
            if present, shouldFailReauthenticationMarkerWrites { return false }
            reauthenticationMarker = present
            return true
        }
    }
}

private actor AuthenticationInvalidationRecorder {
    private(set) var values: [String] = []

    func record(_ error: CominaviServiceError?) {
        switch error {
        case .notLoggedIn: values.append("notLoggedIn")
        case .authenticationStorageUnavailable:
            values.append("authenticationStorageUnavailable")
        case .logoutPending: values.append("logoutPending")
        case .accountDeletionPending: values.append("accountDeletionPending")
        case .circlemsCredentialTransferPending:
            values.append("circlemsCredentialTransferPending")
        case .invalidResponse: values.append("invalidResponse")
        case .server: values.append("server")
        case .favoriteMutationRejected: values.append("favoriteMutationRejected")
        case .planOwnerRequired: values.append("planOwnerRequired")
        case .invitationTokenAlreadyReturned:
            values.append("invitationTokenAlreadyReturned")
        case .revisionConflict: values.append("revisionConflict")
        case nil: values.append("transition")
        }
    }
}

private func makeCirclemsTransfer(
    requestID: UUID = UUID(),
    purpose: CirclemsCredentialTransfer.Purpose = .authenticate,
    environment: CirclemsServiceEnvironment = .production,
    accessToken: String = "provider-access",
    refreshToken: String? = "provider-refresh",
    accessExpiresAt: Int? = 4_089_744_900,
    baseCredentialRevision: Int? = nil
) -> CirclemsCredentialTransfer {
    CirclemsCredentialTransfer(
        requestID: requestID,
        purpose: purpose,
        environment: environment,
        accessToken: accessToken,
        refreshToken: refreshToken,
        accessExpiresAt: accessExpiresAt,
        baseCredentialRevision: baseCredentialRevision,
        state: .pending,
        receipt: nil
    )
}


private func circlemsProfile(
    id: String,
    environment: String,
    subject: String
) -> CominaviUserProfile {
    CominaviUserProfile(
        id: id,
        displayName: "Circle.ms利用者",
        avatarURL: nil,
        revision: 1,
        identities: [CominaviProfileIdentity(
            provider: "circlems",
            environment: environment,
            providerUserID: subject
        )],
        displayNameExplicitlyEdited: false,
        avatarExplicitlyEdited: false
    )
}

private func circlemsCompletionEnvelope(
    session: CominaviAuthenticationSession,
    requestID: UUID,
    clientInstanceID: UUID,
    environment: String,
    subject: String,
    credentialRevision: Int
) throws -> Data {
    let encoded = try JSONEncoder.iso8601.encode(session)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    if var user = object["user"] as? [String: Any],
       var identities = user["identities"] as? [[String: Any]],
       !identities.isEmpty,
       let numericSubject = Int(subject)
    {
        identities[0]["providerUserID"] = numericSubject
        user["identities"] = identities
        object["user"] = user
    }
    object["credentialReceipt"] = [
        "requestId": requestID.uuidString.lowercased(),
        "clientInstanceID": clientInstanceID.uuidString.lowercased(),
        "provider": "circlems",
        "environment": environment,
        "subject": subject,
        "credentialRevision": credentialRevision,
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func circlemsLinkCompletionEnvelope(
    profile: CominaviUserProfile,
    requestID: UUID,
    clientInstanceID: UUID,
    environment: String,
    subject: String,
    credentialRevision: Int
) throws -> Data {
    var user = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(profile))
            as? [String: Any]
    )
    if var identities = user["identities"] as? [[String: Any]],
       !identities.isEmpty,
       let numericSubject = Int(subject)
    {
        identities[0]["providerUserID"] = numericSubject
        user["identities"] = identities
    }
    return try JSONSerialization.data(withJSONObject: [
        "user": user,
        "credentialReceipt": [
            "requestId": requestID.uuidString.lowercased(),
            "clientInstanceID": clientInstanceID.uuidString.lowercased(),
            "provider": "circlems",
            "environment": environment,
            "subject": subject,
            "credentialRevision": credentialRevision,
        ],
    ], options: [.sortedKeys])
}

private actor ProfileMutationServiceStub: CominaviProfileServicing {
    enum FirstUpdateFailure: Sendable {
        case none
        case transient
        case revisionConflict
    }

    struct UpdateAttempt: Sendable {
        let displayName: String
        let baseRevision: Int
        let requestID: UUID
    }

    private var profile: CominaviUserProfile
    private let firstUpdateFailure: FirstUpdateFailure
    private let fetchError: URLError?
    private(set) var updateAttempts: [UpdateAttempt] = []

    init(
        profile: CominaviUserProfile,
        firstUpdateFailure: FirstUpdateFailure = .none,
        fetchError: URLError? = nil
    ) {
        self.profile = profile
        self.firstUpdateFailure = firstUpdateFailure
        self.fetchError = fetchError
    }

    func fetchProfile() async throws -> CominaviUserProfile {
        if let fetchError { throw fetchError }
        return profile
    }

    func setProfile(_ profile: CominaviUserProfile) {
        self.profile = profile
    }

    func updateDisplayName(
        _ displayName: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        updateAttempts.append(UpdateAttempt(
            displayName: displayName,
            baseRevision: baseRevision,
            requestID: requestID
        ))
        if updateAttempts.count == 1 {
            switch firstUpdateFailure {
            case .none: break
            case .transient: throw URLError(.notConnectedToInternet)
            case .revisionConflict:
                throw CominaviServiceError.revisionConflict(
                    code: "profile_revision_conflict",
                    message: "stale profile revision",
                    currentRevision: profile.revision,
                    currentPlan: nil
                )
            }
        }
        guard baseRevision == profile.revision else {
            throw CominaviServiceError.revisionConflict(
                code: "profile_revision_conflict",
                message: "stale profile revision",
                currentRevision: profile.revision,
                currentPlan: nil
            )
        }
        profile.displayName = displayName
        profile.revision += 1
        return profile
    }

    func uploadAvatar(
        _ data: Data,
        contentType: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        guard baseRevision == profile.revision, !data.isEmpty else {
            throw CominaviServiceError.invalidResponse
        }
        profile.avatarURL = URL(string: "/api/v2/users/\(profile.id)/avatar")
        profile.revision += 1
        return profile
    }

    func deleteAvatar(
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        guard baseRevision == profile.revision else {
            throw CominaviServiceError.invalidResponse
        }
        profile.avatarURL = nil
        profile.revision += 1
        return profile
    }
}

private struct FailingCominaviProfileMutationStore: CominaviProfileMutationPersisting {
    func load(userID: String) throws -> Data? { nil }
    func save(_ data: Data, userID: String) throws {
        throw SharedPlanError.persistenceFailed
    }
    func clear(userID: String) throws {}
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private actor StaticCominaviTransport {
    typealias Response = (status: Int, data: Data)
    let responses: [String: Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let configured = try XCTUnwrap(responses[key], "Missing response for \(key)")
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: configured.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (configured.data, response)
    }
}

private actor StaticCominaviStreamingTransport {
    private let status: Int
    private let data: Data
    private let contentType: String
    private(set) var requests: [URLRequest] = []

    init(status: Int, data: Data, contentType: String) {
        self.status = status
        self.data = data
        self.contentType = contentType
    }

    func response(
        for request: URLRequest
    ) throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        requests.append(request)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ))
        let body = data
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in body { continuation.yield(byte) }
            continuation.finish()
        }
        return (stream, response)
    }
}

private actor StreamingFollowingProgressRecorder {
    private var recorded: [FollowingImportProgress] = []

    func append(_ progress: FollowingImportProgress) {
        recorded.append(progress)
    }

    func values() -> [FollowingImportProgress] {
        recorded
    }
}

private final class FaultInjectingCirclemsUserStore: @unchecked Sendable,
    CirclemsUserSessionPersisting
{
    private let lock = NSLock()
    private var storedUser: User?
    private var saveAttempt = 0
    private let failedSaveAttempts: Set<Int>
    private var credentialRevisions: [String: Int] = [:]

    init(user: User?, failedSaveAttempts: Set<Int> = []) {
        storedUser = user
        self.failedSaveAttempts = failedSaveAttempts
    }

    var user: User? { lock.withLock { storedUser } }

    func loadForCredentialTransfer() throws -> User? {
        lock.withLock { storedUser }
    }

    func save(_ user: User?) -> Bool {
        lock.withLock {
            saveAttempt += 1
            guard !failedSaveAttempts.contains(saveAttempt) else { return false }
            storedUser = user
            return true
        }
    }

    func loadCredentialRevision(environment: String, subject: String) throws -> Int? {
        lock.withLock { credentialRevisions["\(environment):\(subject)"] }
    }

    func saveCredentialRevision(
        _ revision: Int,
        environment: String,
        subject: String
    ) -> Bool {
        lock.withLock {
            credentialRevisions["\(environment):\(subject)"] = revision
            return true
        }
    }
}


private actor CirclemsCompletionReplayTransport {
    private let responseBody: Data
    private(set) var requests: [URLRequest] = []
    private(set) var commitCount = 0

    init(responseBody: Data) {
        self.responseBody = responseBody
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if requests.count == 1 {
            commitCount = 1
            throw URLError(.networkConnectionLost)
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (responseBody, response)
    }
}

private actor RefreshSingleFlightTransport {
    let profile: Data
    private(set) var refreshCount = 0
    private(set) var profileCount = 0

    init(profile: Data) {
        self.profile = profile
    }

    func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body: Data
        switch (request.url?.path, request.httpMethod) {
        case ("/api/v2/auth/refresh", "POST"):
            refreshCount += 1
            try await Task.sleep(for: .milliseconds(50))
            body = Data(#"{"tokenType":"Bearer","authVersion":1,"accessToken":"fresh-access","expiresAt":"2099-08-09T00:15:00Z","refreshToken":"fresh-refresh","refreshExpiresAt":"2099-09-09T00:15:00Z","user":{"id":"0123456789abcdef0123456789abcdef","displayName":"利用者","avatarURL":null,"revision":1,"identities":[{"provider":"circlems","environment":"production","providerUserID":42,"email":null}]}}"#.utf8)
        case ("/api/v2/me", "GET"):
            profileCount += 1
            body = profile
        default:
            throw CominaviServiceError.invalidResponse
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (body, response)
    }
}

private actor GeneratedFavoriteRefreshTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var refreshCount = 0
    private(set) var favoriteCount = 0

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let body: Data
        let statusCode: Int
        switch (request.url?.path, request.httpMethod) {
        case ("/api/v2/auth/refresh", "POST"):
            refreshCount += 1
            body = Data(
                #"{"tokenType":"Bearer","authVersion":1,"accessToken":"fresh-access","expiresAt":"2099-08-09T00:15:00Z","refreshToken":"fresh-refresh","refreshExpiresAt":"2099-09-09T00:15:00Z","user":{"id":"0123456789abcdef0123456789abcdef","displayName":"利用者","avatarURL":null,"revision":1,"identities":[{"provider":"circlems","environment":"production","providerUserID":42,"email":null}]}}"#.utf8
            )
            statusCode = 200
        case ("/api/v2/me/favorites/108", "GET"):
            favoriteCount += 1
            if favoriteCount == 1 {
                body = Data(
                    #"{"error":"invalid_token","message":"The access token expired."}"#.utf8
                )
                statusCode = 401
            } else {
                body = Data(
                    #"{"eventNumber":108,"revision":7,"favorites":[]}"#.utf8
                )
                statusCode = 200
            }
        default:
            throw CominaviServiceError.invalidResponse
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (body, response)
    }
}

private actor SuspendedProviderAuthenticationTransport {
    private let providerPath: String
    private let providerResponse: Data
    private let logoutRequestID: UUID
    private let logoutAuthVersion: Int
    private let circleStartResponse: Data?
    private var providerContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(
        providerPath: String,
        providerResponse: Data,
        logoutRequestID: UUID,
        logoutAuthVersion: Int,
        circleStartResponse: Data? = nil
    ) {
        self.providerPath = providerPath
        self.providerResponse = providerResponse
        self.logoutRequestID = logoutRequestID
        self.logoutAuthVersion = logoutAuthVersion
        self.circleStartResponse = circleStartResponse
    }

    func waitUntilProviderRequestIsSuspended() async {
        while providerContinuation == nil {
            await Task.yield()
        }
    }

    func resumeProviderResponse() {
        providerContinuation?.resume()
        providerContinuation = nil
    }

    func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path
        let data: Data
        switch (path, request.httpMethod) {
        case (providerPath, "POST"):
            await withCheckedContinuation { continuation in
                providerContinuation = continuation
            }
            data = providerResponse
        case ("/api/v2/auth/circlems/start", "POST"):
            data = try XCTUnwrap(circleStartResponse)
        case ("/api/v2/auth/logout", "POST"):
            guard request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer predecessor-access",
                  let body = request.httpBody,
                  let object = try JSONSerialization.jsonObject(with: body)
                    as? [String: Any],
                  object["requestId"] as? String
                    == logoutRequestID.uuidString.lowercased(),
                  object["refreshToken"] as? String
                    == String(repeating: "p", count: 43)
            else { throw CominaviServiceError.invalidResponse }
            data = try JSONSerialization.data(withJSONObject: [
                "receipt": [
                    "requestId": logoutRequestID.uuidString.lowercased(),
                    "replayed": false,
                    "authVersion": logoutAuthVersion,
                ],
            ], options: [.sortedKeys])
        default:
            throw CominaviServiceError.invalidResponse
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }
}

private actor SuspendedResponseLossReplayTransport {
    private let path: String
    private let responseData: Data
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(path: String, responseData: Data) {
        self.path = path
        self.responseData = responseData
    }

    func waitUntilFirstResponseIsSuspended() async {
        while firstContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstResponseAsLost() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.url?.path == path, request.httpMethod == "POST" else {
            throw CominaviServiceError.invalidResponse
        }
        requests.append(request)
        if requests.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
            throw URLError(.networkConnectionLost)
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (responseData, response)
    }
}

private actor InvocationCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor SuspendedProfileLogoutProbe {
    private var revokeContinuation: CheckedContinuation<Void, Never>?
    private(set) var events: [String] = []

    func revokeSession() async throws {
        events.append("revoke")
        await withCheckedContinuation { continuation in
            revokeContinuation = continuation
        }
    }

    func waitUntilRevokeIsSuspended() async {
        while revokeContinuation == nil {
            await Task.yield()
        }
    }

    func resumeRevoke() {
        revokeContinuation?.resume()
        revokeContinuation = nil
    }

    func clearLocalUserData() {
        events.append("cleanup")
    }
}

private actor LogoutEpochReplayTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var authVersion: Int
    private(set) var commitCount = 0
    private let commitBeforeFirstFailure: Bool

    init(startingAuthVersion: Int, commitBeforeFirstFailure: Bool = false) {
        authVersion = startingAuthVersion
        self.commitBeforeFirstFailure = commitBeforeFirstFailure
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard request.url?.path == "/api/v2/auth/logout",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization")
                == "Bearer predecessor-access",
              let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let requestID = object["requestId"] as? String,
              let uuid = UUID(uuidString: requestID),
              requestID == uuid.uuidString.lowercased(),
              object["refreshToken"] as? String == String(repeating: "p", count: 43)
        else { throw CominaviServiceError.invalidResponse }

        if requests.count == 1 {
            if commitBeforeFirstFailure {
                authVersion += 1
                commitCount += 1
            }
            throw URLError(.notConnectedToInternet)
        }
        let replayed = commitCount > 0
        if !replayed {
            authVersion += 1
            commitCount += 1
        }
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "receipt": [
                "requestId": requestID,
                "replayed": replayed,
                "authVersion": authVersion,
            ],
        ], options: [.sortedKeys])
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (responseBody, response)
    }
}

private actor AccountDeletionReplayTransport {
    private let responseData: Data
    private(set) var requests: [URLRequest] = []
    private(set) var commitCount = 0

    init(response: Data) {
        responseData = response
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard request.url?.path == "/api/v2/me",
              request.httpMethod == "DELETE",
              request.value(forHTTPHeaderField: "Authorization")
                == "Bearer predecessor-access",
              let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let requestID = object["requestId"] as? String,
              let uuid = UUID(uuidString: requestID),
              requestID == uuid.uuidString.lowercased(),
              object["confirmation"] as? String == "DELETE"
        else { throw CominaviServiceError.invalidResponse }

        if requests.count == 1 {
            commitCount += 1
            throw URLError(.networkConnectionLost)
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 202,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (responseData, response)
    }
}

private actor PushDeviceTransportStub {
    private(set) var requests: [URLRequest] = []

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let path = try XCTUnwrap(request.url?.path)
        let installationID = try XCTUnwrap(path.split(separator: "/").last).description
        guard path == "/api/v2/me/devices/\(installationID)" else {
            throw CominaviServiceError.invalidResponse
        }
        let enabled: Bool
        switch request.httpMethod {
        case "PUT": enabled = true
        case "DELETE": enabled = false
        default: throw CominaviServiceError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "installationID": installationID,
            "enabled": enabled,
        ])
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }
}

private actor CominaviServiceTransportStub {
    private var storedRequests: [URLRequest] = []

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        storedRequests.append(request)
        let path = request.url?.path
        let body: String
        let statusCode: Int
        switch (path, request.httpMethod) {
        case ("/api/v2/me/favorites/108", "GET"):
            body = #"{"eventNumber":108,"revision":2,"favorites":[]}"#
            statusCode = 200
        case ("/api/v2/me/favorites/108", "PUT"):
            body = #"{"eventNumber":108,"revision":3,"favorites":[{"wcID":23000001,"color":2,"notificationsEnabled":true}]}"#
            statusCode = 200
        case ("/api/v2/events/108/updates", "GET"):
            body = #"{"eventNumber":108,"hasMore":false,"publicationRevision":"none","publicationGeneration":0,"publicationCursor":0,"resetRequired":false,"updates":[{"cursor":41,"eventKey":"twitterapi:1:inventory_sold_out","updateKind":"inventory_sold_out","stateKind":"inventory","stateValue":"sold_out","confidence":"high","occurredAt":"2026-08-15T03:00:00Z","sourceRevision":1,"post":{"id":"1","url":"https://x.com/circle/status/1","text":"完売しました","author":{"xUserID":"9","handle":"circle","name":"Circle","profileImageURL":null},"media":[]},"circles":[{"eventNumber":108,"wcID":23000001,"circleID":100,"circleName":"Circle","day":1,"areaName":"西","blockName":"ア","spaceNo":1,"spaceNoSub":0,"location":"1日目 西 ア01a"}]}]}"#
            statusCode = 200
        case ("/api/v2/auth/logout", "POST"):
            let requestBody = try XCTUnwrap(request.httpBody)
            let requestObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let requestID = try XCTUnwrap(requestObject["requestId"] as? String)
            body = #"{"receipt":{"requestId":"\#(requestID)","replayed":false,"authVersion":2}}"#
            statusCode = 200
        default:
            throw CominaviServiceError.invalidResponse
        }
        let response = try XCTUnwrap(
            try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] {
        storedRequests
    }
}
