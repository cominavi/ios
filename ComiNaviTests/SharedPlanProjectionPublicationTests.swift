@testable import ComiNavi
import Foundation
import XCTest

final class SharedPlanProjectionPublicationTests: XCTestCase {
    @MainActor
    func testRepeatedProjectionReadsQuiesceAfterLazyStateLoads() async throws {
        let plan = makePlan(id: "11111111-1111-4111-8111-111111111111")
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: plan.id,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        let snapshot = await document.snapshot(
            pendingOperationIDs: [],
            localEditLimit: .compactionRequired
        )
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveMutation(plan: plan, document: snapshot)
        let store = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "user-1" }
        )
        await store.load()

        _ = try await store.editorProjection(planID: plan.id)
        let settledGeneration = store.editorProjectionGenerations[plan.id]

        let second = try await store.editorProjection(planID: plan.id)
        let third = try await store.editorProjection(planID: plan.id)

        XCTAssertEqual(second.generation, settledGeneration)
        XCTAssertEqual(third.generation, settledGeneration)
        XCTAssertEqual(store.editorProjectionGenerations[plan.id], settledGeneration)
    }

    @MainActor
    func testDocumentPublicationOnlyAdvancesTheChangedPlan() async throws {
        let planA = makePlan(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let planB = makePlan(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let persistence = InMemorySharedPlanPersistence()
        for plan in [planA, planB] {
            let document = try SharedPlanAutomergeDocument(
                fixturePlanID: plan.id,
                comiketNo: plan.comiketNo,
                replicaID: UUID()
            )
            try await persistence.saveMutation(
                plan: plan,
                document: await document.snapshot(pendingOperationIDs: [])
            )
        }
        let store = SharedPlanStore(
            persistence: persistence,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        _ = try await store.editorProjection(planID: planA.id)
        _ = try await store.editorProjection(planID: planB.id)
        _ = try await store.editorProjection(planID: planA.id)
        _ = try await store.editorProjection(planID: planB.id)

        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: planA.comiketNo, wcID: 321)
        )
        let planBGenerationBeforeMutation = store.editorProjectionGenerations[planB.id] ?? 0
        let addedCircle = try await store.addCircle(circle, to: planA.id)
        XCTAssertTrue(addedCircle)
        XCTAssertEqual(
            store.editorProjectionGenerations[planB.id],
            planBGenerationBeforeMutation
        )
        let pendingOperationIDs = try XCTUnwrap(
            store.documentSnapshots[planA.id]?.pendingOperationIDs
        )
        XCTAssertFalse(pendingOperationIDs.isEmpty)
        let planAGeneration = store.editorProjectionGenerations[planA.id] ?? 0
        let planBGeneration = store.editorProjectionGenerations[planB.id] ?? 0

        try await store.acknowledgeOperations(
            Set(pendingOperationIDs),
            planID: planA.id
        )

        XCTAssertGreaterThan(
            store.editorProjectionGenerations[planA.id] ?? 0,
            planAGeneration
        )
        XCTAssertEqual(planBGeneration, planBGenerationBeforeMutation)
        XCTAssertEqual(
            store.editorProjectionGenerations[planB.id],
            planBGenerationBeforeMutation
        )
    }

    private func makePlan(id: String) -> SharedPlan {
        SharedPlan(
            id: id,
            name: id,
            comiketNo: 108,
            ownership: .owned,
            role: .owner,
            lifecycle: .active,
            revision: 1,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
