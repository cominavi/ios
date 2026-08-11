@testable import ComiNavi
import Foundation
import XCTest

@MainActor
final class SharedPlanFavoriteImportTests: XCTestCase {
    func testPreviewDeduplicatesExistingCirclesAndPartialImportRetriesOnlyFailure() async {
        let preview = FavoriteImportPreviewStub(pages: [
            nil: CirclemsFavoriteImportPage(
                eventNumber: 108,
                items: [Self.item(1, "Existing"), Self.item(2, "Retry")],
                nextCursor: "page-2"
            ),
            "page-2": CirclemsFavoriteImportPage(
                eventNumber: 108,
                items: [
                    CirclemsFavoriteImportItem(
                        wcID: 2,
                        updateID: 9_999,
                        circleName: "Retry after catalog update",
                        color: 2,
                        memo: "new catalog version"
                    ),
                    Self.item(3, "Success"),
                ],
                nextCursor: nil
            ),
        ])
        let plan = FavoriteImportPlanStub(snapshot: Self.snapshot(existingWCID: 1))
        plan.failuresRemaining[2] = 1
        let model = SharedPlanFavoriteImportModel(
            planID: Self.planID,
            eventNumber: 108,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )

        await model.load(preview: preview, plan: plan)
        XCTAssertEqual(model.items.map(\.wcID), [1, 2, 3])
        XCTAssertEqual(model.missingItems.map(\.wcID), [2, 3])
        XCTAssertEqual(model.selectedWCIDs, [2, 3])

        await model.importSelected(into: plan, now: Self.now)
        XCTAssertEqual(plan.attemptedWCIDs, [2, 3])
        XCTAssertEqual(model.importedWCIDs, [3])
        XCTAssertEqual(model.failures.map(\.wcID), [2])
        XCTAssertEqual(model.missingItems.map(\.wcID), [2])
        XCTAssertEqual(model.selectedWCIDs, [2])

        await model.importSelected(into: plan, now: Self.now)
        XCTAssertEqual(plan.attemptedWCIDs, [2, 3, 2])
        XCTAssertEqual(model.importedWCIDs, [2, 3])
        XCTAssertTrue(model.missingItems.isEmpty)
        XCTAssertTrue(model.failures.isEmpty)
        let requestedCursors = await preview.requestedCursors
        XCTAssertEqual(requestedCursors, [nil, "page-2"])
    }

    func testReadOnlyAndUnavailablePreviewFailClosedWithoutPlanMutation() async {
        let plan = FavoriteImportPlanStub(snapshot: Self.snapshot(existingWCID: 1))
        let unavailable = FavoriteImportPreviewStub(error: CominaviServiceError.invalidResponse)
        let failed = SharedPlanFavoriteImportModel(
            planID: Self.planID,
            eventNumber: 108,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )
        await failed.load(preview: unavailable, plan: plan)
        XCTAssertNotNil(failed.issueMessage)
        XCTAssertTrue(failed.items.isEmpty)

        let preview = FavoriteImportPreviewStub(pages: [
            nil: CirclemsFavoriteImportPage(
                eventNumber: 108,
                items: [Self.item(2, "Missing")],
                nextCursor: nil
            ),
        ])
        let readOnly = SharedPlanFavoriteImportModel(
            planID: Self.planID,
            eventNumber: 108,
            features: SharedPlanPresentationFeatures(writesEnabled: false)
        )
        await readOnly.load(preview: preview, plan: plan)
        XCTAssertFalse(readOnly.permitsImport)
        await readOnly.importSelected(into: plan, now: Self.now)
        XCTAssertTrue(plan.attemptedWCIDs.isEmpty)
        XCTAssertNotNil(readOnly.issueMessage)
    }

    private static let planID = "11111111-1111-4111-8111-111111111111"
    private static let now = Date(timeIntervalSince1970: 1_000)

    private static func item(_ wcID: Int, _ name: String) -> CirclemsFavoriteImportItem {
        CirclemsFavoriteImportItem(
            wcID: wcID,
            updateID: wcID + 100,
            circleName: name,
            color: 1,
            memo: "memo \(wcID)"
        )
    }

    private static func snapshot(existingWCID: Int) -> SharedPlanEditorSnapshot {
        let key = SharedPlanCircleKey(comiketNo: 108, wcID: existingWCID)!
        return SharedPlanEditorSnapshot(
            plan: SharedPlan(
                id: planID,
                name: "Import",
                comiketNo: 108,
                ownership: .owned,
                role: .owner,
                lifecycle: .active,
                revision: 1,
                circleKeys: [key],
                createdAt: now,
                updatedAt: now
            ),
            circles: [SharedPlanCircleContent(
                key: key,
                presence: .present,
                memo: "",
                needs: [],
                communicationState: [:]
            )],
            conflicts: [],
            syncStatus: .synchronized(mutationsEnabled: true, pendingOperationCount: 0),
            pendingOperationCount: 0,
            localEditLimit: nil,
            syncIssue: nil,
            recoveryDocument: nil,
            recoveryRebaseAvailable: false,
            permitsContentMutations: true
        )
    }
}

private actor FavoriteImportPreviewStub: CirclemsFavoriteImportServicing {
    private let pages: [String?: CirclemsFavoriteImportPage]
    private let error: Error?
    private(set) var requestedCursors: [String?] = []

    init(
        pages: [String?: CirclemsFavoriteImportPage] = [:],
        error: Error? = nil
    ) {
        self.pages = pages
        self.error = error
    }

    func circlemsFavoriteImportPage(
        eventNumber: Int,
        cursor: String?
    ) async throws -> CirclemsFavoriteImportPage {
        requestedCursors.append(cursor)
        if let error { throw error }
        guard let page = pages[cursor] else { throw CominaviServiceError.invalidResponse }
        return page
    }
}

@MainActor
private final class FavoriteImportPlanStub: SharedPlanCircleImporting {
    let snapshot: SharedPlanEditorSnapshot
    var failuresRemaining: [Int: Int] = [:]
    private(set) var attemptedWCIDs: [Int] = []

    init(snapshot: SharedPlanEditorSnapshot) {
        self.snapshot = snapshot
    }

    func editorSnapshot(planID: String) async throws -> SharedPlanEditorSnapshot {
        snapshot
    }

    func addCircle(
        _ key: SharedPlanCircleKey,
        to planID: String,
        now: Date
    ) async throws -> Bool {
        attemptedWCIDs.append(key.wcID)
        if let count = failuresRemaining[key.wcID], count > 0 {
            failuresRemaining[key.wcID] = count - 1
            throw SharedPlanError.persistenceFailed
        }
        return true
    }
}
