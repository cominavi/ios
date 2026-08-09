import XCTest

@testable import ComiNavi

final class FollowingImportStoreTests: XCTestCase {
    func testSuccessfulImportsUnionRatherThanReplaceStoredCircles() async throws {
        let store = InMemoryUserPlanStore()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        try await store.mergeFollowingImport(
            state: state(importedAt: firstDate, matchedCircleCount: 1),
            sources: [source(publicID: 101, importedAt: firstDate)]
        )
        try await store.mergeFollowingImport(
            state: state(importedAt: secondDate, matchedCircleCount: 1),
            sources: [source(publicID: 102, importedAt: secondDate)]
        )

        let sources = try await store.importedCircleSources(eventNumber: 108)
        XCTAssertEqual(sources.map(\.publicCircleID), [101, 102])
        let importState = try await store.followingImportState(eventNumber: 108)
        XCTAssertEqual(importState?.importedAt, secondDate)
    }

    func testRepeatedMatchKeepsFirstImportAndUpdatesLastSeen() async throws {
        let store = InMemoryUserPlanStore()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        try await store.mergeFollowingImport(
            state: state(importedAt: firstDate, matchedCircleCount: 1),
            sources: [source(publicID: 101, importedAt: firstDate)]
        )
        try await store.mergeFollowingImport(
            state: state(importedAt: secondDate, matchedCircleCount: 1),
            sources: [source(publicID: 101, importedAt: secondDate)]
        )

        let storedSources = try await store.importedCircleSources(eventNumber: 108)
        let source = try XCTUnwrap(storedSources.first)
        XCTAssertEqual(source.firstImportedAt, firstDate)
        XCTAssertEqual(source.lastSeenAt, secondDate)
    }

    private func state(
        importedAt: Date,
        matchedCircleCount: Int
    ) -> FollowingImportState {
        FollowingImportState(
            eventNumber: 108,
            twitterUserName: "owner",
            importedAt: importedAt,
            nextAllowedAt: importedAt.addingTimeInterval(6 * 60 * 60),
            followingCount: 100,
            matchedCircleCount: matchedCircleCount
        )
    }

    private func source(publicID: Int, importedAt: Date) -> ImportedCircleSource {
        ImportedCircleSource(
            eventNumber: 108,
            publicCircleID: publicID,
            twitterUserID: "x-\(publicID)",
            twitterUserName: "circle_\(publicID)",
            twitterDisplayName: "Circle \(publicID)",
            profilePictureURL: nil,
            firstImportedAt: importedAt,
            lastSeenAt: importedAt
        )
    }
}
