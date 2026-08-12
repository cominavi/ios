@testable import ComiNavi
import Foundation
import XCTest

@MainActor
final class SharedPlanPhaseBPresentationTests: XCTestCase {
    func testProductionGateStartsWritableSyncAndRoutesMutation() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = SharedPlanEditorModel(planID: Self.planID)

        await model.load(using: service)
        await model.setCirclePresence(
            .active,
            circle: Self.circle,
            using: service,
            now: Self.now
        )

        XCTAssertNil(model.readOnlyReason)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(service.startSyncCount, 1)
        XCTAssertEqual(service.actions, [.circlePresence(.active, Self.circle)])
    }

    func testExplicitDisabledGateKeepsEditorReadOnlyAndSendsNoMutation() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = SharedPlanEditorModel(
            planID: Self.planID,
            features: SharedPlanPresentationFeatures(writesEnabled: false)
        )

        await model.load(using: service)
        await model.setCirclePresence(
            .active,
            circle: Self.circle,
            using: service,
            now: Self.now
        )

        XCTAssertEqual(model.readOnlyReason, .featureDisabled)
        XCTAssertFalse(model.canEdit)
        XCTAssertTrue(service.actions.isEmpty)
        XCTAssertEqual(service.startSyncCount, 1)
        XCTAssertNotNil(model.issueMessage)
    }

    func testPurchaseRequestRequiresANameAndCarriesRequesterPrice() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        await model.load(using: service)

        await model.createNeed(
            requesterUserID: Self.userID,
            itemName: "   ",
            unitPrice: 2_500,
            wantedQuantity: 1,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        XCTAssertTrue(service.actions.isEmpty)
        XCTAssertNotNil(model.issueMessage)

        model.dismissIssue()
        await model.createNeed(
            requesterUserID: Self.userID,
            itemName: "  アクキー  ",
            unitPrice: 2_500,
            wantedQuantity: 1,
            circle: Self.circle,
            id: Self.needID,
            using: service,
            now: Self.now
        )

        XCTAssertEqual(service.actions, [
            .createNeed(
                SharedPlanPurchaseNeed(
                    id: Self.needID,
                    requesterUserID: Self.userID,
                    itemName: "アクキー",
                    unitPrice: 2_500,
                    wantedQuantity: 1
                ),
                Self.circle
            ),
        ])
    }

    func testPurchaseItemPresetsCoverCommonComiketMerchandise() {
        XCTAssertEqual(
            SharedPlanPurchaseItemPreset.allCases.map(\.rawValue),
            [
                "newReleaseSet",
                "newReleaseOnly",
                "acrylicKeychain",
                "acrylicStand",
                "stickerSet",
            ]
        )
        XCTAssertTrue(SharedPlanPurchaseItemPreset.allCases.allSatisfy { !$0.itemName.isEmpty })
    }

    func testPurchaseProgressUpdateRoutesRequestedAndBoughtTogether() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        await model.load(using: service)

        await model.setPurchaseProgress(
            requestedQuantity: 4,
            boughtQuantity: 3,
            needID: Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )

        XCTAssertEqual(service.actions, [
            .wanted(4, Self.needID, Self.circle),
            .fulfilled(3, Self.needID, Self.circle),
        ])
    }

    func testAllTenOperationTypesRouteExactTypedPayloads() async throws {
        let circleParent = makeParentConflict(
            id: "circle-parent",
            path: ["circles", "101"],
            selectedParentID: Self.circleParentID
        )
        let needParent = makeParentConflict(
            id: "need-parent",
            path: [
                "circles", "101", "needs",
                Self.needID.uuidString.lowercased(),
            ],
            selectedParentID: Self.needParentID
        )
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            conflicts: [circleParent.parentConflict, needParent.parentConflict]
        ))
        service.circleParentInventory = circleParent
        service.needParentInventory = needParent
        let model = makeWritableModel()
        await model.load(using: service)

        await model.setCirclePresence(
            .active,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setCirclePresence(
            .removed,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        model.stageMemo("共同メモ👨‍👩‍👧‍👦", circle: Self.circle, using: service)
        await model.flushMemo(circle: Self.circle, using: service, now: Self.now)
        await model.createNeed(
            requesterUserID: Self.userID,
            itemName: "新刊のみ",
            unitPrice: 1_000,
            wantedQuantity: 3,
            circle: Self.circle,
            id: Self.needID,
            using: service,
            now: Self.now
        )
        await model.deleteNeed(
            Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setWantedQuantity(
            4,
            needID: Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setBuyerAllocation(
            2,
            buyerUserID: Self.buyerID,
            needID: Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setFulfilledQuantity(
            1,
            needID: Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setCommunication(
            .string("連絡済み"),
            field: "status",
            circle: Self.circle,
            using: service,
            now: Self.now
        )

        await resolveParent(
            conflict: circleParent.parentConflict,
            parentID: Self.circleParentID,
            model: model,
            service: service
        )
        await resolveParent(
            conflict: needParent.parentConflict,
            parentID: Self.needParentID,
            model: model,
            service: service
        )

        XCTAssertEqual(service.actions, [
            .circlePresence(.active, Self.circle),
            .circlePresence(.removed, Self.circle),
            .memo("共同メモ👨‍👩‍👧‍👦", Self.circle),
            .createNeed(
                SharedPlanPurchaseNeed(
                    id: Self.needID,
                    requesterUserID: Self.userID,
                    itemName: "新刊のみ",
                    unitPrice: 1_000,
                    wantedQuantity: 3
                ),
                Self.circle
            ),
            .deleteNeed(Self.needID, Self.circle),
            .wanted(4, Self.needID, Self.circle),
            .allocation(2, Self.buyerID, Self.needID, Self.circle),
            .fulfilled(1, Self.needID, Self.circle),
            .communication(.string("連絡済み"), "status", Self.circle),
            .resolveCircleParent(
                Self.circleParentID,
                .active,
                [nestedResolution(from: circleParent)]
            ),
            .resolveNeedParent(
                Self.needParentID,
                .active,
                [nestedResolution(from: needParent)]
            ),
        ])
    }

    func testMemoDebounceCoalescesUnicodeDraftAndStopFlushesLatestValue() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel(memoDebounce: .milliseconds(30))
        await model.load(using: service)

        model.stageMemo("か", circle: Self.circle, using: service)
        model.stageMemo("かき", circle: Self.circle, using: service)
        model.stageMemo("かき👨‍👩‍👧‍👦", circle: Self.circle, using: service)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(service.actions, [
            .memo("かき👨‍👩‍👧‍👦", Self.circle),
        ])
        XCTAssertFalse(model.hasUnsavedMemoDrafts)

        model.stageMemo("離脱前の最終値", circle: Self.circle, using: service)
        await model.stop(using: service, now: Self.now)
        XCTAssertEqual(service.actions.last, .memo("離脱前の最終値", Self.circle))
        XCTAssertEqual(service.stopSyncCount, 1)
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
    }

    func testMemoProductionDebounceWaitsFourSecondsAndStopFlushesImmediately() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        await model.load(using: service)

        model.stageMemo("4秒待って保存", circle: Self.circle, using: service)
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertTrue(service.memoAttempts.isEmpty)
        XCTAssertTrue(model.hasUnsavedMemoDrafts)

        await model.stop(using: service, now: Self.now)
        XCTAssertEqual(service.memoAttempts, ["4秒待って保存"])
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
    }

    func testMemoDraftIsNotCreatedForAnyReadOnlyAuthorityReason() async {
        let cases: [(SharedPlanEditorModel, SharedPlanEditorSnapshot)] = [
            (
                SharedPlanEditorModel(
                    planID: Self.planID,
                    features: SharedPlanPresentationFeatures(writesEnabled: false)
                ),
                makeSnapshot()
            ),
            (
                makeWritableModel(),
                makeSnapshot(plan: makePlan(lifecycle: .archived))
            ),
            (
                makeWritableModel(),
                makeSnapshot(plan: makePlan(role: .viewer))
            ),
            (
                makeWritableModel(),
                makeSnapshot(permitsContentMutations: false)
            ),
            (
                makeWritableModel(),
                makeSnapshot(syncIssue: .membershipRevoked)
            ),
            (
                makeWritableModel(),
                makeSnapshot(localEditLimit: .syncBacklog(maximum: 1_000, pending: 1_000))
            ),
        ]

        for (model, snapshot) in cases {
            let service = PhaseBEditorServiceStub(snapshot: snapshot)
            await model.load(using: service)
            model.stageMemo("保存してはいけない", circle: Self.circle, using: service)
            XCTAssertFalse(model.hasUnsavedMemoDrafts)
            XCTAssertTrue(model.memoDraftRecoveries.isEmpty)
            XCTAssertTrue(service.actions.isEmpty)
        }
    }

    func testMemoDebounceWaitsForAnotherMutationAndPersistsLatestUnicodeOnce() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        service.suspendNextWantedMutation = true
        let model = makeWritableModel(memoDebounce: .milliseconds(10))
        await model.load(using: service)

        let wantedTask = Task { @MainActor in
            await model.setWantedQuantity(
                2,
                needID: Self.needID,
                circle: Self.circle,
                using: service,
                now: Self.now
            )
        }
        await service.waitUntilWantedMutationIsSuspended()
        model.stageMemo("待機中👨‍👩‍👧‍👦e\u{301}", circle: Self.circle, using: service)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(service.memoAttempts, [])

        service.releaseWantedMutation()
        await wantedTask.value
        try await waitUntil { service.memoAttempts.count == 1 }

        XCTAssertEqual(service.memoAttempts, ["待機中👨‍👩‍👧‍👦e\u{301}"])
        XCTAssertEqual(service.actions.filter(\.isMemo), [
            .memo("待機中👨‍👩‍👧‍👦e\u{301}", Self.circle),
        ])
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
    }

    func testRemovedCircleBeforeStopPreservesKeyedMemoRecoveryExport() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel(memoDebounce: .seconds(30))
        await model.load(using: service)
        model.stageMemo("消してはいけない下書き", circle: Self.circle, using: service)

        service.snapshot = makeSnapshot(
            circles: [],
            syncStatus: .quarantined(.membershipRevoked),
            syncIssue: .membershipRevoked,
            permitsContentMutations: false
        )
        await model.reload(using: service)
        await model.stop(using: service, now: Self.now)

        XCTAssertTrue(service.memoAttempts.isEmpty)
        XCTAssertTrue(model.hasUnsavedMemoDrafts)
        let recovery = model.memoDraftRecoveries.first
        XCTAssertEqual(recovery?.circle, Self.circle)
        XCTAssertEqual(recovery?.text, "消してはいけない下書き")
        XCTAssertTrue(recovery?.exportText.contains("\"wcID\":101") == true)
        XCTAssertTrue(recovery?.exportText.contains("消してはいけない下書き") == true)
        XCTAssertEqual(service.stopSyncCount, 1)
    }

    func testMemoFailureRetainsAndRetriesExactGeneration() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        service.memoFailuresRemaining = 1
        let model = makeWritableModel(
            memoDebounce: .milliseconds(10),
            memoRetryDelay: .milliseconds(10)
        )
        await model.load(using: service)
        model.stageMemo("再試行する本文", circle: Self.circle, using: service)

        try await waitUntil { service.memoAttempts.count == 2 }

        XCTAssertEqual(service.memoAttempts, ["再試行する本文", "再試行する本文"])
        XCTAssertEqual(service.actions.filter(\.isMemo), [
            .memo("再試行する本文", Self.circle),
        ])
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
        XCTAssertEqual(model.memoText(for: Self.circle), "再試行する本文")
    }

    func testMemoSuccessClearsSubmittedGenerationDespiteConcurrentMergedText() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        service.suspendNextMemoMutation = true
        service.memoResultTexts = ["同時編集後の第三の値", "最終マージ値"]
        let model = makeWritableModel(memoDebounce: .milliseconds(10))
        await model.load(using: service)

        model.stageMemo("第一世代", circle: Self.circle, using: service)
        let firstFlush = Task { @MainActor in
            await model.flushMemo(circle: Self.circle, using: service, now: Self.now)
        }
        await service.waitUntilMemoMutationIsSuspended()
        model.stageMemo("第二世代", circle: Self.circle, using: service)
        service.releaseMemoMutation()
        await firstFlush.value
        XCTAssertEqual(model.memoText(for: Self.circle), "第二世代")

        try await waitUntil { service.memoAttempts.count == 2 }
        XCTAssertEqual(service.memoAttempts, ["第一世代", "第二世代"])
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
        XCTAssertEqual(model.memoText(for: Self.circle), "最終マージ値")
    }

    func testScalarConflictForwardsOnlyAnExactCurrentCandidate() async {
        let conflict = makeScalarConflict()
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(conflicts: [conflict]))
        let model = makeWritableModel()
        await model.load(using: service)

        await model.resolveConflict(
            conflictID: conflict.id,
            selectedChangeHash: Self.hashB,
            using: service,
            now: Self.now
        )

        XCTAssertEqual(service.actions, [
            .resolveConflict(conflict.id, Self.hashB),
        ])

        service.snapshot = makeSnapshot(conflicts: [conflict])
        service.resolveConflictError = SharedPlanError.syncProtocolViolation
        await model.reload(using: service)
        await model.resolveConflict(
            conflictID: conflict.id,
            selectedChangeHash: Self.hashC,
            using: service,
            now: Self.now
        )
        XCTAssertEqual(service.actions.count, 1)
        XCTAssertNotNil(model.issueMessage)
    }

    func testParentResolutionRequiresEveryExactNestedChoice() async {
        let inventory = makeParentConflict(
            id: "circle-parent",
            path: ["circles", "101"],
            selectedParentID: Self.circleParentID,
            nestedCount: 2
        )
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            conflicts: [inventory.parentConflict]
        ))
        service.circleParentInventory = inventory
        let model = makeWritableModel()
        await model.load(using: service)
        await model.prepareParentResolution(
            conflictID: inventory.parentConflict.id,
            selectedParentOperationID: Self.circleParentID,
            using: service
        )

        model.selectParentPresence(.active)
        let first = inventory.requiredNestedConflicts[0]
        model.selectNestedCandidate(
            conflictID: first.id,
            changeHash: first.candidates[0].changeHash
        )
        await model.submitParentResolution(using: service, now: Self.now)
        XCTAssertTrue(service.actions.isEmpty)
        XCTAssertNotNil(model.issueMessage)

        let second = inventory.requiredNestedConflicts[1]
        model.selectNestedCandidate(conflictID: second.id, changeHash: Self.hashC)
        XCTAssertNotNil(model.issueMessage)
        model.selectNestedCandidate(
            conflictID: second.id,
            changeHash: second.candidates[0].changeHash
        )
        await model.submitParentResolution(using: service, now: Self.now)

        XCTAssertEqual(service.actions, [
            .resolveCircleParent(
                Self.circleParentID,
                .active,
                [
                    nestedResolution(
                        conflict: first,
                        candidate: first.candidates[0]
                    ),
                    nestedResolution(
                        conflict: second,
                        candidate: second.candidates[0]
                    ),
                ]
            ),
        ])
        XCTAssertNil(model.parentResolutionDraft)
    }

    func testLocalPrecommitLimitIsReadOnlyButKeepsRecoveryAndSourceProjection() async {
        let recovery = makeRecovery()
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            pendingOperationCount: 1_000,
            localEditLimit: .syncBacklog(maximum: 1_000, pending: 1_000),
            recoveryDocument: recovery,
            permitsContentMutations: true
        ))
        let model = makeWritableModel()

        await model.load(using: service)
        await model.setWantedQuantity(
            5,
            needID: Self.needID,
            circle: Self.circle,
            using: service,
            now: Self.now
        )

        XCTAssertEqual(
            model.readOnlyReason,
            .localLimit(.syncBacklog(maximum: 1_000, pending: 1_000))
        )
        XCTAssertEqual(model.pendingOperationCount, 1_000)
        XCTAssertEqual(model.circles, makeSnapshot().circles)
        XCTAssertEqual(model.recoveryDocument, recovery)
        XCTAssertTrue(service.actions.isEmpty)
        XCTAssertEqual(service.startSyncCount, 1)
    }

    func testTerminalQuarantineRecoveryUsesExplicitDiscardOrRebase() async {
        let issue = SharedPlanSyncIssue.backlogLimit(maximum: 1_000, received: 1_001)
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            syncStatus: .quarantined(issue),
            syncIssue: issue,
            recoveryDocument: makeRecovery(),
            recoveryRebaseAvailable: true,
            permitsContentMutations: false
        ))
        let model = makeWritableModel()
        await model.load(using: service)

        XCTAssertEqual(model.readOnlyReason, .quarantine(issue))
        await model.discardAndRebootstrap(using: service)
        XCTAssertEqual(service.actions, [.discardAndRebootstrap])
        XCTAssertNil(model.syncIssue)
        XCTAssertNil(model.recoveryDocument)

        service.snapshot = makeSnapshot(
            syncStatus: .quarantined(issue),
            syncIssue: issue,
            recoveryDocument: makeRecovery(),
            recoveryRebaseAvailable: true,
            permitsContentMutations: false
        )
        await model.reload(using: service)
        await model.rebaseUnsyncedContent(using: service, now: Self.now)
        XCTAssertEqual(service.actions, [.discardAndRebootstrap, .rebase])
        XCTAssertNil(model.syncIssue)
        XCTAssertNil(model.recoveryDocument)
    }

    func testOpaqueRecoveryOffersDiscardWithoutAttemptingRebase() async {
        let issue = SharedPlanSyncIssue.unavailable("retained document is malformed")
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            syncStatus: .quarantined(issue),
            syncIssue: issue,
            recoveryDocument: makeRecovery(),
            recoveryRebaseAvailable: false,
            permitsContentMutations: false
        ))
        let model = makeWritableModel()
        await model.load(using: service)

        await model.rebaseUnsyncedContent(using: service, now: Self.now)

        XCTAssertTrue(service.actions.isEmpty)
        XCTAssertNotNil(model.issueMessage)
        XCTAssertNotNil(model.recoveryDocument)
        XCTAssertFalse(model.recoveryRebaseAvailable)

        await model.discardAndRebootstrap(using: service)
        XCTAssertEqual(service.actions, [.discardAndRebootstrap])
        XCTAssertNil(model.recoveryDocument)
    }

    func testArchivedViewerAndWaitingForWritableSyncRemainDistinct() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            plan: makePlan(lifecycle: .archived)
        ))
        let model = makeWritableModel()
        await model.load(using: service)
        XCTAssertEqual(model.readOnlyReason, .archived)

        service.snapshot = makeSnapshot(plan: makePlan(role: .viewer))
        await model.reload(using: service)
        XCTAssertEqual(model.readOnlyReason, .insufficientRole)

        service.snapshot = makeSnapshot(permitsContentMutations: false)
        await model.reload(using: service)
        XCTAssertEqual(model.readOnlyReason, .waitingForWritableSync)
    }

    func testOnlyFailedSyncStatesProduceToastCopy() {
        let silentStates: [SharedPlanSyncConnectionStatus] = [
            .idle,
            .connecting,
            .connected(mutationsEnabled: true, pendingOperationCount: 1),
            .synchronized(mutationsEnabled: true, pendingOperationCount: 0),
        ]

        XCTAssertTrue(silentStates.allSatisfy {
            SharedPlanEditorSyncFailurePresentation(status: $0) == nil
        })
        XCTAssertEqual(
            SharedPlanEditorSyncFailurePresentation(
                status: .reconnecting("offline")
            )?.detail,
            "offline"
        )
        XCTAssertNotNil(
            SharedPlanEditorSyncFailurePresentation(
                status: .quarantined(.membershipRevoked)
            )
        )
    }

    func testEveryReadOnlyAuthorityHasDistinctActionablePresentation() {
        let reasons: [SharedPlanEditorReadOnlyReason] = [
            .featureDisabled,
            .archived,
            .insufficientRole,
            .waitingForWritableSync,
            .localLimit(.syncBacklog(maximum: 1_000, pending: 1_000)),
            .localLimit(.compactionRequired),
            .quarantine(.membershipRevoked),
            .quarantine(.roleChanged),
            .quarantine(.unavailable("malformed")),
            .quarantine(.serverCompactionRequired),
            .quarantine(.backlogLimit(maximum: 1_000, received: 1_001)),
        ]
        let presentations = reasons.map(SharedPlanEditorReadOnlyPresentation.init)

        XCTAssertEqual(Set(presentations.map(\.title)).count, presentations.count)
        XCTAssertTrue(presentations.allSatisfy { !$0.detail.isEmpty && !$0.systemImage.isEmpty })
        XCTAssertTrue(presentations[4].detail.contains("1,000"))
        XCTAssertTrue(presentations[5].detail.contains(String(localized: "Download")))
        XCTAssertTrue(presentations[10].detail.contains("1,001"))
        let implementationTerms = ["operation", "branch", "frame", "generation", "interoperable"]
        XCTAssertTrue(presentations.flatMap { [$0.title, $0.detail] }.allSatisfy { text in
            implementationTerms.allSatisfy { !text.localizedCaseInsensitiveContains($0) }
        })
    }

    func testConflictPresentationUsesPlainLanguageWithoutProtocolDetails() {
        let conflict = makeScalarConflict()
        let presentation = SharedPlanConflictPresentation(conflict: conflict)

        XCTAssertEqual(presentation.title, String(localized: "Choose one value"))
        XCTAssertEqual(presentation.path, String(localized: "Requested"))
        XCTAssertFalse(presentation.title.contains(Self.hashA))
        XCTAssertEqual(conflict.candidates[0].value.sharedPlanDisplayText, "1")
        XCTAssertEqual(
            SharedPlanJSONValue.object(["state": .string("removed")])
                .sharedPlanDisplayText,
            String(localized: "Removed")
        )
    }

    func testPurchaseProgressUsesRequestedAssignedAndBoughtStages() {
        func progress(
            requested: Int = 4,
            assigned: Int,
            bought: Int,
            conflict: Bool = false
        ) -> SharedPlanPurchaseProgressPresentation {
            SharedPlanPurchaseProgressPresentation(
                need: SharedPlanPurchaseNeed(
                    id: Self.needID,
                    requesterUserID: Self.userID,
                    itemName: "新刊セット",
                    unitPrice: 2_000,
                    wantedQuantity: requested,
                    buyerAllocations: assigned == 0 ? [:] : [Self.userID: assigned],
                    fulfilledQuantity: bought
                ),
                hasConflict: conflict
            )
        }

        XCTAssertEqual(progress(assigned: 0, bought: 0).state, .requested)
        XCTAssertEqual(progress(assigned: 2, bought: 0).state, .partiallyAssigned)
        XCTAssertEqual(progress(assigned: 4, bought: 0).state, .assigned)
        XCTAssertEqual(progress(assigned: 4, bought: 2).state, .partiallyBought)
        XCTAssertEqual(progress(assigned: 4, bought: 4).state, .bought)
        XCTAssertEqual(progress(assigned: 5, bought: 0).state, .needsReview)
        XCTAssertEqual(progress(assigned: 4, bought: 5).state, .needsReview)
        XCTAssertEqual(progress(assigned: 4, bought: 0, conflict: true).state, .needsReview)
        XCTAssertEqual(progress(assigned: 2, bought: 1).assignedFraction, 0.5)
        XCTAssertEqual(progress(assigned: 2, bought: 1).boughtFraction, 0.25)

        let matchingAssignedAndBought = progress(assigned: 3, bought: 3)
        XCTAssertEqual(matchingAssignedAndBought.requested, 4)
        XCTAssertEqual(matchingAssignedAndBought.assigned, 3)
        XCTAssertEqual(matchingAssignedAndBought.bought, 3)
        XCTAssertEqual(matchingAssignedAndBought.assignedFraction, 0.75)
        XCTAssertEqual(matchingAssignedAndBought.boughtFraction, 0.75)
    }

    func testCircleIdentityCombinesNamePenNameDayAndCatalogLocation() {
        let identity = SharedPlanCircleIdentityPresentation(
            circleName: " うどん道場 ",
            penName: " 青井 ",
            day: 1,
            blockName: "東A",
            spaceNumber: 12,
            spaceNumberSub: 1
        )

        XCTAssertEqual(identity.circleName, "うどん道場")
        XCTAssertEqual(identity.penName, "青井")
        XCTAssertEqual(identity.dayAndLocation, String(localized: "Day 1 · 東A12b"))
        XCTAssertEqual(identity.displayName, "うどん道場 · 青井")
        XCTAssertEqual(identity.navigationSubtitle, "うどん道場 · 青井")

        let fallback = SharedPlanCircleIdentityPresentation(
            circleName: " ",
            penName: nil,
            day: nil,
            blockName: nil,
            spaceNumber: nil,
            spaceNumberSub: nil
        )
        XCTAssertEqual(fallback.circleName, String(localized: "Unnamed circle"))
        XCTAssertNil(fallback.penName)
        XCTAssertEqual(fallback.displayName, String(localized: "Unnamed circle"))
        XCTAssertFalse(fallback.displayName.contains("WCID"))
        XCTAssertEqual(fallback.dayAndLocation, String(localized: "Location unavailable"))
    }

    func testEditorAccessibilityIdentifiersAreStableAndEntityScoped() {
        let otherCircle = SharedPlanCircleKey(comiketNo: 108, wcID: 102)!
        let otherNeed = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let identifiers = [
            SharedPlanEditorAccessibilityID.screen,
            SharedPlanEditorAccessibilityID.readOnly,
            SharedPlanEditorAccessibilityID.circle(Self.circle),
            SharedPlanEditorAccessibilityID.circle(otherCircle),
            SharedPlanEditorAccessibilityID.memo(Self.circle),
            SharedPlanEditorAccessibilityID.addNeed(Self.circle),
            SharedPlanEditorAccessibilityID.need(Self.needID),
            SharedPlanEditorAccessibilityID.need(otherNeed),
            SharedPlanEditorAccessibilityID.needProgress(Self.needID),
            SharedPlanEditorAccessibilityID.needProgressPreview(Self.needID),
            SharedPlanEditorAccessibilityID.conflict("scalar-wanted"),
        ]

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(
            SharedPlanEditorAccessibilityID.circle(Self.circle),
            "shared-plan-editor-circle-108:101"
        )
        XCTAssertTrue(
            SharedPlanEditorAccessibilityID.need(Self.needID)
                .hasSuffix(Self.needID.uuidString.lowercased())
        )
    }

    func testBackgroundFlushPersistsLatestUnicodeDraftWithoutStoppingSync() async {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel(memoDebounce: .seconds(30))
        await model.load(using: service)
        model.stageMemo("背景保存👨‍👩‍👧‍👦e\u{301}", circle: Self.circle, using: service)

        await model.flushAllMemos(using: service, now: Self.now)

        XCTAssertEqual(service.actions.filter(\.isMemo), [
            .memo("背景保存👨‍👩‍👧‍👦e\u{301}", Self.circle),
        ])
        XCTAssertEqual(service.stopSyncCount, 0)
        XCTAssertFalse(model.hasUnsavedMemoDrafts)
    }

    func testOlderSuspendedProjectionCannotOverwriteNewerRemoteAuthority() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        await model.load(using: service)

        service.suspendNextProjection = true
        let staleReload = Task { @MainActor in
            await model.reload(using: service)
        }
        await service.waitUntilProjectionIsSuspended()

        let conflict = makeScalarConflict()
        let updated = makeSnapshot(
            plan: makePlan(role: .viewer),
            circles: [SharedPlanCircleContent(
                key: Self.circle,
                presence: .present,
                memo: "remote",
                needs: [],
                communicationState: [:]
            )],
            conflicts: [conflict],
            syncStatus: .reconnecting("remote authority changed"),
            permitsContentMutations: false
        )
        service.publish(updated)
        await model.reload(using: service)
        service.releaseProjection()
        await staleReload.value

        XCTAssertEqual(model.plan?.role, .viewer)
        XCTAssertEqual(model.circles.first?.memo, "remote")
        XCTAssertEqual(model.conflicts.map(\.id), [conflict.id])
        XCTAssertEqual(model.readOnlyReason, .insufficientRole)
        XCTAssertEqual(model.appliedProjectionGeneration, service.projectionGeneration)
    }

    func testProjectionSubscriptionAppliesRemoteChangesAndCancellationStopsOnce() async throws {
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        let run = Task { @MainActor in await model.run(using: service) }
        try await waitUntil { model.plan != nil }

        let updated = makeSnapshot(
            plan: makePlan(lifecycle: .archived),
            circles: [],
            syncStatus: .idle,
            permitsContentMutations: false
        )
        service.publish(updated)
        try await waitUntil { model.readOnlyReason == .archived }

        run.cancel()
        await run.value
        XCTAssertEqual(service.stopSyncCount, 1)
        XCTAssertTrue(model.circles.isEmpty)
    }

    func testArchivedViewerAndQuarantineNeverStartPlanSync() async {
        let snapshots = [
            makeSnapshot(plan: makePlan(lifecycle: .archived)),
            makeSnapshot(plan: makePlan(role: .viewer)),
            makeSnapshot(
                syncStatus: .quarantined(.membershipRevoked),
                syncIssue: .membershipRevoked,
                permitsContentMutations: false
            ),
        ]
        for snapshot in snapshots {
            let service = PhaseBEditorServiceStub(snapshot: snapshot)
            await makeWritableModel().load(using: service)
            XCTAssertEqual(service.startSyncCount, 0)
        }
    }

    func testLateParentInventoryCannotReplaceNewSheetRequest() async {
        let first = makeParentConflict(
            id: "parent-race",
            path: ["circles", "101"],
            selectedParentID: Self.circleParentID
        )
        let secondParentID = try! XCTUnwrap(
            first.parentConflict.parentRootOperationIDs.first { $0 != Self.circleParentID }
        )
        let second = SharedPlanParentResolutionInventory(
            parentConflict: first.parentConflict,
            selectedParentOperationID: secondParentID,
            requiredNestedConflicts: first.requiredNestedConflicts
        )
        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot(
            conflicts: [first.parentConflict]
        ))
        service.circleParentInventories = [
            Self.circleParentID: first,
            secondParentID: second,
        ]
        service.suspendedParentID = Self.circleParentID
        let model = makeWritableModel()
        await model.load(using: service)

        let stale = Task { @MainActor in
            await model.prepareParentResolution(
                conflictID: first.parentConflict.id,
                selectedParentOperationID: Self.circleParentID,
                using: service
            )
        }
        await service.waitUntilParentInventoryIsSuspended()
        await model.prepareParentResolution(
            conflictID: first.parentConflict.id,
            selectedParentOperationID: secondParentID,
            using: service
        )
        service.releaseParentInventory()
        await stale.value

        XCTAssertEqual(
            model.parentResolutionDraft?.inventory.selectedParentOperationID,
            secondParentID
        )
    }

    func testStructuredConflictSummaryUsesFriendlyMembersAndDistinctValues() {
        let member = makeMember(
            userID: Self.buyerID,
            displayName: "買い手さん",
            role: .editor
        )
        let summary = SharedPlanJSONValue.object([
            Self.buyerID: .integer(2),
            "status": .string("受取済み"),
            "nested": .array([.string("A"), .string("B")]),
        ]).sharedPlanDisplayText(
            members: [member.userID: member],
            currentUserID: Self.userID
        )

        XCTAssertTrue(summary.contains("買い手さん"))
        XCTAssertTrue(summary.contains("2"))
        XCTAssertTrue(summary.contains("受取済み"))
        XCTAssertTrue(summary.contains("1. A"))
        XCTAssertFalse(summary.contains("Structured value"))
    }

    func testProgressAndMemberOutcomeRemainTypedAndQuantityAware() async {
        let circle = SharedPlanCircleContent(
            key: Self.circle,
            presence: .present,
            memo: "",
            needs: [
                SharedPlanPurchaseNeed(
                    id: Self.needID,
                    requesterUserID: Self.userID,
                    wantedQuantity: 5,
                    buyerAllocations: [Self.userID: 4, Self.buyerID: 2],
                    fulfilledQuantity: 2
                ),
                SharedPlanPurchaseNeed(
                    id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                    requesterUserID: Self.buyerID,
                    wantedQuantity: 3,
                    buyerAllocations: [Self.buyerID: 1],
                    fulfilledQuantity: 4
                ),
            ],
            communicationState: [
                SharedPlanMemberOutcome.communicationField: .string("deferred"),
            ]
        )
        let progress = SharedPlanProgressSummary(circles: [circle], conflictCount: 2)
        XCTAssertEqual(progress.wanted, 8)
        XCTAssertEqual(progress.assigned, 7)
        XCTAssertEqual(progress.covered, 6)
        XCTAssertEqual(progress.fulfilled, 5)
        XCTAssertEqual(progress.outstanding, 3)
        XCTAssertEqual(progress.overAssigned, 1)
        XCTAssertEqual(progress.conflicted, 2)
        XCTAssertEqual(progress.terminalOutcomeCircles, 1)
        XCTAssertEqual(progress.assignedFraction, 0.875)
        XCTAssertEqual(progress.fulfilledFraction, 0.625)
        XCTAssertEqual(progress.fulfilledPercentage, 63)

        let emptyProgress = SharedPlanProgressSummary(circles: [], conflictCount: 0)
        XCTAssertEqual(emptyProgress.assignedFraction, 0)
        XCTAssertEqual(emptyProgress.fulfilledFraction, 0)
        XCTAssertEqual(emptyProgress.fulfilledPercentage, 0)

        let service = PhaseBEditorServiceStub(snapshot: makeSnapshot())
        let model = makeWritableModel()
        await model.load(using: service)
        await model.setMemberOutcome(
            .skipped,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        await model.setMemberOutcome(
            nil,
            circle: Self.circle,
            using: service,
            now: Self.now
        )
        XCTAssertEqual(Array(service.actions.suffix(2)), [
            .communication(
                .string("skipped"),
                SharedPlanMemberOutcome.communicationField,
                Self.circle
            ),
            .communication(
                .null,
                SharedPlanMemberOutcome.communicationField,
                Self.circle
            ),
        ])
    }
}

private enum PhaseBEditorAction: Equatable {
    case circlePresence(SharedPlanPresenceState, SharedPlanCircleKey)
    case memo(String, SharedPlanCircleKey)
    case createNeed(SharedPlanPurchaseNeed, SharedPlanCircleKey)
    case deleteNeed(UUID, SharedPlanCircleKey)
    case wanted(Int, UUID, SharedPlanCircleKey)
    case allocation(Int, String, UUID, SharedPlanCircleKey)
    case fulfilled(Int, UUID, SharedPlanCircleKey)
    case communication(SharedPlanJSONValue, String, SharedPlanCircleKey)
    case resolveConflict(String, String)
    case resolveCircleParent(
        UUID,
        SharedPlanPresenceState,
        [SharedPlanNestedConflictResolution]
    )
    case resolveNeedParent(
        UUID,
        SharedPlanPresenceState,
        [SharedPlanNestedConflictResolution]
    )
    case discardAndRebootstrap
    case rebase
}

private extension PhaseBEditorAction {
    var isMemo: Bool {
        if case .memo = self { return true }
        return false
    }
}

@MainActor
private final class PhaseBEditorServiceStub: SharedPlanEditorServicing {
    var snapshot: SharedPlanEditorSnapshot
    var projectionGeneration: UInt64 = 1
    var actions: [PhaseBEditorAction] = []
    var circleParentInventory: SharedPlanParentResolutionInventory?
    var circleParentInventories: [UUID: SharedPlanParentResolutionInventory] = [:]
    var needParentInventory: SharedPlanParentResolutionInventory?
    var resolveConflictError: Error?
    var memoFailuresRemaining = 0
    var memoResultTexts: [String] = []
    var memoAttempts: [String] = []
    var suspendNextMemoMutation = false
    var suspendNextWantedMutation = false
    var startSyncCount = 0
    var stopSyncCount = 0
    var suspendNextProjection = false
    private var projectionContinuation: AsyncStream<UInt64>.Continuation?
    private var suspendedProjectionContinuation: CheckedContinuation<Void, Never>?
    private var suspendedProjectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var memoMutationContinuation: CheckedContinuation<Void, Never>?
    private var memoMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var wantedMutationContinuation: CheckedContinuation<Void, Never>?
    private var wantedMutationWaiters: [CheckedContinuation<Void, Never>] = []
    var suspendedParentID: UUID?
    private var parentInventoryContinuation: CheckedContinuation<Void, Never>?
    private var parentInventoryWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: SharedPlanEditorSnapshot) {
        self.snapshot = snapshot
    }

    func load() async {}

    func editorSnapshot(planID: String) async throws -> SharedPlanEditorSnapshot {
        guard planID == snapshot.plan.id else { throw SharedPlanError.planNotFound }
        return snapshot
    }

    func editorProjection(planID: String) async throws -> SharedPlanEditorProjection {
        guard planID == snapshot.plan.id else { throw SharedPlanError.planNotFound }
        let captured = SharedPlanEditorProjection(
            generation: projectionGeneration,
            snapshot: snapshot
        )
        if suspendNextProjection {
            suspendNextProjection = false
            await withCheckedContinuation { continuation in
                suspendedProjectionContinuation = continuation
                let waiters = suspendedProjectionWaiters
                suspendedProjectionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return captured
    }

    func editorProjectionUpdates(planID: String) -> AsyncStream<UInt64> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            projectionContinuation = continuation
            continuation.yield(projectionGeneration)
        }
    }

    func publish(_ snapshot: SharedPlanEditorSnapshot) {
        self.snapshot = snapshot
        projectionGeneration &+= 1
        projectionContinuation?.yield(projectionGeneration)
    }

    func waitUntilProjectionIsSuspended() async {
        if suspendedProjectionContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspendedProjectionWaiters.append(continuation)
        }
    }

    func releaseProjection() {
        suspendedProjectionContinuation?.resume()
        suspendedProjectionContinuation = nil
    }

    func startSync(planID: String) async {
        startSyncCount += 1
    }

    func stopSync(planID: String) async {
        stopSyncCount += 1
    }

    func addCircle(
        _ key: SharedPlanCircleKey,
        to planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.circlePresence(.active, key))
        return true
    }

    func removeCircle(
        _ key: SharedPlanCircleKey,
        from planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.circlePresence(.removed, key))
        return true
    }

    func updateMemo(
        _ memo: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        memoAttempts.append(memo)
        let waiters = memoMutationWaiters
        memoMutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendNextMemoMutation {
            suspendNextMemoMutation = false
            await withCheckedContinuation { continuation in
                memoMutationContinuation = continuation
            }
        }
        if memoFailuresRemaining > 0 {
            memoFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        actions.append(.memo(memo, key))
        let visibleMemo = memoResultTexts.isEmpty ? memo : memoResultTexts.removeFirst()
        snapshot = snapshot.replacingMemo(visibleMemo, circle: key)
        return true
    }

    func persistMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        snapshot = snapshot.replacingMemoDraft(draft)
    }

    func commitMemoDraft(
        _ draft: SharedPlanMemoDraft,
        now: Date
    ) async throws -> Bool {
        let result = try await updateMemo(
            draft.text,
            circle: draft.circle,
            planID: draft.planID,
            now: now
        )
        snapshot = snapshot.removingMemoDraft(draft)
        return result
    }

    func waitUntilMemoMutationIsSuspended() async {
        if memoMutationContinuation != nil { return }
        await withCheckedContinuation { continuation in
            memoMutationWaiters.append(continuation)
        }
    }

    func releaseMemoMutation() {
        memoMutationContinuation?.resume()
        memoMutationContinuation = nil
    }

    func createPurchaseNeed(
        _ need: SharedPlanPurchaseNeed,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.createNeed(need, key))
        return true
    }

    func deletePurchaseNeed(
        _ needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.deleteNeed(needID, key))
        return true
    }

    func setWantedQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        let waiters = wantedMutationWaiters
        wantedMutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendNextWantedMutation {
            suspendNextWantedMutation = false
            await withCheckedContinuation { continuation in
                wantedMutationContinuation = continuation
            }
        }
        actions.append(.wanted(quantity, needID, key))
        return true
    }

    func waitUntilWantedMutationIsSuspended() async {
        if wantedMutationContinuation != nil { return }
        await withCheckedContinuation { continuation in
            wantedMutationWaiters.append(continuation)
        }
    }

    func releaseWantedMutation() {
        wantedMutationContinuation?.resume()
        wantedMutationContinuation = nil
    }

    func setBuyerAllocation(
        _ quantity: Int,
        buyerUserID: String,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.allocation(quantity, buyerUserID, needID, key))
        return true
    }

    func setFulfilledQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.fulfilled(quantity, needID, key))
        return true
    }

    func setCommunication(
        _ value: SharedPlanJSONValue,
        field: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool {
        actions.append(.communication(value, field, key))
        return true
    }

    func resolveDocumentConflict(
        planID: String,
        conflictID: String,
        selectedChangeHash: String,
        now: Date
    ) async throws -> Bool {
        if let resolveConflictError { throw resolveConflictError }
        guard snapshot.conflicts.contains(where: {
            $0.id == conflictID && $0.candidates.contains(where: {
                $0.changeHash == selectedChangeHash
            })
        }) else { throw SharedPlanError.syncProtocolViolation }
        actions.append(.resolveConflict(conflictID, selectedChangeHash))
        snapshot = snapshot.removingConflict(id: conflictID)
        return true
    }

    func circleParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory {
        guard circle == SharedPlanPhaseBPresentationTests.circle,
              let inventory = circleParentInventories[selectedParentOperationID]
                ?? circleParentInventory,
              inventory.selectedParentOperationID == selectedParentOperationID
        else { throw SharedPlanError.syncProtocolViolation }
        if suspendedParentID == selectedParentOperationID {
            suspendedParentID = nil
            await withCheckedContinuation { continuation in
                parentInventoryContinuation = continuation
                let waiters = parentInventoryWaiters
                parentInventoryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return inventory
    }

    func waitUntilParentInventoryIsSuspended() async {
        if parentInventoryContinuation != nil { return }
        await withCheckedContinuation { continuation in
            parentInventoryWaiters.append(continuation)
        }
    }

    func releaseParentInventory() {
        parentInventoryContinuation?.resume()
        parentInventoryContinuation = nil
    }

    func needParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory {
        guard circle == SharedPlanPhaseBPresentationTests.circle,
              needID == SharedPlanPhaseBPresentationTests.needID,
              needParentInventory?.selectedParentOperationID == selectedParentOperationID,
              let needParentInventory
        else { throw SharedPlanError.syncProtocolViolation }
        return needParentInventory
    }

    func resolveCircleParent(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date
    ) async throws -> Bool {
        guard let inventory = circleParentInventory else {
            throw SharedPlanError.syncProtocolViolation
        }
        actions.append(.resolveCircleParent(
            selectedParentOperationID,
            state,
            nestedResolutions
        ))
        snapshot = snapshot.removingConflict(id: inventory.parentConflict.id)
        return true
    }

    func resolveNeedParent(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date
    ) async throws -> Bool {
        guard let inventory = needParentInventory else {
            throw SharedPlanError.syncProtocolViolation
        }
        actions.append(.resolveNeedParent(
            selectedParentOperationID,
            state,
            nestedResolutions
        ))
        snapshot = snapshot.removingConflict(id: inventory.parentConflict.id)
        return true
    }

    func discardUnsyncedContentAndRebootstrap(planID: String) async throws {
        actions.append(.discardAndRebootstrap)
        snapshot = snapshot.clearingRecovery()
    }

    func rebaseUnsyncedContent(planID: String, now: Date) async throws {
        actions.append(.rebase)
        snapshot = snapshot.clearingRecovery()
    }
}

private extension SharedPlanEditorSnapshot {
    func replacingMemoDraft(_ draft: SharedPlanMemoDraft) -> SharedPlanEditorSnapshot {
        var drafts = memoDrafts.filter { $0.id != draft.id }
        drafts.append(draft)
        return replacingMemoDrafts(drafts)
    }

    func removingMemoDraft(_ draft: SharedPlanMemoDraft) -> SharedPlanEditorSnapshot {
        replacingMemoDrafts(memoDrafts.filter {
            !($0.id == draft.id && $0.generation == draft.generation)
        })
    }

    private func replacingMemoDrafts(
        _ drafts: [SharedPlanMemoDraft]
    ) -> SharedPlanEditorSnapshot {
        SharedPlanEditorSnapshot(
            plan: plan,
            replicaID: replicaID,
            circles: circles,
            conflicts: conflicts,
            members: members,
            memoDrafts: drafts,
            syncStatus: syncStatus,
            pendingOperationCount: pendingOperationCount,
            localEditLimit: localEditLimit,
            syncIssue: syncIssue,
            recoveryDocument: recoveryDocument,
            recoveryRebaseAvailable: recoveryRebaseAvailable,
            permitsContentMutations: permitsContentMutations
        )
    }

    func replacingMemo(
        _ memo: String,
        circle key: SharedPlanCircleKey
    ) -> SharedPlanEditorSnapshot {
        SharedPlanEditorSnapshot(
            plan: plan,
            replicaID: replicaID,
            circles: circles.map { circle in
                guard circle.key == key else { return circle }
                return SharedPlanCircleContent(
                    key: circle.key,
                    presence: circle.presence,
                    memo: memo,
                    needs: circle.needs,
                    communicationState: circle.communicationState
                )
            },
            conflicts: conflicts,
            members: members,
            memoDrafts: memoDrafts,
            syncStatus: syncStatus,
            pendingOperationCount: pendingOperationCount,
            localEditLimit: localEditLimit,
            syncIssue: syncIssue,
            recoveryDocument: recoveryDocument,
            recoveryRebaseAvailable: recoveryRebaseAvailable,
            permitsContentMutations: permitsContentMutations
        )
    }

    func removingConflict(id: String) -> SharedPlanEditorSnapshot {
        SharedPlanEditorSnapshot(
            plan: plan,
            replicaID: replicaID,
            circles: circles,
            conflicts: conflicts.filter { $0.id != id },
            members: members,
            memoDrafts: memoDrafts,
            syncStatus: syncStatus,
            pendingOperationCount: pendingOperationCount,
            localEditLimit: localEditLimit,
            syncIssue: syncIssue,
            recoveryDocument: recoveryDocument,
            recoveryRebaseAvailable: recoveryRebaseAvailable,
            permitsContentMutations: permitsContentMutations
        )
    }

    func clearingRecovery() -> SharedPlanEditorSnapshot {
        SharedPlanEditorSnapshot(
            plan: plan,
            replicaID: replicaID,
            circles: circles,
            conflicts: conflicts,
            members: members,
            memoDrafts: memoDrafts,
            syncStatus: .idle,
            pendingOperationCount: 0,
            localEditLimit: nil,
            syncIssue: nil,
            recoveryDocument: nil,
            recoveryRebaseAvailable: false,
            permitsContentMutations: true
        )
    }
}

private extension SharedPlanPhaseBPresentationTests {
    static let planID = "11111111-1111-4111-8111-111111111111"
    static let userID = "00000000000000000000000000000001"
    static let buyerID = "00000000000000000000000000000002"
    static let needID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let circleParentID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let needParentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let nestedOperationID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let circle = SharedPlanCircleKey(comiketNo: 108, wcID: 101)!
    static let now = Date(timeIntervalSince1970: 1_786_276_800)
    static let hashA = String(repeating: "a", count: 64)
    static let hashB = String(repeating: "b", count: 64)
    static let hashC = String(repeating: "c", count: 64)

    func makeWritableModel(
        memoDebounce: Duration = .seconds(4),
        memoRetryDelay: Duration = .seconds(2)
    ) -> SharedPlanEditorModel {
        SharedPlanEditorModel(
            planID: Self.planID,
            features: SharedPlanPresentationFeatures(writesEnabled: true),
            memoDebounce: memoDebounce,
            memoRetryDelay: memoRetryDelay
        )
    }

    func makePlan(
        role: SharedPlanRole = .owner,
        lifecycle: SharedPlanLifecycle = .active
    ) -> SharedPlan {
        SharedPlan(
            id: Self.planID,
            name: "共同購入",
            comiketNo: 108,
            ownership: .owned,
            role: role,
            lifecycle: lifecycle,
            revision: 7,
            circleKeys: [Self.circle],
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    func makeMember(
        userID: String,
        displayName: String,
        role: SharedPlanRole,
        status: SharedPlanMembershipStatus = .active
    ) -> SharedPlanMember {
        SharedPlanMember(
            userID: userID,
            displayName: displayName,
            avatarURL: nil,
            role: role,
            membershipStatus: status,
            joinedAt: Self.now,
            removedAt: status == .removed ? Self.now : nil
        )
    }

    func makeSnapshot(
        plan: SharedPlan? = nil,
        replicaID: UUID? = UUID(uuidString: "77777777-7777-4777-8777-777777777777"),
        circles: [SharedPlanCircleContent]? = nil,
        conflicts: [SharedPlanDocumentConflict] = [],
        members: [SharedPlanMember] = [],
        memoDrafts: [SharedPlanMemoDraft] = [],
        syncStatus: SharedPlanSyncConnectionStatus = .synchronized(
            mutationsEnabled: true,
            pendingOperationCount: 0
        ),
        pendingOperationCount: Int = 0,
        localEditLimit: SharedPlanLocalEditLimit? = nil,
        syncIssue: SharedPlanSyncIssue? = nil,
        recoveryDocument: SharedPlanRecoveryDocument? = nil,
        recoveryRebaseAvailable: Bool = false,
        permitsContentMutations: Bool = true
    ) -> SharedPlanEditorSnapshot {
        SharedPlanEditorSnapshot(
            plan: plan ?? makePlan(),
            replicaID: replicaID,
            circles: circles ?? [SharedPlanCircleContent(
                key: Self.circle,
                presence: .present,
                memo: "",
                needs: [SharedPlanPurchaseNeed(
                    id: Self.needID,
                    requesterUserID: Self.userID,
                    wantedQuantity: 1
                )],
                communicationState: [:]
            )],
            conflicts: conflicts,
            members: members,
            memoDrafts: memoDrafts,
            syncStatus: syncStatus,
            pendingOperationCount: pendingOperationCount,
            localEditLimit: localEditLimit,
            syncIssue: syncIssue,
            recoveryDocument: recoveryDocument,
            recoveryRebaseAvailable: recoveryRebaseAvailable,
            permitsContentMutations: permitsContentMutations
        )
    }

    func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func makeRecovery() -> SharedPlanRecoveryDocument {
        SharedPlanRecoveryDocument(
            planID: Self.planID,
            pendingOperationCount: 1_000,
            metadataIntentCount: 0,
            exportText: "{\"planID\":\"(Self.planID)\"}"
        )
    }

    func makeScalarConflict() -> SharedPlanDocumentConflict {
        SharedPlanDocumentConflict(
            conflictID: "scalar-wanted",
            kind: .scalar,
            path: [
                "circles", "101", "needs",
                Self.needID.uuidString.lowercased(), "wantedQuantity",
            ],
            candidates: [
                candidate(hash: Self.hashA, value: .integer(1)),
                candidate(hash: Self.hashB, value: .integer(2)),
            ]
        )
    }

    func makeParentConflict(
        id: String,
        path: [String],
        selectedParentID: UUID,
        nestedCount: Int = 1
    ) -> SharedPlanParentResolutionInventory {
        let otherParentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let parent = SharedPlanDocumentConflict(
            conflictID: id,
            kind: .parent,
            path: path,
            candidates: [
                candidate(
                    hash: Self.hashA,
                    value: .object(["state": .string("active")]),
                    operationID: selectedParentID,
                    rootOperationID: selectedParentID
                ),
                candidate(
                    hash: Self.hashB,
                    value: .object(["state": .string("removed")]),
                    operationID: otherParentID,
                    rootOperationID: otherParentID
                ),
            ],
            parentRootOperationIDs: [selectedParentID, otherParentID]
        )
        let nested = (0..<nestedCount).map { index in
            SharedPlanDocumentConflict(
                conflictID: "\(id)-nested-\(index)",
                kind: .scalar,
                path: path + ["field-\(index)"],
                candidates: [candidate(
                    hash: index == 0 ? Self.hashA : Self.hashB,
                    value: .string("value-\(index)")
                )]
            )
        }
        return SharedPlanParentResolutionInventory(
            parentConflict: parent,
            selectedParentOperationID: selectedParentID,
            requiredNestedConflicts: nested
        )
    }

    func candidate(
        hash: String,
        value: SharedPlanJSONValue,
        operationID: UUID? = nil,
        rootOperationID: UUID? = nil
    ) -> SharedPlanConflictCandidate {
        SharedPlanConflictCandidate(
            changeHash: hash,
            operationID: operationID ?? Self.nestedOperationID,
            actorUserID: Self.userID,
            value: value,
            rootOperationID: rootOperationID
        )
    }

    func nestedResolution(
        from inventory: SharedPlanParentResolutionInventory
    ) -> SharedPlanNestedConflictResolution {
        let conflict = inventory.requiredNestedConflicts[0]
        return nestedResolution(conflict: conflict, candidate: conflict.candidates[0])
    }

    func nestedResolution(
        conflict: SharedPlanDocumentConflict,
        candidate: SharedPlanConflictCandidate
    ) -> SharedPlanNestedConflictResolution {
        SharedPlanNestedConflictResolution(
            conflictID: conflict.id,
            path: conflict.path,
            selectedChangeHash: candidate.changeHash,
            value: candidate.value
        )
    }

    func resolveParent(
        conflict: SharedPlanDocumentConflict,
        parentID: UUID,
        model: SharedPlanEditorModel,
        service: PhaseBEditorServiceStub
    ) async {
        await model.prepareParentResolution(
            conflictID: conflict.id,
            selectedParentOperationID: parentID,
            using: service
        )
        model.selectParentPresence(.active)
        guard let nested = model.parentResolutionDraft?.inventory
            .requiredNestedConflicts.first,
            let candidate = nested.candidates.first
        else { return }
        model.selectNestedCandidate(
            conflictID: nested.id,
            changeHash: candidate.changeHash
        )
        await model.submitParentResolution(using: service, now: Self.now)
    }
}
