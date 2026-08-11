@testable import ComiNavi
import Foundation
import XCTest

final class SharedPlanFoundationTests: XCTestCase {
    @MainActor
    func testFiftyOwnedActivePlansAllowNoFiftyFirstPlan() async throws {
        let persistence = InMemorySharedPlanPersistence()
        for index in 0..<50 {
            try await persistence.savePlan(makePlan(id: "plan-\(index)"), write: nil)
        }
        // Joined and archived plans do not consume owner slots.
        try await persistence.savePlan(
            makePlan(id: "joined", ownership: .joined, role: .editor),
            write: nil
        )
        try await persistence.savePlan(
            makePlan(id: "archived", lifecycle: .archived),
            write: nil
        )
        let store = SharedPlanStore(persistence: persistence, actorUserID: { "user-1" })
        await store.load()

        XCTAssertEqual(store.createAvailability(comiketNo: 108).activeOwnedCount, 50)
        XCTAssertFalse(store.createAvailability(comiketNo: 108).canCreate)
        do {
            _ = try await store.createPlan(name: "51件目", comiketNo: 108)
            XCTFail("The 51st active owned plan must be rejected locally")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .planLimitReached(comiketNo: 108))
        }
    }

    @MainActor
    func testArchiveFreesSlotAndReopenRechecksLimit() async throws {
        let persistence = InMemorySharedPlanPersistence()
        for index in 0..<50 {
            try await persistence.savePlan(makePlan(id: "plan-\(index)"), write: nil)
        }
        let store = SharedPlanStore(persistence: persistence, actorUserID: { "user-1" })
        await store.load()

        try await store.archivePlan(id: "plan-0")
        XCTAssertEqual(store.createAvailability(comiketNo: 108).activeOwnedCount, 49)
        try await store.reopenPlan(id: "plan-0")
        XCTAssertEqual(store.createAvailability(comiketNo: 108).activeOwnedCount, 50)

        try await store.archivePlan(id: "plan-0")
        try await persistence.savePlan(makePlan(id: "replacement"), write: nil)
        let relaunched = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        do {
            try await relaunched.reopenPlan(id: "plan-0")
            XCTFail("Reopening must atomically reacquire a slot")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .planLimitReached(comiketNo: 108))
        }
    }

    @MainActor
    func testProductionCreationWaitsForServerUUIDAndExactBootstrap() async throws {
        let serverPlan = makePlan(id: "d171cac7-2dad-4a22-a24a-f3ac0324603f")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bootstrap = SharedPlanSyncBootstrap(
            v: 1,
            document: await serverDocument.save().base64URLEncodedString,
            heads: await serverDocument.heads()
        )
        let remote = SharedPlanRemoteStub(plan: serverPlan, bootstrap: bootstrap)
        let persistence = InMemorySharedPlanPersistence()
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()

        let created = try await store.createPlan(name: serverPlan.name, comiketNo: 108)
        XCTAssertEqual(created.id, serverPlan.id)
        XCTAssertFalse(created.id.hasPrefix("local-"))
        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        let productionDocument = try await store.documentForSync(planID: created.id)
        let actorID = await productionDocument.actorID()
        XCTAssertEqual(actorID, actorID.lowercased())
        XCTAssertNotNil(actorID.range(of: #"^[0-9a-f]+$"#, options: .regularExpression))
        let productionHasRootConflict = try await productionDocument.hasConcurrentRootObjects()
        XCTAssertFalse(productionHasRootConflict)

        let independentA = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: 108,
            replicaID: UUID()
        )
        let independentB = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: 108,
            replicaID: UUID()
        )
        try await independentA.merge(await independentB.save())
        let independentHasRootConflict = try await independentA.hasConcurrentRootObjects()
        XCTAssertTrue(independentHasRootConflict)
    }

    @MainActor
    func testNamedPurchaseRequestWithPriceSurvivesDurableReload() async throws {
        let userID = "user-1"
        let serverPlan = makePlan(id: "a171cac7-2dad-4a22-a24a-f3ac0324603f")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: serverPlan.comiketNo,
            replicaID: UUID()
        )
        let remote = SharedPlanRemoteStub(
            plan: serverPlan,
            bootstrap: SharedPlanSyncBootstrap(
                v: 1,
                document: await serverDocument.save().base64URLEncodedString,
                heads: await serverDocument.heads()
            )
        )
        let persistence = InMemorySharedPlanPersistence()
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { userID }
        )
        await store.load()
        let plan = try await store.createPlan(name: serverPlan.name, comiketNo: 108)
        let circle = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 321))
        let needID = UUID()
        _ = try await store.addCircle(circle, to: plan.id)
        _ = try await store.createPurchaseNeed(
            SharedPlanPurchaseNeed(
                id: needID,
                requesterUserID: userID,
                itemName: "新幹線のきっぷ",
                unitPrice: 14_720,
                wantedQuantity: 2
            ),
            circle: circle,
            planID: plan.id
        )

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { userID }
        )
        await relaunched.load()
        let need = try await relaunched.circleContent(circle: circle, planID: plan.id)?
            .needs.first(where: { $0.id == needID })
        XCTAssertEqual(need?.itemName, "新幹線のきっぷ")
        XCTAssertEqual(need?.unitPrice, 14_720)
        XCTAssertEqual(need?.wantedQuantity, 2)
    }

    @MainActor
    func testPaginatedBuyerAuthorityRejectsMemberRemovedBeforeMutation() async throws {
        let currentUserID = "11111111111111111111111111111111"
        let otherUserID = "22222222222222222222222222222222"
        let serverPlan = makePlan(id: "d171cac7-2dad-4a22-a24a-f3ac0324603f")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: serverPlan.comiketNo,
            replicaID: UUID()
        )
        let bootstrap = SharedPlanSyncBootstrap(
            v: 1,
            document: await serverDocument.save().base64URLEncodedString,
            heads: await serverDocument.heads()
        )
        let remote = SharedPlanRemoteStub(plan: serverPlan, bootstrap: bootstrap)
        let joinedAt = Date(timeIntervalSince1970: 100)
        let current = SharedPlanMember(
            userID: currentUserID,
            displayName: "自分",
            avatarURL: nil,
            role: .owner,
            membershipStatus: .active,
            joinedAt: joinedAt,
            removedAt: nil
        )
        let other = SharedPlanMember(
            userID: otherUserID,
            displayName: "買い手",
            avatarURL: nil,
            role: .editor,
            membershipStatus: .active,
            joinedAt: joinedAt,
            removedAt: nil
        )
        await remote.setMemberPages([
            "first": SharedPlanMemberPage(items: [current], nextCursor: "next"),
            "next": SharedPlanMemberPage(items: [other], nextCursor: nil),
        ])
        let persistence = InMemorySharedPlanPersistence()
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { currentUserID }
        )
        await store.load()
        let plan = try await store.createPlan(
            name: serverPlan.name,
            comiketNo: serverPlan.comiketNo
        )
        try await store.refreshAllAllocationMembers(planID: plan.id)
        XCTAssertEqual(store.membersByPlanID[plan.id]?.map(\.userID), [currentUserID, otherUserID])

        let circle = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 321))
        let needID = UUID()
        _ = try await store.addCircle(circle, to: plan.id)
        _ = try await store.createPurchaseNeed(
            SharedPlanPurchaseNeed(
                id: needID,
                requesterUserID: currentUserID,
                wantedQuantity: 2
            ),
            circle: circle,
            planID: plan.id
        )
        _ = try await store.setBuyerAllocation(
            1,
            buyerUserID: otherUserID,
            needID: needID,
            circle: circle,
            planID: plan.id
        )

        let removed = SharedPlanMember(
            userID: otherUserID,
            displayName: "買い手",
            avatarURL: nil,
            role: .editor,
            membershipStatus: .removed,
            joinedAt: joinedAt,
            removedAt: Date(timeIntervalSince1970: 200)
        )
        await remote.setMemberPages([
            "first": SharedPlanMemberPage(items: [current], nextCursor: "next"),
            "next": SharedPlanMemberPage(items: [removed], nextCursor: nil),
        ])
        try await store.refreshAllAllocationMembers(planID: plan.id)

        do {
            _ = try await store.setBuyerAllocation(
                2,
                buyerUserID: otherUserID,
                needID: needID,
                circle: circle,
                planID: plan.id
            )
            XCTFail("A removed member must not receive a new allocation")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .insufficientRole)
        }
        let content = try await store.circleContent(circle: circle, planID: plan.id)
        XCTAssertEqual(content?.needs.first?.buyerAllocations[otherUserID], 1)
    }

    @MainActor
    func testMemoDraftCommitIsAtomicAndExactRetryCannotAuthorDuplicateOperation()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-plan-memo-draft-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try SQLiteSharedPlanPersistence(
            path: directory.appendingPathComponent("shared-plans.sqlite").path
        )
        let userID = "11111111111111111111111111111111"
        let serverPlan = makePlan(id: "d171cac7-2dad-4a22-a24a-f3ac0324603f")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: serverPlan.id,
            comiketNo: serverPlan.comiketNo,
            replicaID: UUID()
        )
        let bootstrap = SharedPlanSyncBootstrap(
            v: 1,
            document: await serverDocument.save().base64URLEncodedString,
            heads: await serverDocument.heads()
        )
        let remote = SharedPlanRemoteStub(plan: serverPlan, bootstrap: bootstrap)
        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { userID }
        )
        await store?.load()
        let plan = try await store?.createPlan(
            name: serverPlan.name,
            comiketNo: serverPlan.comiketNo
        )
        let planID = try XCTUnwrap(plan?.id)
        let circle = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 654))
        _ = try await store?.addCircle(circle, to: planID)
        let initial = try await store?.editorSnapshot(planID: planID)
        let replicaID = try XCTUnwrap(initial?.replicaID)
        let baselinePending = initial?.pendingOperationCount ?? 0
        let draft = SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: circle,
            text: "応答消失後も一度だけ👨‍👩‍👧‍👦e\u{301}",
            generation: 1,
            reason: .staged,
            updatedAt: Date(timeIntervalSince1970: 500),
            recoveryMessage: nil
        )
        try await store?.persistMemoDraft(draft)
        let persistedDrafts = try await persistence.loadMemoDrafts(planID: planID)
        XCTAssertEqual(persistedDrafts, [draft])

        let didCommitDraft = try await store?.commitMemoDraft(draft)
        XCTAssertEqual(didCommitDraft, true)
        let draftsAfterCommit = try await persistence.loadMemoDrafts(planID: planID)
        XCTAssertTrue(draftsAfterCommit.isEmpty)
        let committedPending = try XCTUnwrap(
            store?.documentSnapshots[planID]?.pendingOperationIDs.count
        )
        XCTAssertEqual(committedPending, baselinePending + 1)

        // Model/process termination after the SQLite transaction but before
        // in-memory acknowledgement can only retry the exact draft. Its
        // missing durable generation proves the operation already committed.
        let didReplayDraft = try await store?.commitMemoDraft(draft)
        XCTAssertEqual(didReplayDraft, false)
        XCTAssertEqual(
            store?.documentSnapshots[planID]?.pendingOperationIDs.count,
            committedPending
        )
        store = nil

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { userID }
        )
        await relaunched.load()
        let snapshot = try await relaunched.editorSnapshot(planID: planID)
        XCTAssertTrue(snapshot.memoDrafts.isEmpty)
        XCTAssertEqual(snapshot.pendingOperationCount, committedPending)
        XCTAssertEqual(
            snapshot.circles.first(where: { $0.key == circle })?.memo,
            draft.text
        )
    }

    func testMemoDraftGenerationCASAndUserScopedSQLiteIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-plan-memo-isolation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SQLiteSharedPlanPersistence(
            path: SharedPlanStore.databaseURL(baseDirectory: directory, userID: "user-a").path
        )
        let second = try SQLiteSharedPlanPersistence(
            path: SharedPlanStore.databaseURL(baseDirectory: directory, userID: "user-b").path
        )
        let planID = "11111111-1111-4111-8111-111111111111"
        let replicaID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let circle = SharedPlanCircleKey(comiketNo: 108, wcID: 777)!
        let older = SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: circle,
            text: "old",
            generation: 1,
            reason: .staged,
            updatedAt: Date(timeIntervalSince1970: 1),
            recoveryMessage: nil
        )
        let newer = SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: circle,
            text: "new",
            generation: 2,
            reason: .mutationFailed,
            updatedAt: Date(timeIntervalSince1970: 2),
            recoveryMessage: "retry"
        )
        try await first.saveMemoDraft(newer)
        try await first.saveMemoDraft(older)

        let firstUserDrafts = try await first.loadMemoDrafts(planID: planID)
        XCTAssertEqual(firstUserDrafts, [newer])
        let secondUserDrafts = try await second.loadMemoDrafts(planID: planID)
        XCTAssertTrue(secondUserDrafts.isEmpty)
        let reopened = try SQLiteSharedPlanPersistence(
            path: SharedPlanStore.databaseURL(baseDirectory: directory, userID: "user-a").path
        )
        let relaunchedDrafts = try await reopened.loadMemoDrafts(planID: planID)
        XCTAssertEqual(relaunchedDrafts, [newer])
    }

    @MainActor
    func testFailedCreationKeepsRequestButExposesNoEditableLocalPlan() async throws {
        let persistence = InMemorySharedPlanPersistence()
        let store = SharedPlanStore(persistence: persistence, actorUserID: { "user-1" })
        await store.load()
        do {
            _ = try await store.createPlan(name: "オフライン", comiketNo: 108)
            XCTFail("Creation requires the server UUID and bootstrap")
        } catch {
            XCTAssertTrue(store.plans.isEmpty)
            XCTAssertEqual(store.pendingRESTWrites.count, 1)
            XCTAssertEqual(store.pendingRESTWrites.first?.kind, .create)
        }
    }

    @MainActor
    func testEventMismatchDoesNotPersistOperation() async throws {
        let (store, plan) = try await makeBootstrappedStore()
        let wrong = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 109, wcID: 42))
        do {
            _ = try await store.addCircle(wrong, to: plan.id)
            XCTFail("Cross-event circle identity must fail")
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .eventMismatch(expected: 108, received: 109)
            )
        }
        XCTAssertEqual(store.documentSnapshots[plan.id]?.pendingOperationIDs, [])
    }

    func testStableWCIDResolutionSurvivesCatalogReorderingAndMarksMissingRows() throws {
        let first = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9001))
        let stale = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9002))
        let resolved = SharedPlanCircleResolver.resolve(
            keys: [first, stale],
            comiketNo: 108,
            catalogIDsByWCID: [9001: 77]
        )
        XCTAssertEqual(resolved[0].id, "108:9001")
        XCTAssertEqual(resolved[0].catalogCircleID, 77)
        XCTAssertNil(resolved[1].catalogCircleID)
        XCTAssertTrue(resolved[1].isStaleInCurrentCatalog)
    }

    @MainActor
    func testInviteUniversalAndCustomLinksPersistAcrossColdStart() throws {
        let secrets = InMemorySharedPlanInvitationSecretStore()
        let token = "Abcdef12_-XY"
        let inbox = SharedPlanInvitationInbox(storage: secrets)

        XCTAssertTrue(inbox.receive(url: try XCTUnwrap(URL(
            string: "https://cominavi.net/join/\(token)"
        ))))
        XCTAssertEqual(inbox.pending?.token, token)
        XCTAssertTrue(inbox.isGoogleEntryEligible)
        let relaunched = SharedPlanInvitationInbox(storage: secrets)
        XCTAssertEqual(relaunched.pending?.token, token)
        XCTAssertEqual(
            SharedPlanInvitationLink.token(from: try XCTUnwrap(URL(
                string: "cominavi://join/\(token)"
            ))),
            token
        )
        XCTAssertNil(SharedPlanInvitationLink.token(from: try XCTUnwrap(URL(
            string: "https://cominavi.net/plans/join/\(token)"
        ))))
        XCTAssertNil(SharedPlanInvitationLink.token(from: try XCTUnwrap(URL(
            string: "https://cominavi.net/join/too-short"
        ))))
    }

    @MainActor
    func testDefinitiveInvitationFailureRemainsVisibleButDoesNotSurviveRelaunch() throws {
        let secrets = InMemorySharedPlanInvitationSecretStore()
        let token = "Abcdef12_-XY"
        let inbox = SharedPlanInvitationInbox(storage: secrets)
        XCTAssertTrue(inbox.receive(url: try XCTUnwrap(URL(
            string: "https://cominavi.net/join/\(token)"
        ))))

        inbox.removePersistedCapability(token: token)

        XCTAssertEqual(inbox.pending?.token, token)
        XCTAssertNil(SharedPlanInvitationInbox(storage: secrets).pending)
        inbox.clear()
        XCTAssertNil(inbox.pending)
    }

    @MainActor
    func testInvitationOutboxStoresCapabilityOnlyInProtectedVault() async throws {
        let persistence = InMemorySharedPlanPersistence()
        let vault = InMemorySharedPlanInviteCapabilityVault()
        let store = SharedPlanStore(
            persistence: persistence,
            inviteCapabilityVault: vault,
            actorUserID: { "user-1" }
        )
        await store.load()
        let token = "Abcdef12_-XY"
        let requestID = try await store.acceptInvitation(token: token)
        await store.drainRESTOutbox()

        let writes = try await persistence.loadRESTWrites()
        XCTAssertEqual(writes.map(\.id), [requestID])
        XCTAssertNil(writes.first?.inviteToken)
        let encoded = try JSONEncoder().encode(try XCTUnwrap(writes.first))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(token))
        let protectedToken = await vault.token(requestID: requestID)
        XCTAssertEqual(protectedToken, token)

        try await store.cancelInvitationAcceptance(requestID: requestID)
        let remainingWrites = try await persistence.loadRESTWrites()
        XCTAssertTrue(remainingWrites.isEmpty)
        let removedToken = await vault.token(requestID: requestID)
        XCTAssertNil(removedToken)
    }

    func testDuplicateServerFrameIsIdempotentAndGapFailsClosed() async throws {
        let planID = "11111111-1111-4111-8111-111111111111"
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        let bytes = await seed.save()
        let client = try SharedPlanAutomergeDocument(
            data: bytes,
            replicaID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        )
        let peerReplicaID = UUID(
            uuidString: "01f9af86-e16e-45f4-abcc-4d50b00fa65d"
        )!
        let peer = try SharedPlanAutomergeDocument(
            data: bytes,
            replicaID: peerReplicaID
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 81))
        _ = try await peer.addCircle(
            key,
            operationID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            actorUserID: "peer-user",
            authoredAt: Date(timeIntervalSince1970: 1_000)
        )
        let peerOperationRecords = try await peer.operationRecords()
        XCTAssertEqual(peerOperationRecords.count, 1)
        let sessionID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let session = SharedPlanSyncSession(planID: planID, document: client)
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1
        ))
        // Automerge sync is a handshake: the server peer must first consume
        // the client's heads before it can generate the missing changes.
        await peer.beginSyncSession(id: sessionID)
        let generatedClientGreeting = try await session.nextOutboundFrame()
        let clientGreeting = try XCTUnwrap(generatedClientGreeting)
        try await peer.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: clientGreeting.payload))
        )
        let generatedPayload = try await peer.generateSyncMessage(sessionID: sessionID)
        let payload = try XCTUnwrap(generatedPayload)
        let first = SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 1,
            frameID: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
            payload: payload.base64URLEncodedString
        )
        let firstApplied = try await session.receiveServerFrame(first)
        let duplicateApplied = try await session.receiveServerFrame(first)
        let clientKeys = try await client.circleKeys()
        XCTAssertTrue(firstApplied)
        XCTAssertFalse(duplicateApplied)
        XCTAssertEqual(clientKeys, [key])

        let gap = SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 3,
            frameID: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            payload: payload.base64URLEncodedString
        )
        do {
            _ = try await session.receiveServerFrame(gap)
            XCTFail("A nonduplicate gap must close the session")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
            let state = await session.state
            XCTAssertEqual(state, .failed(code: "sync_protocol_violation", retryable: true))
        }
    }

    @MainActor
    func testOfflineMutationSurvivesRelaunchAndMembershipFailure() async throws {
        let persistence = InMemorySharedPlanPersistence(replicaID: UUID())
        let (remote, plan) = try await makeRemote()
        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store?.load()
        _ = try await store?.createPlan(name: plan.name, comiketNo: 108)
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 101))
        _ = try await store?.addCircle(key, to: plan.id)
        XCTAssertEqual(store?.documentSnapshots[plan.id]?.pendingOperationIDs.count, 1)

        store = nil
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.plans.first?.circleKeys, [key])
        try await relaunched.recordSyncIssue(.membershipRevoked, planID: plan.id)
        XCTAssertEqual(
            relaunched.documentSnapshots[plan.id]?.syncIssue,
            .membershipRevoked
        )
        XCTAssertEqual(
            relaunched.documentSnapshots[plan.id]?.pendingOperationIDs.count,
            1,
            "Revocation must retain unsynced semantic operations"
        )
    }

    func testLogicalRemovalRetainsConcurrentMemoEdit() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 202))
        _ = try await seed.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        let base = await seed.save()
        let removing = try SharedPlanAutomergeDocument(data: base, replicaID: UUID())
        let editing = try SharedPlanAutomergeDocument(data: base, replicaID: UUID())
        _ = try await removing.removeCircle(
            key,
            operationID: UUID(),
            actorUserID: "remover",
            authoredAt: Date()
        )
        _ = try await editing.updateMemo(
            "削除と同時に書いたメモ",
            for: key,
            operationID: UUID(),
            actorUserID: "editor",
            authoredAt: Date()
        )
        try await removing.merge(await editing.save())
        try await editing.merge(await removing.save())

        let presence = try await removing.presence(for: key)
        let removingMemo = try await removing.memo(for: key)
        let editingMemo = try await editing.memo(for: key)
        let operationIDs = await removing.semanticOperationIDs()
        let operationCount = operationIDs.count
        XCTAssertEqual(presence, .removed)
        XCTAssertEqual(removingMemo, "削除と同時に書いたメモ")
        XCTAssertEqual(editingMemo, "削除と同時に書いたメモ")
        XCTAssertEqual(operationCount, 3)
    }

    func testJapaneseCombiningAndComplexEmojiTextConvergesAcrossRounds() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 303))
        _ = try await seed.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        let bytes = await seed.save()
        let left = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        let right = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        let complex = "日本語 e\u{301} 👨‍👩‍👧‍👦"
        _ = try await left.updateMemo(
            complex,
            for: key,
            operationID: UUID(),
            actorUserID: "left",
            authoredAt: Date()
        )
        _ = try await right.updateMemo(
            "先頭",
            for: key,
            operationID: UUID(),
            actorUserID: "right",
            authoredAt: Date()
        )
        try await synchronize(left, right)
        let firstLeftMemo = try await left.memo(for: key)
        let firstRightMemo = try await right.memo(for: key)
        XCTAssertEqual(firstLeftMemo, firstRightMemo)
        XCTAssertTrue(firstLeftMemo?.contains("👨‍👩‍👧‍👦") == true)

        let secondRound = (try await right.memo(for: key) ?? "") + "・終了"
        _ = try await right.updateMemo(
            secondRound,
            for: key,
            operationID: UUID(),
            actorUserID: "right",
            authoredAt: Date()
        )
        try await synchronize(left, right)
        let finalMemo = try await left.memo(for: key)
        XCTAssertEqual(finalMemo, secondRound)
    }

    func testLiteralAutomergeJS326BootstrapLoadsAndCarriesComplexTextSync() async throws {
        let fixture = try JSONDecoder().decode(
            BackendAutomergeBootstrapFixture.self,
            from: try fixtureData(named: "automerge-bootstrap-v1")
        )
        let bytes = try XCTUnwrap(Data(base64URLString: fixture.document))
        let left = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        let right = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())

        XCTAssertEqual(fixture.automergeJS, "3.2.6")
        XCTAssertEqual(left.planID, fixture.planID)
        XCTAssertEqual(left.comiketNo, fixture.comiketNo)
        let swiftHeads = await left.heads()
        XCTAssertEqual(swiftHeads, fixture.heads)
        let hasRootConflict = try await left.hasConcurrentRootObjects()
        XCTAssertFalse(hasRootConflict)

        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 606))
        _ = try await left.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "swift-user",
            authoredAt: Date(timeIntervalSince1970: 1)
        )
        let complex = "日本語 e\u{301} 👩🏽‍💻🫶🏻"
        _ = try await left.updateMemo(
            complex,
            for: key,
            operationID: UUID(),
            actorUserID: "swift-user",
            authoredAt: Date(timeIntervalSince1970: 2)
        )
        try await synchronize(left, right)
        let rightMemo = try await right.memo(for: key)
        XCTAssertEqual(rightMemo, complex)
    }

    func testSyncWireEncodesCanonicalLowercaseUUIDLiteralsAndRejectsUppercase() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let replicaID = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        let frameID = try XCTUnwrap(UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"))
        let frame = SharedPlanClientSyncFrame(
            v: 1,
            type: "sync",
            planID: "11111111-1111-4111-8111-111111111111",
            sessionID: sessionID,
            replicaID: replicaID,
            actorID: "0123456789abcdef0123456789abcdef",
            seq: 1,
            frameID: frameID,
            payload: "AA"
        )
        let encoded = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(#""sessionID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa""#))
        XCTAssertTrue(json.contains(#""replicaID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb""#))
        XCTAssertTrue(json.contains(#""frameID":"cccccccc-cccc-4ccc-8ccc-cccccccccccc""#))
        XCTAssertTrue(json.contains(#""actorID":"0123456789abcdef0123456789abcdef""#))
        XCTAssertTrue(json.contains(#""planID":"11111111-1111-4111-8111-111111111111""#))

        let uppercase = json.replacingOccurrences(
            of: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            with: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            SharedPlanClientSyncFrame.self,
            from: Data(uppercase.utf8)
        ))
        let uppercasePlanID = json.replacingOccurrences(
            of: "11111111-1111-4111-8111-111111111111",
            with: "11111111-1111-4111-8111-11111111111A"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            SharedPlanClientSyncFrame.self,
            from: Data(uppercasePlanID.utf8)
        ))
    }

    func testSharedPlanCacheIsIsolatedBetweenPublicUserIDs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = SharedPlanStore.databaseURL(
            baseDirectory: directory,
            userID: "public-user-a"
        )
        let secondURL = SharedPlanStore.databaseURL(
            baseDirectory: directory,
            userID: "public-user-b"
        )
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertFalse(firstURL.lastPathComponent.contains("public-user-a"))

        let first = try SQLiteSharedPlanPersistence(path: firstURL.path)
        let second = try SQLiteSharedPlanPersistence(path: secondURL.path)
        try await first.savePlan(makePlan(id: "user-a-plan"), write: nil)
        let firstPlans = try await first.loadPlans()
        let secondPlans = try await second.loadPlans()
        XCTAssertEqual(firstPlans.map(\.id), ["user-a-plan"])
        XCTAssertTrue(secondPlans.isEmpty)
    }

    @MainActor
    func testRevisionConflictIsDurablyQuarantinedWithoutBlockingAnotherPlan() async throws {
        let conflictedRemote = makePlan(id: "conflicted", revision: 2)
        let independentRemote = makePlan(id: "independent", revision: 1)
        let remote = ConflictAndIndependentRemoteStub(
            conflicted: conflictedRemote,
            independent: independentRemote
        )
        let persistence = InMemorySharedPlanPersistence()
        var conflictedLocal = makePlan(id: conflictedRemote.id, revision: 1)
        conflictedLocal.name = "端末に残す名前"
        var independentLocal = independentRemote
        independentLocal.name = "別プランの変更"
        let first = SharedPlanRESTWrite(
            id: UUID(),
            planID: conflictedLocal.id,
            kind: .rename,
            baseRevision: 1,
            name: conflictedLocal.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = SharedPlanRESTWrite(
            id: UUID(),
            planID: independentLocal.id,
            kind: .rename,
            baseRevision: 1,
            name: independentLocal.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await persistence.savePlan(conflictedLocal, write: first)
        try await persistence.savePlan(independentLocal, write: second)

        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store?.load()
        XCTAssertTrue(store?.pendingRESTWrites.isEmpty == true)
        XCTAssertEqual(store?.quarantinedRESTWrites.map(\.id), [first.id])
        let independentRenameCount = await remote.independentRenameCount
        XCTAssertEqual(independentRenameCount, 1)
        XCTAssertEqual(
            store?.plans.first(where: { $0.id == conflictedLocal.id })?.name,
            conflictedRemote.name,
            "The authoritative resource is visible while the rejected intent stays quarantined"
        )
        XCTAssertEqual(store?.quarantinedRESTWrites.first?.name, conflictedLocal.name)

        store = nil
        let beforeRelaunch = await remote.conflictedRenameCount
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.quarantinedRESTWrites.map(\.id), [first.id])
        let afterRelaunch = await remote.conflictedRenameCount
        XCTAssertEqual(afterRelaunch, beforeRelaunch)
        await relaunched.refresh()
        XCTAssertEqual(
            relaunched.plans.first(where: { $0.id == conflictedLocal.id })?.name,
            conflictedRemote.name
        )
        try await relaunched.discardQuarantinedMetadataChanges(planID: conflictedLocal.id)
        XCTAssertTrue(relaunched.quarantinedRESTWrites.isEmpty)
        XCTAssertEqual(
            relaunched.plans.first(where: { $0.id == conflictedLocal.id })?.name,
            conflictedRemote.name
        )
    }

    @MainActor
    func testRevisionConflictRetryFetchesAuthorityAndUsesANewRequest() async throws {
        let conflictedRemote = makePlan(id: "retry-conflicted", revision: 4)
        let independent = makePlan(id: "retry-independent")
        let remote = ConflictAndIndependentRemoteStub(
            conflicted: conflictedRemote,
            independent: independent
        )
        let persistence = InMemorySharedPlanPersistence()
        var local = makePlan(id: conflictedRemote.id, revision: 3)
        local.name = "再試行する名前"
        let original = SharedPlanRESTWrite(
            id: UUID(),
            planID: local.id,
            kind: .rename,
            baseRevision: 3,
            name: local.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date()
        )
        try await persistence.savePlan(local, write: original)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()
        XCTAssertEqual(store.quarantinedRESTWrites.map(\.id), [original.id])
        XCTAssertEqual(store.plans.first?.revision, 4)

        try await store.retryQuarantinedMetadataChanges(planID: local.id)
        await store.drainRESTOutbox()
        XCTAssertTrue(store.quarantinedRESTWrites.isEmpty)
        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first(where: { $0.id == local.id })?.name, local.name)
        XCTAssertEqual(store.plans.first(where: { $0.id == local.id })?.revision, 5)
        let requestIDs = await remote.conflictedRequestIDs
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertNotEqual(requestIDs[0], requestIDs[1])
    }

    @MainActor
    func testBulkQuarantineDiscardRefetchesAfterNewerRefreshWins() async throws {
        let planID = UUID().uuidString.lowercased()
        let stale = makePlan(id: planID, revision: 4)
        var newer = stale
        newer.name = "新しいサーバー名"
        newer.revision = 5
        newer.updatedAt = Date(timeIntervalSince1970: 5)
        let quarantined = makeQuarantinedRename(
            planID: planID,
            baseRevision: 3,
            name: "破棄する端末名"
        )
        let persistence = FaultInjectingSharedPlanPersistence()
        try await persistence.saveQuarantinedRESTWrites(
            [quarantined],
            currentPlan: stale
        )
        let remote = AuthorityInterleavingRemoteStub(plan: stale)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()

        await remote.suspendNextFetch(returning: [stale])
        let discard = Task { @MainActor in
            try await store.discardQuarantinedMetadataChanges(planID: planID)
        }
        guard await eventually({ await remote.isFetchSuspended }) else {
            await remote.releaseSuspendedFetch()
            discard.cancel()
            _ = try? await discard.value
            return XCTFail("Bulk discard did not reach its forced authoritative fetch")
        }
        await remote.setPlan(newer)
        let refresh = Task { @MainActor in await store.refresh() }
        guard await eventually({ await remote.fetchCount >= 2 }) else {
            await remote.releaseSuspendedFetch()
            discard.cancel()
            refresh.cancel()
            _ = try? await discard.value
            await refresh.value
            return XCTFail("Concurrent refresh did not fetch newer authority")
        }
        await refresh.value
        XCTAssertEqual(store.plans.first?.revision, 5)

        await remote.releaseSuspendedFetch()
        try await discard.value

        XCTAssertTrue(store.quarantinedRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.revision, 5)
        let durablePlan = try await persistence.loadedPlan(id: planID)
        XCTAssertEqual(durablePlan?.revision, 5)
        let fetchCount = await remote.fetchCount
        XCTAssertEqual(fetchCount, 3)
    }

    @MainActor
    func testQuarantineRetryUsesCurrentRevisionAfterNewerRefreshWins() async throws {
        let planID = UUID().uuidString.lowercased()
        let stale = makePlan(id: planID, revision: 4)
        var newer = stale
        newer.name = "新しいサーバー名"
        newer.revision = 5
        newer.updatedAt = Date(timeIntervalSince1970: 5)
        let quarantined = makeQuarantinedRename(
            planID: planID,
            baseRevision: 3,
            name: "再試行する端末名"
        )
        let persistence = FaultInjectingSharedPlanPersistence()
        try await persistence.saveQuarantinedRESTWrites(
            [quarantined],
            currentPlan: stale
        )
        let remote = AuthorityInterleavingRemoteStub(plan: stale)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()

        await remote.suspendNextFetch(returning: [stale])
        let retry = Task { @MainActor in
            try await store.retryQuarantinedMetadataChanges(
                planID: planID,
                now: Date(timeIntervalSince1970: 10)
            )
        }
        guard await eventually({ await remote.isFetchSuspended }) else {
            await remote.releaseSuspendedFetch()
            retry.cancel()
            _ = try? await retry.value
            return XCTFail("Retry did not reach its forced authoritative fetch")
        }
        await remote.setPlan(newer)
        let refresh = Task { @MainActor in await store.refresh() }
        guard await eventually({ await remote.fetchCount >= 2 }) else {
            await remote.releaseSuspendedFetch()
            retry.cancel()
            refresh.cancel()
            _ = try? await retry.value
            await refresh.value
            return XCTFail("Concurrent refresh did not fetch newer authority")
        }
        await refresh.value
        XCTAssertEqual(store.plans.first?.revision, 5)

        await remote.releaseSuspendedFetch()
        try await retry.value

        let pending = try XCTUnwrap(store.pendingRESTWrites.first)
        XCTAssertEqual(pending.baseRevision, 5)
        XCTAssertEqual(store.plans.first?.revision, 5)
        let durablePlan = try await persistence.loadedPlan(id: planID)
        let durableWrites = try await persistence.loadRESTWrites()
        XCTAssertEqual(durablePlan?.revision, 5)
        XCTAssertEqual(durableWrites.first?.baseRevision, 5)
        let fetchCount = await remote.fetchCount
        XCTAssertEqual(fetchCount, 3)
    }

    @MainActor
    func testSingleMetadataDiscardRefetchesAfterNewerRefreshWins() async throws {
        let planID = UUID().uuidString.lowercased()
        let stale = makePlan(id: planID, revision: 4)
        var newer = stale
        newer.name = "新しいサーバー名"
        newer.revision = 5
        newer.updatedAt = Date(timeIntervalSince1970: 5)
        let quarantined = makeQuarantinedRename(
            planID: planID,
            baseRevision: 3,
            name: "個別破棄する端末名"
        )
        let persistence = FaultInjectingSharedPlanPersistence()
        try await persistence.saveQuarantinedRESTWrites(
            [quarantined],
            currentPlan: stale
        )
        let remote = AuthorityInterleavingRemoteStub(plan: stale)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()

        await remote.suspendNextFetch(returning: [stale])
        let discard = Task { @MainActor in
            try await store.discardQuarantinedWrite(id: quarantined.id)
        }
        guard await eventually({ await remote.isFetchSuspended }) else {
            await remote.releaseSuspendedFetch()
            discard.cancel()
            _ = try? await discard.value
            return XCTFail("Single discard did not reach its forced authoritative fetch")
        }
        await remote.setPlan(newer)
        let refresh = Task { @MainActor in await store.refresh() }
        guard await eventually({ await remote.fetchCount >= 2 }) else {
            await remote.releaseSuspendedFetch()
            discard.cancel()
            refresh.cancel()
            _ = try? await discard.value
            await refresh.value
            return XCTFail("Concurrent refresh did not fetch newer authority")
        }
        await refresh.value
        XCTAssertEqual(store.plans.first?.revision, 5)

        await remote.releaseSuspendedFetch()
        try await discard.value

        XCTAssertTrue(store.quarantinedRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.revision, 5)
        let durablePlan = try await persistence.loadedPlan(id: planID)
        XCTAssertEqual(durablePlan?.revision, 5)
        let fetchCount = await remote.fetchCount
        XCTAssertEqual(fetchCount, 3)
    }

    @MainActor
    func testMembershipRemovalQuarantineSurvivesRelaunchWithoutResending() async throws {
        let retained = makePlan(id: "retained")
        let removed = makePlan(id: "removed")
        let remote = MembershipRemovalRemoteStub(retainedPlan: retained)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: removed.id,
            comiketNo: removed.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        let snapshot = await document.snapshot(pendingOperationIDs: [UUID()])
        try await persistence.saveBootstrappedPlan(
            removed,
            document: snapshot,
            removingWriteID: nil
        )
        try await persistence.savePlan(retained, write: nil)
        var renamedRemoved = removed
        renamedRemoved.name = "未同期の名前"
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: removed.id,
            kind: .rename,
            baseRevision: removed.revision,
            name: renamedRemoved.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date()
        )
        try await persistence.savePlan(renamedRemoved, write: write)

        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store?.load()
        let initialRemovedRenameCount = await remote.removedRenameCount
        XCTAssertEqual(initialRemovedRenameCount, 1)
        await store?.refresh()
        XCTAssertEqual(store?.plans.map(\.id), [retained.id])
        XCTAssertTrue(store?.pendingRESTWrites.isEmpty == true)
        XCTAssertEqual(store?.quarantinedRESTWrites.first?.quarantineReason, .membershipRevoked)
        let retainedDocument = try await persistence.loadDocument(planID: removed.id)
        XCTAssertNotNil(retainedDocument)

        store = nil
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.plans.map(\.id), [retained.id])
        XCTAssertTrue(relaunched.pendingRESTWrites.isEmpty)
        XCTAssertEqual(relaunched.quarantinedRESTWrites.map(\.id), [write.id])
        let relaunchedRemovedRenameCount = await remote.removedRenameCount
        XCTAssertEqual(relaunchedRemovedRenameCount, 1)
    }

    @MainActor
    func testDelayedMetadataAcknowledgementCannotResurrectRevokedPlan() async throws {
        let plan = makePlan(id: "delayed-ack-revocation")
        let remote = DelayedMembershipRevocationRemoteStub(plan: plan)
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()

        try await store.renamePlan(id: plan.id, name: "送信済みの名前")
        await remote.waitUntilRenameIsPending()

        let refresh = Task { @MainActor in
            await store.refresh()
        }
        for _ in 0..<100 where !store.isRefreshing {
            await Task.yield()
        }
        XCTAssertTrue(store.isRefreshing)

        await remote.revokeMembershipAndCompleteRename()
        await refresh.value

        XCTAssertFalse(store.plans.contains { $0.id == plan.id })
        let persistedPlans = try await persistence.loadPlans()
        XCTAssertFalse(persistedPlans.contains { $0.id == plan.id })

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertFalse(relaunched.plans.contains { $0.id == plan.id })
    }

    @MainActor
    func testReachabilityTransitionDrainsTransientOfflineWriteWithoutRelaunch() async throws {
        let remotePlan = makePlan(id: "reachability-plan")
        let remote = RevisionCheckingRemoteStub(plan: remotePlan, writesEnabled: false)
        let persistence = InMemorySharedPlanPersistence()
        var optimistic = remotePlan
        optimistic.name = "再接続後の名前"
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: remotePlan.id,
            kind: .rename,
            baseRevision: remotePlan.revision,
            name: optimistic.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date()
        )
        try await persistence.savePlan(optimistic, write: write)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()
        XCTAssertEqual(store.pendingRESTWrites.map(\.id), [write.id])

        await remote.setWritesEnabled(true)
        await store.networkBecameReachable()

        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.name, optimistic.name)
        let receivedBaseRevisions = await remote.receivedBaseRevisions
        XCTAssertEqual(receivedBaseRevisions, [1])
    }

    @MainActor
    func testUnavailableDurableStorageFailsClosedBeforeAnyRemoteSend() async throws {
        let (remote, _) = try await makeRemote()
        let store = SharedPlanStore(
            persistence: UnavailableSharedPlanPersistence(),
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()
        do {
            _ = try await store.createPlan(name: "保存不可", comiketNo: 108)
            XCTFail("Unavailable SQLite must never report an in-memory success")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .persistenceFailed)
        }
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        let createCalls = await remote.createCallCount
        XCTAssertEqual(createCalls, 0)
    }

    func testPlanAndProfileNamesEnforceDistinctScalarBoundsBeforeEnqueue() throws {
        XCTAssertNoThrow(try SharedPlanValidation.normalizedPlanName(String(repeating: "界", count: 100)))
        XCTAssertThrowsError(
            try SharedPlanValidation.normalizedPlanName(String(repeating: "界", count: 101))
        )
        XCTAssertNoThrow(
            try SharedPlanValidation.normalizedProfileDisplayName(String(repeating: "名", count: 80))
        )
        XCTAssertThrowsError(
            try SharedPlanValidation.normalizedProfileDisplayName(String(repeating: "名", count: 81))
        )
        XCTAssertThrowsError(
            try SharedPlanValidation.normalizedPlanName(String(repeating: "e\u{301}", count: 51)),
            "Combining sequences count by Unicode scalar, matching the backend"
        )
    }

    func testRejectedSyncStateIsDiscardedAndFreshSessionStillConverges() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bytes = await seed.save()
        let left = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        let right = try SharedPlanAutomergeDocument(data: bytes, replicaID: UUID())
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 404))
        _ = try await left.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "left",
            authoredAt: Date()
        )

        let rejectedSession = UUID()
        await right.beginSyncSession(id: rejectedSession)
        do {
            try await right.receiveSyncMessage(
                sessionID: rejectedSession,
                message: Data([0xff, 0x00, 0xaa])
            )
            XCTFail("Malformed sync bytes must be rejected")
        } catch {}
        do {
            _ = try await right.generateSyncMessage(sessionID: rejectedSession)
            XCTFail("Rejected session state must not be reused")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }

        try await synchronize(left, right)
        let rightKeys = try await right.circleKeys()
        XCTAssertEqual(rightKeys, [key])
    }

    func testQuantityBoundAccepts999AndRejects1000() async throws {
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: UUID().uuidString.lowercased(),
            comiketNo: 108,
            replicaID: UUID()
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 505))
        _ = try await document.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        let valid = SharedPlanPurchaseNeed(
            id: UUID(),
            requesterUserID: "member",
            wantedQuantity: 999
        )
        let created = try await document.createNeed(
            valid,
            for: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        XCTAssertTrue(created)
        let allocated = try await document.setBuyerAllocation(
            999,
            buyerUserID: "buyer",
            needID: valid.id,
            circle: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        XCTAssertTrue(allocated)
        let fulfilled = try await document.setFulfilledQuantity(
            999,
            needID: valid.id,
            circle: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date()
        )
        XCTAssertTrue(fulfilled)
        do {
            _ = try await document.setWantedQuantity(
                1_000,
                needID: valid.id,
                circle: key,
                operationID: UUID(),
                actorUserID: "owner",
                authoredAt: Date()
            )
            XCTFail("Quantity 1000 exceeds v1 bounds")
        } catch {
            guard case .documentLimit = error as? SharedPlanError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testRenameThenArchiveRebasesUnsentWriteAfterReceipt() async throws {
        let plan = makePlan(id: UUID().uuidString.lowercased())
        let remote = RevisionCheckingRemoteStub(plan: plan)
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()

        try await store.renamePlan(
            id: plan.id,
            name: "更新後の名前",
            now: Date(timeIntervalSince1970: 2)
        )
        try await store.archivePlan(
            id: plan.id,
            now: Date(timeIntervalSince1970: 3)
        )
        await store.drainRESTOutbox()

        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.name, "更新後の名前")
        XCTAssertEqual(store.plans.first?.lifecycle, .archived)
        XCTAssertEqual(store.plans.first?.revision, 3)
        let baseRevisions = await remote.receivedBaseRevisions
        XCTAssertEqual(baseRevisions, [1, 2])
    }

    @MainActor
    func testArchivePersistenceBlocksRenameAcknowledgementUntilWriteIsPublished() async throws {
        let plan = makePlan(id: UUID().uuidString.lowercased())
        let remote = RevisionCheckingRemoteStub(plan: plan)
        let persistence = FaultInjectingSharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        await persistence.suspendNextSavePlanAfterPersistence(kind: .archive)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()
        try await store.renamePlan(
            id: plan.id,
            name: "更新後の名前",
            now: Date(timeIntervalSince1970: 2)
        )

        let archive = Task { @MainActor in
            try await store.archivePlan(
                id: plan.id,
                now: Date(timeIntervalSince1970: 3)
            )
        }
        guard await eventually({ await persistence.isSavePlanSuspended }) else {
            await persistence.releaseSuspendedSavePlan()
            archive.cancel()
            _ = try? await archive.value
            return XCTFail("Archive persistence did not reach the forced suspension")
        }
        let durablePlanWhileUnpublished = try await persistence.loadedPlan(id: plan.id)
        let durableWritesWhileUnpublished = try await persistence.loadRESTWrites()
        XCTAssertEqual(durablePlanWhileUnpublished?.lifecycle, .archived)
        XCTAssertEqual(
            durableWritesWhileUnpublished.map(\.kind),
            [.rename, .archive]
        )
        XCTAssertEqual(store.plans.first?.lifecycle, .active)
        XCTAssertEqual(store.pendingRESTWrites.map(\.kind), [.rename])
        let drain = Task { @MainActor in await store.drainRESTOutbox() }
        guard await eventually({ store.isDrainingOutbox }) else {
            await persistence.releaseSuspendedSavePlan()
            drain.cancel()
            archive.cancel()
            _ = try? await archive.value
            await drain.value
            return XCTFail("The explicit drain did not enter its authority wait")
        }
        let baseRevisionsWhileArchiveIsDurableOnly = await remote.receivedBaseRevisions
        XCTAssertTrue(baseRevisionsWhileArchiveIsDurableOnly.isEmpty)

        await persistence.releaseSuspendedSavePlan()
        try await archive.value
        await drain.value

        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertTrue(store.quarantinedRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.name, "更新後の名前")
        XCTAssertEqual(store.plans.first?.lifecycle, .archived)
        XCTAssertEqual(store.plans.first?.revision, 3)
        let receivedBaseRevisions = await remote.receivedBaseRevisions
        XCTAssertEqual(receivedBaseRevisions, [1, 2])
    }

    @MainActor
    func testRefreshPreservesOptimisticMetadataAndRelaunchAutomaticallyDrains() async throws {
        let plan = makePlan(id: UUID().uuidString.lowercased())
        let remote = RevisionCheckingRemoteStub(plan: plan, writesEnabled: false)
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store?.load()
        try await store?.renamePlan(
            id: plan.id,
            name: "オフライン名",
            now: Date(timeIntervalSince1970: 2)
        )
        try await store?.archivePlan(
            id: plan.id,
            now: Date(timeIntervalSince1970: 3)
        )

        await store?.refresh()
        XCTAssertEqual(store?.plans.first?.name, "オフライン名")
        XCTAssertEqual(store?.plans.first?.lifecycle, .archived)
        XCTAssertEqual(store?.pendingRESTWrites.count, 2)

        store = nil
        await remote.setWritesEnabled(true)
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertTrue(relaunched.pendingRESTWrites.isEmpty)
        XCTAssertEqual(relaunched.plans.first?.name, "オフライン名")
        XCTAssertEqual(relaunched.plans.first?.lifecycle, .archived)
        XCTAssertEqual(relaunched.plans.first?.revision, 3)
    }

    @MainActor
    func testFailedPersistenceNeverLeaksAnUndurableSemanticOperation() async throws {
        let (remote, plan) = try await makeRemote()
        let persistence = FaultInjectingSharedPlanPersistence()
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()
        _ = try await store.createPlan(name: plan.name, comiketNo: plan.comiketNo)
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 707))

        await persistence.failNextDocumentMutation()
        do {
            _ = try await store.addCircle(key, to: plan.id)
            XCTFail("A failed durable transaction must reject the mutation")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .persistenceFailed)
        }
        let documentAfterFailure = try await store.documentForSync(planID: plan.id)
        let keysAfterFailure = try await documentAfterFailure.circleKeys()
        let operationsAfterFailure = await documentAfterFailure.semanticOperationIDs()
        XCTAssertTrue(keysAfterFailure.isEmpty)
        XCTAssertTrue(operationsAfterFailure.isEmpty)
        XCTAssertEqual(store.documentSnapshots[plan.id]?.pendingOperationIDs, [])

        _ = try await store.addCircle(key, to: plan.id)
        let operationsAfterRetry = await documentAfterFailure.semanticOperationIDs()
        let keysAfterRetry = try await documentAfterFailure.circleKeys()
        XCTAssertEqual(keysAfterRetry, [key])
        XCTAssertEqual(operationsAfterRetry.count, 1)
        XCTAssertEqual(store.documentSnapshots[plan.id]?.pendingOperationIDs.count, 1)
    }

    func testTerminalInvitationFailuresConsumeOnlyDefinitiveCapabilities() {
        XCTAssertTrue(SharedPlanInvitationFailurePolicy.consumesRouteCapability(
            after: CominaviServiceError.server(
                code: "invitation_not_found",
                message: "not found",
                status: 404
            )
        ))
        XCTAssertTrue(SharedPlanInvitationFailurePolicy.consumesRouteCapability(
            after: SharedPlanError.removedMember
        ))
        XCTAssertFalse(SharedPlanInvitationFailurePolicy.consumesRouteCapability(
            after: URLError(.notConnectedToInternet)
        ))
        XCTAssertFalse(SharedPlanInvitationFailurePolicy.consumesRouteCapability(
            after: CominaviServiceError.notLoggedIn
        ))
    }

    @MainActor
    func testIdentityInvalidationBlocksMetadataBeforeLocalPersistence() async throws {
        let persistence = InMemorySharedPlanPersistence()
        let plan = makePlan(id: "identity-transition")
        try await persistence.savePlan(plan, write: nil)
        let actorUserID = LockedOptionalString("user-a")
        let store = SharedPlanStore(
            persistence: persistence,
            actorUserID: { actorUserID.value }
        )
        await store.load()
        actorUserID.value = nil

        do {
            try await store.renamePlan(id: plan.id, name: "Bへの遷移中")
            XCTFail("A retained store must reject writes once identity is invalidated")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .profileRequired)
        }
        let persistedWrites = try await persistence.loadRESTWrites()
        let persistedPlans = try await persistence.loadPlans()
        XCTAssertTrue(persistedWrites.isEmpty)
        XCTAssertEqual(persistedPlans.first?.name, plan.name)
    }

    @MainActor
    func testMissingInviteCapabilityQuarantinesAndContinuesLaterWrite() async throws {
        let remotePlan = makePlan(id: "after-missing-invite")
        let remote = RevisionCheckingRemoteStub(plan: remotePlan)
        let persistence = InMemorySharedPlanPersistence()
        let missingInvite = SharedPlanRESTWrite(
            id: UUID(),
            planID: "pending-invite:missing",
            kind: .acceptInvitation,
            baseRevision: nil,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        var optimistic = remotePlan
        optimistic.name = "後続の変更"
        let rename = SharedPlanRESTWrite(
            id: UUID(),
            planID: remotePlan.id,
            kind: .rename,
            baseRevision: remotePlan.revision,
            name: optimistic.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await persistence.saveRESTWrite(missingInvite)
        try await persistence.savePlan(optimistic, write: rename)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            inviteCapabilityVault: InMemorySharedPlanInviteCapabilityVault(),
            actorUserID: { "user-1" }
        )

        await store.load()

        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertEqual(store.quarantinedRESTWrites.map(\.id), [missingInvite.id])
        XCTAssertEqual(
            store.quarantinedRESTWrites.first?.quarantineCode,
            "invite_capability_missing"
        )
        XCTAssertEqual(store.plans.first?.name, optimistic.name)
        let receivedBaseRevisions = await remote.receivedBaseRevisions
        XCTAssertEqual(receivedBaseRevisions, [remotePlan.revision])
    }

    @MainActor
    func testCRDTOnlyRevocationCreatesDurableExportableRecovery() async throws {
        let removed = makePlan(id: "crdt-only-revoked")
        let retained = makePlan(id: "still-visible")
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: removed.id,
            comiketNo: removed.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        let snapshot = await document.snapshot(pendingOperationIDs: [UUID()])
        try await persistence.saveBootstrappedPlan(
            removed,
            document: snapshot,
            removingWriteID: nil
        )
        let remote = MembershipRemovalRemoteStub(retainedPlan: retained)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store.load()

        await store.refresh()

        XCTAssertFalse(store.plans.contains { $0.id == removed.id })
        let recovery = try XCTUnwrap(store.recoveryDocuments.first {
            $0.planID == removed.id
        })
        XCTAssertEqual(recovery.pendingOperationCount, 1)
        XCTAssertTrue(recovery.exportText.contains("automergeSave"))
        let recoveredSnapshot = try await persistence.loadDocument(planID: removed.id)
        XCTAssertEqual(recoveredSnapshot?.syncIssue, .membershipRevoked)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertTrue(relaunched.recoveryDocuments.contains { $0.planID == removed.id })
        try await relaunched.discardRecoveryDocument(planID: removed.id)
        let discardedDocument = try await persistence.loadDocument(planID: removed.id)
        XCTAssertNil(discardedDocument)
    }

    @MainActor
    func testReinstatementRotatesOnlyRevokedPlanGenerationAndArchivesOldIntent() async throws {
        let reinstatedPlan = makePlan(id: "reinstated-plan")
        let unaffectedPlan = makePlan(id: "unaffected-plan")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: reinstatedPlan.id,
            comiketNo: reinstatedPlan.comiketNo,
            replicaID: UUID()
        )
        let remote = MembershipReinstatementRemoteStub(
            reinstatedPlan: reinstatedPlan,
            unaffectedPlan: unaffectedPlan,
            bootstrap: SharedPlanSyncBootstrap(
                v: 1,
                document: await serverDocument.save().base64URLEncodedString,
                heads: await serverDocument.heads()
            )
        )
        let persistence = InMemorySharedPlanPersistence()
        let oldReplicaID = UUID()
        let oldOperationID = UUID()
        let oldCircle = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 8101))
        let oldDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: reinstatedPlan.id,
            comiketNo: reinstatedPlan.comiketNo,
            replicaID: oldReplicaID
        )
        try await oldDocument.addCircle(
            oldCircle,
            operationID: oldOperationID,
            actorUserID: "user-1",
            authoredAt: Date(timeIntervalSince1970: 2),
            allowingDurableMutation: true
        )
        try await persistence.saveBootstrappedPlan(
            reinstatedPlan,
            document: await oldDocument.snapshot(pendingOperationIDs: [oldOperationID]),
            removingWriteID: nil
        )
        let predecessorMemoDraft = SharedPlanMemoDraft(
            planID: reinstatedPlan.id,
            replicaID: oldReplicaID,
            circle: oldCircle,
            text: "失効前の未送信メモ",
            generation: 1,
            reason: .staged,
            updatedAt: Date(timeIntervalSince1970: 3),
            recoveryMessage: nil
        )
        try await persistence.saveMemoDraft(predecessorMemoDraft)

        let unaffectedReplicaID = UUID()
        let unaffectedOperationID = UUID()
        let unaffectedDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: unaffectedPlan.id,
            comiketNo: unaffectedPlan.comiketNo,
            replicaID: unaffectedReplicaID
        )
        try await unaffectedDocument.addCircle(
            try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 8102)),
            operationID: unaffectedOperationID,
            actorUserID: "user-1",
            authoredAt: Date(timeIntervalSince1970: 3),
            allowingDurableMutation: true
        )
        try await persistence.saveBootstrappedPlan(
            unaffectedPlan,
            document: await unaffectedDocument.snapshot(
                pendingOperationIDs: [unaffectedOperationID]
            ),
            removingWriteID: nil
        )

        var optimisticPlan = reinstatedPlan
        optimisticPlan.name = "失効前の未同期名"
        let oldRename = SharedPlanRESTWrite(
            id: UUID(),
            planID: reinstatedPlan.id,
            kind: .rename,
            baseRevision: reinstatedPlan.revision,
            name: optimisticPlan.name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        try await persistence.savePlan(optimisticPlan, write: oldRename)

        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store?.load()
        _ = try await store?.documentForSync(planID: reinstatedPlan.id)
        _ = try await store?.documentForSync(planID: unaffectedPlan.id)

        await store?.refresh()
        XCTAssertFalse(store?.plans.contains { $0.id == reinstatedPlan.id } == true)
        XCTAssertEqual(
            store?.quarantinedRESTWrites.first?.quarantineReason,
            .membershipRevoked
        )

        await remote.reinstate()
        await store?.refresh()

        let freshSnapshot = try XCTUnwrap(store?.documentSnapshots[reinstatedPlan.id])
        XCTAssertNotEqual(freshSnapshot.replicaID, oldReplicaID)
        XCTAssertTrue(freshSnapshot.pendingOperationIDs.isEmpty)
        let freshDocument = try await XCTUnwrap(store).documentForSync(planID: reinstatedPlan.id)
        let freshCircleKeys = try await freshDocument.circleKeys()
        XCTAssertFalse(freshCircleKeys.contains(oldCircle))
        let freshEditor = try await store?.editorSnapshot(planID: reinstatedPlan.id)
        XCTAssertEqual(freshEditor?.memoDrafts, [predecessorMemoDraft])
        XCTAssertEqual(freshEditor?.replicaID, freshSnapshot.replicaID)
        XCTAssertFalse(
            freshEditor?.memoDrafts.contains(where: {
                $0.replicaID == freshSnapshot.replicaID
            }) == true
        )
        XCTAssertEqual(
            store?.documentSnapshots[unaffectedPlan.id]?.replicaID,
            unaffectedReplicaID
        )
        XCTAssertEqual(
            store?.documentSnapshots[unaffectedPlan.id]?.pendingOperationIDs,
            [unaffectedOperationID]
        )
        XCTAssertFalse(store?.quarantinedRESTWrites.contains { $0.id == oldRename.id } == true)

        let archived = try XCTUnwrap(store?.archivedRecoveries.values.first)
        XCTAssertEqual(archived.snapshot.replicaID, oldReplicaID)
        XCTAssertEqual(archived.snapshot.pendingOperationIDs, [oldOperationID])
        XCTAssertEqual(archived.metadataIntents.map(\.id), [oldRename.id])
        let recovery = try XCTUnwrap(store?.recoveryDocuments.first {
            $0.id.hasPrefix("archived-") && $0.planID == reinstatedPlan.id
        })
        XCTAssertEqual(recovery.metadataIntentCount, 1)
        XCTAssertTrue(recovery.exportText.contains("失効前の未同期名"))

        try await store?.renamePlan(id: reinstatedPlan.id, name: "再参加後の名前")
        await store?.drainRESTOutbox()
        XCTAssertEqual(
            store?.plans.first(where: { $0.id == reinstatedPlan.id })?.name,
            "再参加後の名前"
        )

        store = nil
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        let relaunchedFresh = try await relaunched.documentForSync(planID: reinstatedPlan.id)
        let relaunchedFreshReplicaID = relaunchedFresh.replicaID
        XCTAssertEqual(relaunchedFreshReplicaID, freshSnapshot.replicaID)
        let relaunchedUnaffected = try await relaunched.documentForSync(planID: unaffectedPlan.id)
        let relaunchedUnaffectedReplicaID = relaunchedUnaffected.replicaID
        XCTAssertEqual(relaunchedUnaffectedReplicaID, unaffectedReplicaID)
        XCTAssertEqual(
            relaunched.documentSnapshots[unaffectedPlan.id]?.pendingOperationIDs,
            [unaffectedOperationID]
        )
        XCTAssertEqual(
            relaunched.archivedRecoveries.values.first?.metadataIntents.map(\.id),
            [oldRename.id]
        )
        XCTAssertEqual(
            relaunched.archivedRecoveries.values.first?.metadataIntents.first?.quarantineReason,
            .membershipRevoked
        )
        let relaunchedEditor = try await relaunched.editorSnapshot(planID: reinstatedPlan.id)
        XCTAssertEqual(relaunchedEditor.memoDrafts, [predecessorMemoDraft])
        XCTAssertFalse(
            relaunchedEditor.memoDrafts.contains(where: {
                $0.replicaID == relaunchedFreshReplicaID
            })
        )
    }

    @MainActor
    func testRecoveryDiscardCompletingFirstCannotDeleteLaterReinstatement() async throws {
        let revokedPlan = makePlan(id: UUID().uuidString.lowercased())
        let unaffectedPlan = makePlan(id: UUID().uuidString.lowercased())
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: revokedPlan.id,
            comiketNo: revokedPlan.comiketNo,
            replicaID: UUID()
        )
        let remote = MembershipReinstatementRemoteStub(
            reinstatedPlan: revokedPlan,
            unaffectedPlan: unaffectedPlan,
            bootstrap: SharedPlanSyncBootstrap(
                v: 1,
                document: await serverDocument.save().base64URLEncodedString,
                heads: await serverDocument.heads()
            )
        )
        let persistence = FaultInjectingSharedPlanPersistence()
        let revokedDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: revokedPlan.id,
            comiketNo: revokedPlan.comiketNo,
            replicaID: UUID()
        )
        try await persistence.saveBootstrappedPlan(
            revokedPlan,
            document: await revokedDocument.snapshot(pendingOperationIDs: [UUID()]),
            removingWriteID: nil
        )
        try await persistence.savePlan(unaffectedPlan, write: nil)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()
        await store.refresh()
        XCTAssertFalse(store.plans.contains { $0.id == revokedPlan.id })
        XCTAssertEqual(
            store.documentSnapshots[revokedPlan.id]?.syncIssue,
            .membershipRevoked
        )

        await remote.reinstate()
        await persistence.suspendNextRemovePlanBeforePersistence(id: revokedPlan.id)
        let discard = Task { @MainActor in
            try await store.discardRecoveryDocument(planID: revokedPlan.id)
        }
        guard await eventually({ await persistence.isRemovePlanSuspended }) else {
            await persistence.releaseSuspendedRemovePlan()
            discard.cancel()
            _ = try? await discard.value
            return XCTFail("Recovery discard did not reach its forced remove")
        }
        let fetchCountBeforeRefresh = await remote.fetchCount
        let refresh = Task { @MainActor in await store.refresh() }
        guard await eventually({ store.authorityOperationWaiterCountForTesting() == 1 }) else {
            await persistence.releaseSuspendedRemovePlan()
            discard.cancel()
            refresh.cancel()
            _ = try? await discard.value
            await refresh.value
            return XCTFail("Reinstatement refresh did not wait behind recovery discard")
        }
        let fetchCountWhileRefreshWaits = await remote.fetchCount
        XCTAssertEqual(fetchCountWhileRefreshWaits, fetchCountBeforeRefresh)

        await persistence.releaseSuspendedRemovePlan()
        try await discard.value
        await refresh.value

        XCTAssertTrue(store.plans.contains { $0.id == revokedPlan.id })
        let durablePlan = try await persistence.loadedPlan(id: revokedPlan.id)
        XCTAssertEqual(durablePlan?.id, revokedPlan.id)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertTrue(relaunched.plans.contains { $0.id == revokedPlan.id })
    }

    @MainActor
    func testReinstatementCompletingFirstRejectsQueuedRecoveryDiscard() async throws {
        let revokedPlan = makePlan(id: UUID().uuidString.lowercased())
        let unaffectedPlan = makePlan(id: UUID().uuidString.lowercased())
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: revokedPlan.id,
            comiketNo: revokedPlan.comiketNo,
            replicaID: UUID()
        )
        let remote = MembershipReinstatementRemoteStub(
            reinstatedPlan: revokedPlan,
            unaffectedPlan: unaffectedPlan,
            bootstrap: SharedPlanSyncBootstrap(
                v: 1,
                document: await serverDocument.save().base64URLEncodedString,
                heads: await serverDocument.heads()
            )
        )
        let persistence = FaultInjectingSharedPlanPersistence()
        let revokedDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: revokedPlan.id,
            comiketNo: revokedPlan.comiketNo,
            replicaID: UUID()
        )
        try await persistence.saveBootstrappedPlan(
            revokedPlan,
            document: await revokedDocument.snapshot(pendingOperationIDs: [UUID()]),
            removingWriteID: nil
        )
        try await persistence.savePlan(unaffectedPlan, write: nil)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await store.load()
        await store.refresh()
        XCTAssertFalse(store.plans.contains { $0.id == revokedPlan.id })

        await remote.reinstate()
        await remote.suspendNextBootstrap()
        let refresh = Task { @MainActor in await store.refresh() }
        guard await eventually({ await remote.isBootstrapSuspended }) else {
            await remote.releaseSuspendedBootstrap()
            refresh.cancel()
            await refresh.value
            return XCTFail("Reinstatement did not reach its forced bootstrap")
        }
        await persistence.suspendNextRemovePlanBeforePersistence(id: revokedPlan.id)
        let discard = Task { @MainActor in
            try await store.discardRecoveryDocument(planID: revokedPlan.id)
        }
        guard await eventually({ store.authorityOperationWaiterCountForTesting() == 1 }) else {
            await remote.releaseSuspendedBootstrap()
            await persistence.releaseSuspendedRemovePlan()
            refresh.cancel()
            discard.cancel()
            await refresh.value
            _ = try? await discard.value
            return XCTFail("Recovery discard did not wait behind reinstatement")
        }
        let removeReachedPersistence = await persistence.isRemovePlanSuspended
        XCTAssertFalse(removeReachedPersistence)

        await remote.releaseSuspendedBootstrap()
        await refresh.value
        await persistence.releaseSuspendedRemovePlan()
        do {
            try await discard.value
            XCTFail("A stale recovery discard must reject the reinstated plan")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .planNotFound)
        }

        XCTAssertTrue(store.plans.contains { $0.id == revokedPlan.id })
        let durablePlan = try await persistence.loadedPlan(id: revokedPlan.id)
        XCTAssertEqual(durablePlan?.id, revokedPlan.id)
        let durableSnapshot = try await persistence.loadDocument(planID: revokedPlan.id)
        XCTAssertNotNil(durableSnapshot)
        XCTAssertNil(durableSnapshot?.syncIssue)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            automaticallySchedulesOutboxDrain: false,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertTrue(relaunched.plans.contains { $0.id == revokedPlan.id })
        XCTAssertNil(relaunched.documentSnapshots[revokedPlan.id]?.syncIssue)
    }

    @MainActor
    func testTransientReinstatementBootstrapFailureDoesNotPoisonOtherPlans() async throws {
        let reinstatedPlan = makePlan(id: "reinstatement-bootstrap-retry")
        let unaffectedPlan = makePlan(id: "reinstatement-unaffected")
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: reinstatedPlan.id,
            comiketNo: reinstatedPlan.comiketNo,
            replicaID: UUID()
        )
        let remote = MembershipReinstatementRemoteStub(
            reinstatedPlan: reinstatedPlan,
            unaffectedPlan: unaffectedPlan,
            bootstrap: SharedPlanSyncBootstrap(
                v: 1,
                document: await serverDocument.save().base64URLEncodedString,
                heads: await serverDocument.heads()
            )
        )
        let persistence = InMemorySharedPlanPersistence()
        let oldReplicaID = UUID()
        let localDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: reinstatedPlan.id,
            comiketNo: reinstatedPlan.comiketNo,
            replicaID: oldReplicaID
        )
        try await persistence.saveBootstrappedPlan(
            reinstatedPlan,
            document: await localDocument.snapshot(pendingOperationIDs: [UUID()]),
            removingWriteID: nil
        )
        try await persistence.savePlan(unaffectedPlan, write: nil)
        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await store?.load()
        _ = try await store?.documentForSync(planID: reinstatedPlan.id)
        await store?.refresh()

        await remote.reinstate(failingBootstrapAttempts: 1)
        await store?.refresh()
        XCTAssertEqual(
            store?.documentSnapshots[reinstatedPlan.id]?.syncIssue,
            .membershipRevoked
        )
        do {
            try await store?.renamePlan(id: reinstatedPlan.id, name: "まだ編集不可")
            XCTFail("The reinstated plan must remain locked until a fresh generation is durable")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .membershipRevoked)
        }
        try await store?.renamePlan(id: unaffectedPlan.id, name: "他プランは編集可能")
        await store?.drainRESTOutbox()
        XCTAssertEqual(
            store?.plans.first(where: { $0.id == unaffectedPlan.id })?.name,
            "他プランは編集可能"
        )

        store = nil
        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertEqual(
            relaunched.documentSnapshots[reinstatedPlan.id]?.syncIssue,
            .membershipRevoked
        )
        await relaunched.refresh()
        let fresh = try XCTUnwrap(relaunched.documentSnapshots[reinstatedPlan.id])
        XCTAssertNotEqual(fresh.replicaID, oldReplicaID)
        XCTAssertNil(fresh.syncIssue)
        XCTAssertEqual(relaunched.archivedRecoveries.values.first?.snapshot.replicaID, oldReplicaID)
    }

    @MainActor
    func testRecoveryPersistenceFailureStillRemovesRevokedPlanInMemory() async throws {
        let removed = makePlan(id: "recovery-write-failure")
        let retained = makePlan(id: "remaining")
        let persistence = FaultInjectingSharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: removed.id,
            comiketNo: removed.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        try await persistence.saveBootstrappedPlan(
            removed,
            document: await document.snapshot(pendingOperationIDs: [UUID()]),
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: MembershipRemovalRemoteStub(retainedPlan: retained),
            actorUserID: { "user-1" }
        )
        await store.load()
        await persistence.failNextReconciliation()

        await store.refresh()

        XCTAssertFalse(store.plans.contains { $0.id == removed.id })
        do {
            try await store.renamePlan(id: removed.id, name: "送信してはいけない")
            XCTFail("A failed recovery transaction must leave mutations disabled")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .persistenceFailed)
        }
    }

    @MainActor
    private func makeBootstrappedStore() async throws -> (SharedPlanStore, SharedPlan) {
        let (remote, plan) = try await makeRemote()
        let store = SharedPlanStore(
            persistence: InMemorySharedPlanPersistence(),
            remote: remote,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()
        _ = try await store.createPlan(name: plan.name, comiketNo: plan.comiketNo)
        return (store, plan)
    }

    @MainActor
    private func makeRemote() async throws -> (SharedPlanRemoteStub, SharedPlan) {
        let plan = makePlan(id: UUID().uuidString.lowercased())
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: plan.id,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        return (
            SharedPlanRemoteStub(
                plan: plan,
                bootstrap: SharedPlanSyncBootstrap(
                    v: 1,
                    document: await document.save().base64URLEncodedString,
                    heads: await document.heads()
                )
            ),
            plan
        )
    }

    private func makePlan(
        id: String,
        ownership: SharedPlanOwnership = .owned,
        role: SharedPlanRole = .owner,
        lifecycle: SharedPlanLifecycle = .active,
        revision: Int = 1
    ) -> SharedPlan {
        SharedPlan(
            id: id,
            name: "買い物プラン",
            comiketNo: 108,
            ownership: ownership,
            role: role,
            lifecycle: lifecycle,
            revision: revision,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeQuarantinedRename(
        planID: String,
        baseRevision: Int,
        name: String
    ) -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: UUID(),
            planID: planID,
            kind: .rename,
            baseRevision: baseRevision,
            name: name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: Date(timeIntervalSince1970: 2)
        ).quarantined(
            for: .revisionConflict,
            currentRevision: baseRevision + 1,
            code: "revision_conflict",
            message: "revision conflict"
        )
    }

    @MainActor
    private func eventually(
        attempts: Int = 2_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func synchronize(
        _ left: SharedPlanAutomergeDocument,
        _ right: SharedPlanAutomergeDocument
    ) async throws {
        let sessionID = UUID()
        await left.beginSyncSession(id: sessionID)
        await right.beginSyncSession(id: sessionID)
        for _ in 0..<32 {
            let leftMessage = try await left.generateSyncMessage(sessionID: sessionID)
            if let leftMessage {
                try await right.receiveSyncMessage(sessionID: sessionID, message: leftMessage)
            }
            let rightMessage = try await right.generateSyncMessage(sessionID: sessionID)
            if let rightMessage {
                try await left.receiveSyncMessage(sessionID: sessionID, message: rightMessage)
            }
            if leftMessage == nil, rightMessage == nil { break }
        }
        await left.endSyncSession(id: sessionID)
        await right.endSyncSession(id: sessionID)
    }

    @MainActor
    func testCreatedInvitationSurvivesCrashBetweenProtectedSaveAndSQLiteAck() async throws {
        let plan = makePlan(id: "11111111-1111-4111-8111-111111111111")
        let persistence = FaultInjectingSharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        await persistence.failNextAcknowledgement()
        let vault = InMemorySharedPlanCreatedInvitationVault()
        let remote = AdministrativeRemoteStub(plan: plan)
        var firstStore: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            createdInvitationVault: vault,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await firstStore?.load()

        let requestID = try await firstStore?.createInvitation(
            planID: plan.id,
            expiresAt: Date(timeIntervalSince1970: 2_000.875),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let unwrappedRequestID = try XCTUnwrap(requestID)
        for _ in 0..<1_000 where firstStore?.restWriteIssues[unwrappedRequestID] == nil {
            await Task.yield()
        }
        let firstMetrics = await remote.metrics()
        let protectedAfterFailure = await vault.loadAll()
        XCTAssertEqual(firstMetrics.createInvitationCallCount, 1)
        XCTAssertEqual(firstMetrics.createInvitationExpiresAt, [
            Date(timeIntervalSince1970: 2_000),
        ])
        XCTAssertEqual(
            protectedAfterFailure[unwrappedRequestID]?.expiresAt,
            Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertTrue(firstStore?.pendingRESTWrites.contains(where: {
            $0.id == unwrappedRequestID
        }) == true)
        firstStore = nil

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            createdInvitationVault: vault,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await relaunched.load()
        let replayMetrics = await remote.metrics()
        XCTAssertEqual(replayMetrics.createInvitationCallCount, 1)
        XCTAssertTrue(relaunched.pendingRESTWrites.isEmpty)
        XCTAssertEqual(relaunched.plans.first?.revision, 2)
        XCTAssertEqual(
            relaunched.createdInvitations[unwrappedRequestID]?.token,
            "AQEBAQEBAQEB"
        )
    }

    @MainActor
    func testLostInvitationTokenQuarantinesIntentAndReconcilesBeforeLaterWrite() async throws {
        let plan = makePlan(id: "11111111-1111-4111-8111-111111111111")
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        let requestID = UUID(uuidString: "44444444-4444-4444-8444-444444444441")!
        let write = SharedPlanRESTWrite(
            id: requestID,
            planID: plan.id,
            kind: .createInvitation,
            baseRevision: 1,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try await persistence.saveRESTWrite(write)
        let remote = AdministrativeRemoteStub(plan: plan)
        await remote.seedCommittedInvitation(requestID: requestID)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )

        await store.load()
        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        let quarantined = try XCTUnwrap(store.quarantinedRESTWrites.first)
        XCTAssertEqual(quarantined.id, requestID)
        XCTAssertEqual(
            quarantined.invitationID,
            "55555555-5555-4555-8555-555555555555"
        )
        XCTAssertEqual(quarantined.quarantineReason, .terminalFailure)
        XCTAssertEqual(store.plans.first?.revision, 2)

        try await store.renamePlan(id: plan.id, name: "次の編集")
        for _ in 0..<1_000 where store.pendingRESTWrites.isEmpty == false {
            await Task.yield()
        }
        let metrics = await remote.metrics()
        XCTAssertEqual(metrics.renameBaseRevisions, [2])
        XCTAssertEqual(store.plans.first?.name, "次の編集")
        XCTAssertEqual(store.plans.first?.revision, 3)
        XCTAssertEqual(store.quarantinedRESTWrites.map(\.id), [requestID])
    }

    @MainActor
    func testRetryQuarantinedAdministrativeWritesPreservesEveryPayloadAndDrainsAll()
        async throws
    {
        let plan = makePlan(
            id: "11111111-1111-4111-8111-111111111111",
            revision: 10
        )
        let targetA = "22222222222222222222222222222222"
        let targetB = "33333333333333333333333333333333"
        let targetC = "44444444444444444444444444444444"
        let invitationID = "55555555-5555-4555-8555-555555555555"
        let expiresAt = Date(timeIntervalSince1970: 5_000)
        let oldWrites = [
            SharedPlanRESTWrite(
                id: UUID(), planID: plan.id, kind: .revokeMember,
                baseRevision: 1, name: nil, comiketNo: nil, inviteToken: nil,
                targetUserID: targetA, createdAt: Date(timeIntervalSince1970: 1),
                quarantineReason: .revisionConflict
            ),
            SharedPlanRESTWrite(
                id: UUID(), planID: plan.id, kind: .reinstateMember,
                baseRevision: 1, name: nil, comiketNo: nil, inviteToken: nil,
                targetUserID: targetB, createdAt: Date(timeIntervalSince1970: 2),
                quarantineReason: .revisionConflict
            ),
            SharedPlanRESTWrite(
                id: UUID(), planID: plan.id, kind: .transferOwnership,
                baseRevision: 1, name: nil, comiketNo: nil, inviteToken: nil,
                targetUserID: targetC, createdAt: Date(timeIntervalSince1970: 3),
                quarantineReason: .revisionConflict
            ),
            SharedPlanRESTWrite(
                id: UUID(), planID: plan.id, kind: .createInvitation,
                baseRevision: 1, name: nil, comiketNo: nil, inviteToken: nil,
                expiresAt: expiresAt, createdAt: Date(timeIntervalSince1970: 4),
                quarantineReason: .revisionConflict
            ),
            SharedPlanRESTWrite(
                id: UUID(), planID: plan.id, kind: .revokeInvitation,
                baseRevision: 1, name: nil, comiketNo: nil, inviteToken: nil,
                invitationID: invitationID,
                createdAt: Date(timeIntervalSince1970: 5),
                quarantineReason: .revisionConflict
            ),
        ]
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveQuarantinedRESTWrites(oldWrites, currentPlan: plan)
        let remote = AdministrativeRetryRemoteStub(plan: plan)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await store.load()

        try await store.retryQuarantinedMetadataChanges(
            planID: plan.id,
            now: Date(timeIntervalSince1970: 100)
        )
        for _ in 0..<5_000 where !store.pendingRESTWrites.isEmpty {
            await Task.yield()
        }
        let calls = await remote.calls
        XCTAssertEqual(calls.map(\.kind), [
            .revokeMember, .reinstateMember, .transferOwnership,
            .createInvitation, .revokeInvitation,
        ])
        XCTAssertEqual(calls.map(\.baseRevision), [10, 11, 12, 13, 14])
        XCTAssertEqual(calls.map(\.targetUserID), [targetA, targetB, targetC, nil, nil])
        XCTAssertEqual(calls.map(\.invitationID), [nil, nil, nil, nil, invitationID])
        XCTAssertEqual(calls.map(\.expiresAt), [nil, nil, nil, expiresAt, nil])
        XCTAssertTrue(Set(calls.map(\.requestID)).isDisjoint(with: Set(oldWrites.map(\.id))))
        XCTAssertTrue(store.pendingRESTWrites.isEmpty)
        XCTAssertTrue(store.quarantinedRESTWrites.isEmpty)
        XCTAssertEqual(store.plans.first?.revision, 15)
    }

    @MainActor
    func testLostMemberMutationResponseRefreshesInverseAuthoritativeStateInBothOrders()
        async throws
    {
        let targetUserID = "22222222222222222222222222222222"
        for initialStatus in [
            SharedPlanMembershipStatus.active,
            SharedPlanMembershipStatus.removed,
        ] {
            let plan = makePlan(
                id: "11111111-1111-4111-8111-111111111111",
                revision: 1
            )
            let persistence = InMemorySharedPlanPersistence()
            try await persistence.savePlan(plan, write: nil)
            let remote = MemberInverseReplayRemoteStub(
                plan: plan,
                targetUserID: targetUserID,
                initialStatus: initialStatus
            )
            let store = SharedPlanStore(
                persistence: persistence,
                remote: remote,
                actorUserID: { "11111111111111111111111111111111" }
            )
            await store.load()
            try await store.refreshMembers(planID: plan.id)

            if initialStatus == .active {
                _ = try await store.revokeMember(
                    planID: plan.id,
                    userID: targetUserID
                )
            } else {
                _ = try await store.reinstateMember(
                    planID: plan.id,
                    userID: targetUserID
                )
            }
            await remote.waitUntilFirstResponseIsLost()
            XCTAssertEqual(store.pendingRESTWrites.count, 1)

            // Another actor commits the inverse before this client replays its
            // exact lost-response request. The immutable receipt describes the
            // first mutation; only the subsequent member page is current.
            await remote.commitInverseMutation()
            await store.networkBecameReachable()

            XCTAssertTrue(store.pendingRESTWrites.isEmpty)
            XCTAssertEqual(store.plans.first?.revision, 3)
            XCTAssertEqual(
                store.membersByPlanID[plan.id]?.first?.membershipStatus,
                initialStatus
            )
            if initialStatus == .active {
                XCTAssertNil(store.membersByPlanID[plan.id]?.first?.removedAt)
            } else {
                XCTAssertNotNil(store.membersByPlanID[plan.id]?.first?.removedAt)
            }
            let metrics = await remote.metrics()
            XCTAssertEqual(metrics.mutationCalls, 2)
            XCTAssertEqual(metrics.memberPageCalls, 2)
        }
    }

    @MainActor
    func testRevisionedMetadataAcknowledgementsRejectJumpedReceiptsAndStaleResources()
        async throws
    {
        let revisionedKinds: [SharedPlanRESTWriteKind] = [
            .rename, .archive, .reopen, .revokeMember, .reinstateMember,
            .transferOwnership, .createInvitation, .revokeInvitation,
        ]
        for kind in revisionedKinds {
            try await assertMalformedAdministrativeAcknowledgementIsRetained(
                kind: kind,
                receiptRevision: 3,
                returnedPlanRevision: 3
            )
        }
        for kind in revisionedKinds where kind != .createInvitation {
            try await assertMalformedAdministrativeAcknowledgementIsRetained(
                kind: kind,
                receiptRevision: 2,
                returnedPlanRevision: 1
            )
        }
    }

    @MainActor
    private func assertMalformedAdministrativeAcknowledgementIsRetained(
        kind: SharedPlanRESTWriteKind,
        receiptRevision: Int,
        returnedPlanRevision: Int
    ) async throws {
        let plan = makePlan(id: "11111111-1111-4111-8111-111111111111")
        let requestID = UUID()
        let expiresAt = Date(timeIntervalSince1970: 5_000)
        let write = SharedPlanRESTWrite(
            id: requestID,
            planID: plan.id,
            kind: kind,
            baseRevision: 1,
            name: kind == .rename ? "不正な応答" : nil,
            comiketNo: nil,
            inviteToken: nil,
            targetUserID: [
                SharedPlanRESTWriteKind.revokeMember,
                .reinstateMember,
                .transferOwnership,
            ]
                .contains(kind) ? "22222222222222222222222222222222" : nil,
            invitationID: kind == .revokeInvitation
                ? "55555555-5555-4555-8555-555555555555" : nil,
            expiresAt: kind == .createInvitation ? expiresAt : nil,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        try await persistence.saveRESTWrite(write)
        let vault = InMemorySharedPlanCreatedInvitationVault()
        let remote = MalformedAdministrativeRemoteStub(
            plan: plan,
            kind: kind,
            receiptRevision: receiptRevision,
            returnedPlanRevision: returnedPlanRevision
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            createdInvitationVault: vault,
            actorUserID: { "11111111111111111111111111111111" }
        )

        await store.load()

        let persistedWriteIDs = try await persistence.loadRESTWrites().map(\.id)
        let callCount = await remote.callCount
        XCTAssertEqual(store.pendingRESTWrites.map(\.id), [requestID], "\(kind)")
        XCTAssertEqual(persistedWriteIDs, [requestID])
        XCTAssertEqual(callCount, 1, "\(kind)")
        XCTAssertNotNil(store.restWriteIssues[requestID], "\(kind)")
        if kind == .createInvitation {
            let protectedInvitations = await vault.loadAll()
            XCTAssertTrue(protectedInvitations.isEmpty)
        }
    }

    @MainActor
    func testNotificationReadPersistsBeforeSendAndAcknowledgesAtomically() async throws {
        let persistence = InMemorySharedPlanPersistence()
        let notification = makeNotification(
            id: String(repeating: "f", count: 64),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await persistence.saveNotifications([notification])
        let readAt = Date(timeIntervalSince1970: 200)
        let remote = NotificationRemoteStub(readAt: readAt)
        await remote.suspendNextRead()
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await store.load()

        try await store.markNotificationRead(
            id: notification.id,
            now: Date(timeIntervalSince1970: 150)
        )
        await remote.waitUntilReadStarted()
        let persistedReadIntents = try await persistence.loadNotificationReadIntents()
        XCTAssertEqual(persistedReadIntents, [notification.id])
        XCTAssertTrue(store.pendingNotificationReadIDs.contains(notification.id))
        XCTAssertNil(store.notifications.first?.readAt)

        await remote.releaseSuspendedRead()
        for _ in 0..<1_000 where store.pendingNotificationReadIDs.contains(notification.id) {
            await Task.yield()
        }
        XCTAssertFalse(store.pendingNotificationReadIDs.contains(notification.id))
        XCTAssertEqual(store.notifications.first?.readAt, readAt)
        let remainingReadIntents = try await persistence.loadNotificationReadIntents()
        let persistedNotifications = try await persistence.loadNotifications()
        XCTAssertTrue(remainingReadIntents.isEmpty)
        XCTAssertEqual(persistedNotifications.first?.readAt, readAt)
    }

    @MainActor
    func testNotificationReadLostResponseReplaysAfterRelaunchWithoutSecondCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-plan-notifications-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try SQLiteSharedPlanPersistence(
            path: directory.appendingPathComponent("shared-plans.sqlite").path
        )
        let notification = makeNotification(
            id: String(repeating: "e", count: 64),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await persistence.saveNotifications([notification])
        try await persistence.saveNotificationReadIntent(
            eventID: notification.id,
            createdAt: Date(timeIntervalSince1970: 150)
        )
        let readAt = Date(timeIntervalSince1970: 200)
        let remote = NotificationRemoteStub(readAt: readAt, lostResponses: 1)

        var firstStore: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await firstStore?.load()
        let firstMetrics = await remote.metrics()
        XCTAssertEqual(firstStore?.pendingNotificationReadIDs, [notification.id])
        XCTAssertEqual(firstMetrics.readCallCount, 1)
        XCTAssertEqual(firstMetrics.commitCount, 1)
        firstStore = nil

        let relaunched = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await relaunched.load()
        let replayMetrics = await remote.metrics()
        XCTAssertTrue(relaunched.pendingNotificationReadIDs.isEmpty)
        XCTAssertEqual(relaunched.notifications.first?.readAt, readAt)
        XCTAssertEqual(replayMetrics.readCallCount, 2)
        XCTAssertEqual(replayMetrics.commitCount, 1)
        XCTAssertEqual(replayMetrics.receivedReadIDs, [notification.id, notification.id])
    }

    @MainActor
    func testStaleNotificationPageCannotEraseDurableReadStateAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-plan-stale-notification-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try SQLiteSharedPlanPersistence(
            path: directory.appendingPathComponent("shared-plans.sqlite").path
        )
        let notification = makeNotification(
            id: String(repeating: "d", count: 64),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await persistence.saveNotifications([notification])
        let readAt = Date(timeIntervalSince1970: 200)
        let remote = NotificationRemoteStub(
            pages: [
                "first": SharedPlanNotificationPage(
                    items: [notification],
                    nextCursor: nil
                ),
            ],
            readAt: readAt
        )
        var store: SharedPlanStore? = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await store?.load()
        try await store?.markNotificationRead(id: notification.id)
        for _ in 0..<1_000 where store?.pendingNotificationReadIDs.isEmpty == false {
            await Task.yield()
        }
        XCTAssertEqual(store?.notifications.first?.readAt, readAt)

        // This GET was captured before the read acknowledgement and still has
        // readAt:null. It must not overwrite the monotonic local receipt.
        try await store?.refreshNotifications(limit: 1)
        XCTAssertEqual(store?.notifications.first?.readAt, readAt)
        store = nil

        let relaunched = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.notifications.first?.readAt, readAt)
    }

    @MainActor
    func testNotificationPaginationRetainsCachedHistoryAcrossOfflineRelaunch() async throws {
        let persistence = InMemorySharedPlanPersistence()
        let cached = makeNotification(
            id: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newest = makeNotification(
            id: String(repeating: "c", count: 64),
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let middle = makeNotification(
            id: String(repeating: "b", count: 64),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await persistence.saveNotifications([cached])
        let remote = NotificationRemoteStub(
            pages: [
                "first": SharedPlanNotificationPage(items: [newest], nextCursor: "next"),
                "next": SharedPlanNotificationPage(items: [middle], nextCursor: nil),
            ]
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await store.load()
        try await store.refreshNotifications(limit: 1)
        try await store.loadMoreNotifications(limit: 1)
        let persistedNotifications = try await persistence.loadNotifications()
        XCTAssertEqual(store.notifications.map(\.id), [newest.id, middle.id, cached.id])
        XCTAssertEqual(persistedNotifications.map(\.id), [
            newest.id, middle.id, cached.id,
        ])

        let offline = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "11111111111111111111111111111111" }
        )
        await offline.load()
        XCTAssertEqual(offline.notifications.map(\.id), [newest.id, middle.id, cached.id])
    }

    private func makeNotification(
        id: String,
        createdAt: Date
    ) -> SharedPlanNotificationItem {
        SharedPlanNotificationItem(
            id: id,
            kind: .sharedPlanEvent,
            planID: "11111111-1111-4111-8111-111111111111",
            eventType: SharedPlanOperationType.circleMemoSplice.rawValue,
            i18nKey: "shared_plan.circle.memo.splice",
            payloadVersion: 1,
            payload: .operation(SharedPlanOperationNotificationPayload(
                v: 1,
                planID: "11111111-1111-4111-8111-111111111111",
                operationID: "22222222-2222-4222-8222-222222222222",
                operationType: .circleMemoSplice,
                actorUserID: "11111111111111111111111111111111",
                payload: ["v": .integer(1)],
                heads: [String(repeating: "a", count: 64)],
                membershipEpoch: 7
            )),
            createdAt: createdAt,
            readAt: nil
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

}

private struct BackendAutomergeBootstrapFixture: Decodable {
    let fixtureVersion: Int
    let automergeJS: String
    let automergeSwift: String
    let actorID: String
    let planID: String
    let comiketNo: Int
    let document: String
    let heads: [String]
}

private actor SharedPlanRemoteStub: SharedPlanRemoteServicing {
    let plan: SharedPlan
    let bootstrap: SharedPlanSyncBootstrap
    private(set) var createCallCount = 0
    private var memberPages: [String: SharedPlanMemberPage] = [:]

    init(plan: SharedPlan, bootstrap: SharedPlanSyncBootstrap) {
        self.plan = plan
        self.bootstrap = bootstrap
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }
    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        guard planID == plan.id else { throw SharedPlanError.planNotFound }
        return bootstrap
    }
    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        createCallCount += 1
        guard name == plan.name, comiketNo == plan.comiketNo else {
            throw SharedPlanError.persistenceFailed
        }
        return result(
            plan,
            requestID: requestID,
            status: .active,
            syncBootstrap: bootstrap
        )
    }
    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        var renamed = plan
        renamed.name = name
        renamed.revision = baseRevision + 1
        return result(renamed, requestID: requestID, status: renamed.lifecycle)
    }
    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        var archived = plan
        archived.lifecycle = .archived
        archived.revision = baseRevision + 1
        return result(archived, requestID: requestID, status: .archived)
    }
    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        var reopened = plan
        reopened.lifecycle = .active
        reopened.revision = baseRevision + 1
        return result(reopened, requestID: requestID, status: .active)
    }
    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }
    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        result(plan, requestID: requestID, status: .active)
    }

    func setMemberPages(_ pages: [String: SharedPlanMemberPage]) {
        memberPages = pages
    }

    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage {
        guard planID == plan.id,
              let page = memberPages[cursor ?? "first"]
        else { throw SharedPlanError.planNotFound }
        return page
    }

    private func result(
        _ plan: SharedPlan,
        requestID: UUID,
        status: SharedPlanLifecycle,
        syncBootstrap: SharedPlanSyncBootstrap? = nil
    ) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: status
            ),
            syncBootstrap: syncBootstrap
        )
    }
}

private actor AuthorityInterleavingRemoteStub: SharedPlanRemoteServicing {
    private var plan: SharedPlan
    private var nextSuspendedResponse: [SharedPlan]?
    private var suspendedResponse: [SharedPlan]?
    private var suspendedFetch: CheckedContinuation<[SharedPlan], Never>?
    private(set) var fetchCount = 0

    var isFetchSuspended: Bool { suspendedFetch != nil }

    init(plan: SharedPlan) {
        self.plan = plan
    }

    func setPlan(_ plan: SharedPlan) {
        self.plan = plan
    }

    func suspendNextFetch(returning response: [SharedPlan]) {
        nextSuspendedResponse = response
    }

    func releaseSuspendedFetch() {
        nextSuspendedResponse = nil
        guard let suspendedFetch else {
            suspendedResponse = nil
            return
        }
        self.suspendedFetch = nil
        let response = suspendedResponse ?? [plan]
        suspendedResponse = nil
        suspendedFetch.resume(returning: response)
    }

    func fetchPlans() async throws -> [SharedPlan] {
        fetchCount += 1
        guard let response = nextSuspendedResponse else { return [plan] }
        nextSuspendedResponse = nil
        suspendedResponse = response
        return await withCheckedContinuation { continuation in
            suspendedFetch = continuation
        }
    }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }
}

private actor RevisionCheckingRemoteStub: SharedPlanRemoteServicing {
    private var plan: SharedPlan
    private var writesEnabled: Bool
    private(set) var receivedBaseRevisions: [Int] = []

    init(plan: SharedPlan, writesEnabled: Bool = true) {
        self.plan = plan
        self.writesEnabled = writesEnabled
    }

    func setWritesEnabled(_ enabled: Bool) {
        writesEnabled = enabled
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        try requireWrite(id: id, baseRevision: baseRevision)
        receivedBaseRevisions.append(baseRevision)
        plan.name = name
        plan.revision += 1
        return result(requestID: requestID, resultStatus: plan.lifecycle)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try requireWrite(id: id, baseRevision: baseRevision)
        receivedBaseRevisions.append(baseRevision)
        plan.lifecycle = .archived
        plan.revision += 1
        return result(requestID: requestID, resultStatus: .archived)
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try requireWrite(id: id, baseRevision: baseRevision)
        receivedBaseRevisions.append(baseRevision)
        plan.lifecycle = .active
        plan.revision += 1
        return result(requestID: requestID, resultStatus: .active)
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    private func result(
        requestID: UUID,
        resultStatus: SharedPlanLifecycle
    ) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: resultStatus
            )
        )
    }

    private func requireWrite(id: String, baseRevision: Int) throws {
        guard writesEnabled else { throw URLError(.notConnectedToInternet) }
        guard id == plan.id, baseRevision == plan.revision else {
            throw CominaviServiceError.server(
                code: "revision_conflict",
                message: "stale base revision",
                status: 409
            )
        }
    }
}

private actor ConflictAndIndependentRemoteStub: SharedPlanRemoteServicing {
    private var conflicted: SharedPlan
    private var independent: SharedPlan
    private var shouldRejectConflictedWrite = true
    private(set) var conflictedRenameCount = 0
    private(set) var independentRenameCount = 0
    private(set) var conflictedRequestIDs: [UUID] = []

    init(conflicted: SharedPlan, independent: SharedPlan) {
        self.conflicted = conflicted
        self.independent = independent
    }

    func fetchPlans() async throws -> [SharedPlan] { [conflicted, independent] }
    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }
    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }
    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        if id == conflicted.id {
            conflictedRenameCount += 1
            conflictedRequestIDs.append(requestID)
            if shouldRejectConflictedWrite {
                shouldRejectConflictedWrite = false
                throw CominaviServiceError.revisionConflict(
                    code: "plan_revision_conflict",
                    message: "stale base revision",
                    currentRevision: conflicted.revision,
                    currentPlan: conflicted
                )
            }
            guard baseRevision == conflicted.revision else {
                throw SharedPlanError.persistenceFailed
            }
            conflicted.name = name
            conflicted.revision += 1
            return result(plan: conflicted, requestID: requestID)
        }
        guard id == independent.id, baseRevision == independent.revision else {
            throw SharedPlanError.persistenceFailed
        }
        independentRenameCount += 1
        independent.name = name
        independent.revision += 1
        return result(plan: independent, requestID: requestID)
    }
    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }
    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }
    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }
    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    private func result(plan: SharedPlan, requestID: UUID) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: plan.lifecycle
            )
        )
    }
}

private actor MembershipRemovalRemoteStub: SharedPlanRemoteServicing {
    private let retainedPlan: SharedPlan
    private(set) var removedRenameCount = 0

    init(retainedPlan: SharedPlan) {
        self.retainedPlan = retainedPlan
    }

    func fetchPlans() async throws -> [SharedPlan] { [retainedPlan] }
    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }
    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }
    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        removedRenameCount += 1
        throw URLError(.notConnectedToInternet)
    }
    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }
    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }
    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }
    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }
}

private actor MembershipReinstatementRemoteStub: SharedPlanRemoteServicing {
    private var reinstatedPlan: SharedPlan
    private var unaffectedPlan: SharedPlan
    private let bootstrap: SharedPlanSyncBootstrap
    private var membershipIsReinstated = false
    private var remainingBootstrapFailures = 0
    private var shouldSuspendNextBootstrap = false
    private var suspendedBootstrapContinuation: CheckedContinuation<Void, Never>?
    private(set) var fetchCount = 0

    var isBootstrapSuspended: Bool { suspendedBootstrapContinuation != nil }

    init(
        reinstatedPlan: SharedPlan,
        unaffectedPlan: SharedPlan,
        bootstrap: SharedPlanSyncBootstrap
    ) {
        self.reinstatedPlan = reinstatedPlan
        self.unaffectedPlan = unaffectedPlan
        self.bootstrap = bootstrap
    }

    func reinstate(failingBootstrapAttempts: Int = 0) {
        membershipIsReinstated = true
        remainingBootstrapFailures = failingBootstrapAttempts
    }

    func suspendNextBootstrap() {
        shouldSuspendNextBootstrap = true
    }

    func releaseSuspendedBootstrap() {
        shouldSuspendNextBootstrap = false
        suspendedBootstrapContinuation?.resume()
        suspendedBootstrapContinuation = nil
    }

    func fetchPlans() async throws -> [SharedPlan] {
        fetchCount += 1
        return membershipIsReinstated
            ? [reinstatedPlan, unaffectedPlan]
            : [unaffectedPlan]
    }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        guard membershipIsReinstated, planID == reinstatedPlan.id else {
            throw SharedPlanError.planNotFound
        }
        if remainingBootstrapFailures > 0 {
            remainingBootstrapFailures -= 1
            throw URLError(.networkConnectionLost)
        }
        if shouldSuspendNextBootstrap {
            shouldSuspendNextBootstrap = false
            await withCheckedContinuation { continuation in
                suspendedBootstrapContinuation = continuation
            }
        }
        return bootstrap
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        if id == reinstatedPlan.id {
            guard membershipIsReinstated else { throw URLError(.notConnectedToInternet) }
            guard baseRevision == reinstatedPlan.revision else {
                throw SharedPlanError.revisionConflict
            }
            reinstatedPlan.name = name
            reinstatedPlan.revision += 1
            reinstatedPlan.updatedAt = Date()
            return result(plan: reinstatedPlan, requestID: requestID)
        }
        guard id == unaffectedPlan.id, baseRevision == unaffectedPlan.revision else {
            throw SharedPlanError.revisionConflict
        }
        unaffectedPlan.name = name
        unaffectedPlan.revision += 1
        unaffectedPlan.updatedAt = Date()
        return result(plan: unaffectedPlan, requestID: requestID)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    private func result(
        plan: SharedPlan,
        requestID: UUID
    ) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: plan.lifecycle
            )
        )
    }
}

private actor DelayedMembershipRevocationRemoteStub: SharedPlanRemoteServicing {
    private let plan: SharedPlan
    private var membershipIsActive = true
    private var pendingRename: CheckedContinuation<SharedPlanMutationResult, Never>?
    private var renameWaiters: [CheckedContinuation<Void, Never>] = []

    init(plan: SharedPlan) {
        self.plan = plan
    }

    func waitUntilRenameIsPending() async {
        guard pendingRename == nil else { return }
        await withCheckedContinuation { continuation in
            renameWaiters.append(continuation)
        }
    }

    func revokeMembershipAndCompleteRename() {
        membershipIsActive = false
        guard let continuation = pendingRename else { return }
        pendingRename = nil
        var renamed = plan
        renamed.name = "送信済みの名前"
        renamed.revision += 1
        continuation.resume(returning: result(plan: renamed, requestID: pendingRequestID))
    }

    private var pendingRequestID = UUID()

    func fetchPlans() async throws -> [SharedPlan] {
        membershipIsActive ? [plan] : []
    }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        guard id == plan.id, baseRevision == plan.revision else {
            throw SharedPlanError.persistenceFailed
        }
        pendingRequestID = requestID
        return await withCheckedContinuation { continuation in
            pendingRename = continuation
            let waiters = renameWaiters
            renameWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    private func result(plan: SharedPlan, requestID: UUID) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: plan.lifecycle
            )
        )
    }
}

private struct AdministrativeRemoteMetrics: Sendable {
    let createInvitationCallCount: Int
    let createInvitationExpiresAt: [Date]
    let renameBaseRevisions: [Int]
}

private actor AdministrativeRemoteStub: SharedPlanRemoteServicing {
    private var plan: SharedPlan
    private var committedInvitationRequests: Set<UUID> = []
    private var createInvitationCallCount = 0
    private var createInvitationExpiresAt: [Date] = []
    private var renameBaseRevisions: [Int] = []

    init(plan: SharedPlan) {
        self.plan = plan
    }

    func seedCommittedInvitation(requestID: UUID) {
        committedInvitationRequests.insert(requestID)
        plan.revision += 1
    }

    func metrics() -> AdministrativeRemoteMetrics {
        AdministrativeRemoteMetrics(
            createInvitationCallCount: createInvitationCallCount,
            createInvitationExpiresAt: createInvitationExpiresAt,
            renameBaseRevisions: renameBaseRevisions
        )
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        guard id == plan.id, baseRevision == plan.revision else {
            throw CominaviServiceError.revisionConflict(
                code: "revision_conflict",
                message: "stale revision",
                currentRevision: plan.revision,
                currentPlan: plan
            )
        }
        renameBaseRevisions.append(baseRevision)
        plan.name = name
        plan.revision += 1
        return mutationResult(requestID: requestID)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation {
        createInvitationCallCount += 1
        createInvitationExpiresAt.append(expiresAt)
        guard planID == plan.id else { throw SharedPlanError.planNotFound }
        if committedInvitationRequests.contains(requestID) {
            throw CominaviServiceError.invitationTokenAlreadyReturned(
                message: "The invitation token was already returned.",
                invitationID: "55555555-5555-4555-8555-555555555555"
            )
        }
        guard baseRevision == plan.revision else {
            throw CominaviServiceError.revisionConflict(
                code: "revision_conflict",
                message: "stale revision",
                currentRevision: plan.revision,
                currentPlan: plan
            )
        }
        committedInvitationRequests.insert(requestID)
        plan.revision += 1
        return SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: "55555555-5555-4555-8555-555555555555",
            token: "AQEBAQEBAQEB",
            expiresAt: expiresAt,
            canonicalURL: URL(string: "https://cominavi.net/join/AQEBAQEBAQEB")!,
            fallbackURL: URL(string: "cominavi://join/AQEBAQEBAQEB")!,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: .active
            )
        )
    }

    private func mutationResult(requestID: UUID) -> SharedPlanMutationResult {
        SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: plan.lifecycle
            )
        )
    }
}

private struct AdministrativeRetryCall: Equatable, Sendable {
    let kind: SharedPlanRESTWriteKind
    let requestID: UUID
    let baseRevision: Int
    let targetUserID: String?
    let invitationID: String?
    let expiresAt: Date?
}

private actor AdministrativeRetryRemoteStub: SharedPlanRemoteServicing {
    private var plan: SharedPlan
    private(set) var calls: [AdministrativeRetryCall] = []

    init(plan: SharedPlan) {
        self.plan = plan
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage {
        SharedPlanMemberPage(items: [], nextCursor: nil)
    }

    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try commit(
            kind: .revokeMember,
            requestID: requestID,
            baseRevision: baseRevision,
            targetUserID: userID
        )
    }

    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try commit(
            kind: .reinstateMember,
            requestID: requestID,
            baseRevision: baseRevision,
            targetUserID: userID
        )
    }

    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try commit(
            kind: .transferOwnership,
            requestID: requestID,
            baseRevision: baseRevision,
            targetUserID: newOwnerUserID
        )
    }

    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation {
        let result = try commit(
            kind: .createInvitation,
            requestID: requestID,
            baseRevision: baseRevision,
            expiresAt: expiresAt
        )
        return SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: "55555555-5555-4555-8555-555555555555",
            token: "AQEBAQEBAQEB",
            expiresAt: expiresAt,
            canonicalURL: URL(string: "https://cominavi.net/join/AQEBAQEBAQEB")!,
            fallbackURL: URL(string: "cominavi://join/AQEBAQEBAQEB")!,
            receipt: result.receipt
        )
    }

    func revokeInvitation(
        planID: String,
        invitationID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try commit(
            kind: .revokeInvitation,
            requestID: requestID,
            baseRevision: baseRevision,
            invitationID: invitationID
        )
    }

    private func commit(
        kind: SharedPlanRESTWriteKind,
        requestID: UUID,
        baseRevision: Int,
        targetUserID: String? = nil,
        invitationID: String? = nil,
        expiresAt: Date? = nil
    ) throws -> SharedPlanMutationResult {
        guard baseRevision == plan.revision else {
            throw SharedPlanError.persistenceFailed
        }
        calls.append(AdministrativeRetryCall(
            kind: kind,
            requestID: requestID,
            baseRevision: baseRevision,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt
        ))
        plan.revision += 1
        return SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: plan.revision,
                resultStatus: .active
            )
        )
    }
}

private struct MemberInverseReplayMetrics: Sendable {
    let mutationCalls: Int
    let memberPageCalls: Int
}

private actor MemberInverseReplayRemoteStub: SharedPlanRemoteServicing {
    private var plan: SharedPlan
    private let targetUserID: String
    private let initialStatus: SharedPlanMembershipStatus
    private var status: SharedPlanMembershipStatus
    private var committedKind: SharedPlanRESTWriteKind?
    private var committedRequestID: UUID?
    private var committedResultRevision: Int?
    private var firstResponseWasLost = false
    private var firstResponseWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationCalls = 0
    private var memberPageCalls = 0

    init(
        plan: SharedPlan,
        targetUserID: String,
        initialStatus: SharedPlanMembershipStatus
    ) {
        self.plan = plan
        self.targetUserID = targetUserID
        self.initialStatus = initialStatus
        self.status = initialStatus
    }

    func waitUntilFirstResponseIsLost() async {
        guard !firstResponseWasLost else { return }
        await withCheckedContinuation { continuation in
            firstResponseWaiters.append(continuation)
        }
    }

    func commitInverseMutation() {
        status = initialStatus
        plan.revision += 1
    }

    func metrics() -> MemberInverseReplayMetrics {
        MemberInverseReplayMetrics(
            mutationCalls: mutationCalls,
            memberPageCalls: memberPageCalls
        )
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage {
        memberPageCalls += 1
        return SharedPlanMemberPage(
            items: [SharedPlanMember(
                userID: targetUserID,
                displayName: "共同編集者",
                avatarURL: nil,
                role: .editor,
                membershipStatus: status,
                joinedAt: Date(timeIntervalSince1970: 1),
                removedAt: status == .removed
                    ? Date(timeIntervalSince1970: Double(plan.revision))
                    : nil
            )],
            nextCursor: nil
        )
    }

    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try await mutateMember(
            kind: .revokeMember,
            requestID: requestID,
            baseRevision: baseRevision,
            newStatus: .removed
        )
    }

    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try await mutateMember(
            kind: .reinstateMember,
            requestID: requestID,
            baseRevision: baseRevision,
            newStatus: .active
        )
    }

    private func mutateMember(
        kind: SharedPlanRESTWriteKind,
        requestID: UUID,
        baseRevision: Int,
        newStatus: SharedPlanMembershipStatus
    ) async throws -> SharedPlanMutationResult {
        mutationCalls += 1
        if committedRequestID == nil {
            guard baseRevision == plan.revision else {
                throw SharedPlanError.persistenceFailed
            }
            committedKind = kind
            committedRequestID = requestID
            status = newStatus
            plan.revision += 1
            committedResultRevision = plan.revision
            firstResponseWasLost = true
            let waiters = firstResponseWaiters
            firstResponseWaiters.removeAll()
            waiters.forEach { $0.resume() }
            throw URLError(.networkConnectionLost)
        }
        guard committedKind == kind,
              committedRequestID == requestID,
              committedResultRevision != nil
        else { throw SharedPlanError.persistenceFailed }
        return SharedPlanMutationResult(
            plan: plan,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: true,
                resultRevision: committedResultRevision!,
                resultStatus: .active
            )
        )
    }
}

private actor MalformedAdministrativeRemoteStub: SharedPlanRemoteServicing {
    private let sourcePlan: SharedPlan
    private let kind: SharedPlanRESTWriteKind
    private let receiptRevision: Int
    private let returnedPlanRevision: Int
    private(set) var callCount = 0

    init(
        plan: SharedPlan,
        kind: SharedPlanRESTWriteKind,
        receiptRevision: Int,
        returnedPlanRevision: Int
    ) {
        sourcePlan = plan
        self.kind = kind
        self.receiptRevision = receiptRevision
        self.returnedPlanRevision = returnedPlanRevision
    }

    func fetchPlans() async throws -> [SharedPlan] { [sourcePlan] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .rename, requestID: requestID)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .archive, requestID: requestID)
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .reopen, requestID: requestID)
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .revokeMember, requestID: requestID)
    }

    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .reinstateMember, requestID: requestID)
    }

    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .transferOwnership, requestID: requestID)
    }

    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation {
        callCount += 1
        guard kind == .createInvitation else {
            throw SharedPlanError.persistenceFailed
        }
        return SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: "55555555-5555-4555-8555-555555555555",
            token: "AQEBAQEBAQEB",
            expiresAt: expiresAt,
            canonicalURL: URL(string: "https://cominavi.net/join/AQEBAQEBAQEB")!,
            fallbackURL: URL(string: "cominavi://join/AQEBAQEBAQEB")!,
            receipt: receipt(requestID: requestID)
        )
    }

    func revokeInvitation(
        planID: String,
        invitationID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        try malformedResult(expectedKind: .revokeInvitation, requestID: requestID)
    }

    private func malformedResult(
        expectedKind: SharedPlanRESTWriteKind,
        requestID: UUID
    ) throws -> SharedPlanMutationResult {
        callCount += 1
        guard kind == expectedKind else { throw SharedPlanError.persistenceFailed }
        var returned = sourcePlan
        returned.revision = returnedPlanRevision
        returned.lifecycle = expectedKind == .archive ? .archived : .active
        return SharedPlanMutationResult(
            plan: returned,
            receipt: receipt(requestID: requestID)
        )
    }

    private func receipt(requestID: UUID) -> SharedPlanMutationReceipt {
        SharedPlanMutationReceipt(
            requestID: requestID,
            replayed: false,
            resultRevision: receiptRevision,
            resultStatus: kind == .archive ? .archived : .active
        )
    }
}

private struct NotificationRemoteMetrics: Sendable {
    let receivedReadIDs: [String]
    let readCallCount: Int
    let commitCount: Int
}

private actor NotificationRemoteStub: SharedPlanRemoteServicing {
    private let pages: [String: SharedPlanNotificationPage]
    private let readAt: Date
    private var lostResponses: Int
    private var shouldSuspendNextRead = false
    private var suspendedReadContinuation: CheckedContinuation<Void, Never>?
    private var readStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedReadIDs: [String] = []
    private(set) var readCallCount = 0
    private(set) var commitCount = 0
    private var committedReadIDs: Set<String> = []

    init(
        pages: [String: SharedPlanNotificationPage] = [:],
        readAt: Date = Date(timeIntervalSince1970: 200),
        lostResponses: Int = 0
    ) {
        self.pages = pages
        self.readAt = readAt
        self.lostResponses = lostResponses
    }

    func suspendNextRead() {
        shouldSuspendNextRead = true
    }

    func waitUntilReadStarted() async {
        guard readCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            readStartedWaiters.append(continuation)
        }
    }

    func releaseSuspendedRead() {
        suspendedReadContinuation?.resume()
        suspendedReadContinuation = nil
    }

    func metrics() -> NotificationRemoteMetrics {
        NotificationRemoteMetrics(
            receivedReadIDs: receivedReadIDs,
            readCallCount: readCallCount,
            commitCount: commitCount
        )
    }

    func fetchPlans() async throws -> [SharedPlan] { [] }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw SharedPlanError.planNotFound
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.persistenceFailed
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        throw SharedPlanError.invalidInvite
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.invalidInvite
    }

    func fetchNotifications(
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanNotificationPage {
        guard let page = pages[cursor ?? "first"] else {
            throw URLError(.notConnectedToInternet)
        }
        return page
    }

    func markNotificationRead(id: String) async throws -> SharedPlanNotificationReadReceipt {
        readCallCount += 1
        receivedReadIDs.append(id)
        let waiters = readStartedWaiters
        readStartedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if shouldSuspendNextRead {
            shouldSuspendNextRead = false
            await withCheckedContinuation { continuation in
                suspendedReadContinuation = continuation
            }
        }
        if committedReadIDs.insert(id).inserted { commitCount += 1 }
        if lostResponses > 0 {
            lostResponses -= 1
            throw URLError(.networkConnectionLost)
        }
        return SharedPlanNotificationReadReceipt(id: id, readAt: readAt)
    }
}

private actor FaultInjectingSharedPlanPersistence: SharedPlanPersisting {
    private let base = InMemorySharedPlanPersistence()
    private var shouldFailNextMutation = false
    private var shouldFailNextReconciliation = false
    private var shouldFailNextAcknowledgement = false
    private var suspendedSavePlanKind: SharedPlanRESTWriteKind?
    private var suspendedSavePlanContinuation: CheckedContinuation<Void, Never>?
    private var suspendedRemovePlanID: String?
    private var suspendedRemovePlanContinuation: CheckedContinuation<Void, Never>?

    var isSavePlanSuspended: Bool { suspendedSavePlanContinuation != nil }
    var isRemovePlanSuspended: Bool { suspendedRemovePlanContinuation != nil }

    func failNextDocumentMutation() {
        shouldFailNextMutation = true
    }

    func failNextReconciliation() {
        shouldFailNextReconciliation = true
    }

    func failNextAcknowledgement() {
        shouldFailNextAcknowledgement = true
    }

    func suspendNextSavePlanAfterPersistence(kind: SharedPlanRESTWriteKind) {
        suspendedSavePlanKind = kind
    }

    func releaseSuspendedSavePlan() {
        suspendedSavePlanKind = nil
        suspendedSavePlanContinuation?.resume()
        suspendedSavePlanContinuation = nil
    }

    func suspendNextRemovePlanBeforePersistence(id: String) {
        suspendedRemovePlanID = id
    }

    func releaseSuspendedRemovePlan() {
        suspendedRemovePlanID = nil
        suspendedRemovePlanContinuation?.resume()
        suspendedRemovePlanContinuation = nil
    }

    func loadedPlan(id: String) async throws -> SharedPlan? {
        try await base.loadPlans().first { $0.id == id }
    }

    func replicaID() async throws -> UUID { try await base.replicaID() }
    func loadPlans() async throws -> [SharedPlan] { try await base.loadPlans() }
    func loadRESTWrites() async throws -> [SharedPlanRESTWrite] {
        try await base.loadRESTWrites()
    }
    func loadDocument(planID: String) async throws -> SharedPlanDocumentSnapshot? {
        try await base.loadDocument(planID: planID)
    }
    func loadOrphanedDocuments(
        excludingPlanIDs: Set<String>
    ) async throws -> [SharedPlanDocumentSnapshot] {
        try await base.loadOrphanedDocuments(excludingPlanIDs: excludingPlanIDs)
    }
    func loadArchivedRecoveryDocuments() async throws -> [ArchivedSharedPlanRecovery] {
        try await base.loadArchivedRecoveryDocuments()
    }
    func loadNotifications() async throws -> [SharedPlanNotificationItem] {
        try await base.loadNotifications()
    }
    func loadNotificationReadIntents() async throws -> [String] {
        try await base.loadNotificationReadIntents()
    }
    func loadMemoDrafts(planID: String) async throws -> [SharedPlanMemoDraft] {
        try await base.loadMemoDrafts(planID: planID)
    }
    func saveMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        try await base.saveMemoDraft(draft)
    }
    func saveRESTWrite(_ write: SharedPlanRESTWrite) async throws {
        try await base.saveRESTWrite(write)
    }
    func saveNotifications(_ notifications: [SharedPlanNotificationItem]) async throws {
        try await base.saveNotifications(notifications)
    }
    func saveNotificationReadIntent(eventID: String, createdAt: Date) async throws {
        try await base.saveNotificationReadIntent(eventID: eventID, createdAt: createdAt)
    }
    func acknowledgeNotificationRead(
        _ receipt: SharedPlanNotificationReadReceipt
    ) async throws {
        try await base.acknowledgeNotificationRead(receipt)
    }
    func removeNotificationReadIntent(eventID: String) async throws {
        try await base.removeNotificationReadIntent(eventID: eventID)
    }
    func saveBootstrappedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        removingWriteID: UUID?
    ) async throws {
        try await base.saveBootstrappedPlan(
            plan,
            document: document,
            removingWriteID: removingWriteID
        )
    }
    func saveDiscardedContentRebootstrap(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        discardingMemoDraftReplicaID: UUID
    ) async throws {
        try await base.saveDiscardedContentRebootstrap(
            plan,
            document: document,
            discardingMemoDraftReplicaID: discardingMemoDraftReplicaID
        )
    }
    func savePlan(_ plan: SharedPlan, write: SharedPlanRESTWrite?) async throws {
        if let kind = write?.kind, kind == suspendedSavePlanKind {
            suspendedSavePlanKind = nil
            try await base.savePlan(plan, write: write)
            await withCheckedContinuation { continuation in
                suspendedSavePlanContinuation = continuation
            }
            return
        }
        try await base.savePlan(plan, write: write)
    }
    func saveMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot
    ) async throws {
        if shouldFailNextMutation {
            shouldFailNextMutation = false
            throw SharedPlanError.persistenceFailed
        }
        try await base.saveMutation(plan: plan, document: document)
    }
    func saveMemoMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        acknowledging draft: SharedPlanMemoDraft
    ) async throws {
        try await base.saveMemoMutation(
            plan: plan,
            document: document,
            acknowledging: draft
        )
    }
    func saveRecoveryDocument(_ document: SharedPlanDocumentSnapshot) async throws {
        try await base.saveRecoveryDocument(document)
    }
    func replaceReinstatedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        retaining recovery: ArchivedSharedPlanRecovery
    ) async throws {
        try await base.replaceReinstatedPlan(
            plan,
            document: document,
            retaining: recovery
        )
    }
    func reconcileCachedPlans(
        _ plans: [SharedPlan],
        quarantinedWrites: [SharedPlanRESTWrite],
        recoveryDocuments: [SharedPlanDocumentSnapshot]
    ) async throws {
        if shouldFailNextReconciliation {
            shouldFailNextReconciliation = false
            throw SharedPlanError.persistenceFailed
        }
        try await base.reconcileCachedPlans(
            plans,
            quarantinedWrites: quarantinedWrites,
            recoveryDocuments: recoveryDocuments
        )
    }
    func saveQuarantinedRESTWrites(
        _ writes: [SharedPlanRESTWrite],
        currentPlan: SharedPlan?
    ) async throws {
        try await base.saveQuarantinedRESTWrites(writes, currentPlan: currentPlan)
    }
    func replaceQuarantinedRESTWrites(
        removing writeIDs: Set<UUID>,
        with pendingWrites: [SharedPlanRESTWrite],
        plan: SharedPlan
    ) async throws {
        try await base.replaceQuarantinedRESTWrites(
            removing: writeIDs,
            with: pendingWrites,
            plan: plan
        )
    }
    func saveAcknowledgedPlan(
        _ plan: SharedPlan,
        removingWriteID: UUID,
        rebasedWrites: [SharedPlanRESTWrite]
    ) async throws {
        if shouldFailNextAcknowledgement {
            shouldFailNextAcknowledgement = false
            throw SharedPlanError.persistenceFailed
        }
        try await base.saveAcknowledgedPlan(
            plan,
            removingWriteID: removingWriteID,
            rebasedWrites: rebasedWrites
        )
    }
    func removeRESTWrite(id: UUID) async throws {
        try await base.removeRESTWrite(id: id)
    }
    func removePlan(id: String) async throws {
        if id == suspendedRemovePlanID {
            suspendedRemovePlanID = nil
            await withCheckedContinuation { continuation in
                suspendedRemovePlanContinuation = continuation
            }
        }
        try await base.removePlan(id: id)
    }
    func removeArchivedRecoveryDocument(id: UUID) async throws {
        try await base.removeArchivedRecoveryDocument(id: id)
    }
    func removeAll() async throws {
        try await base.removeAll()
    }
}

private final class LockedOptionalString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(_ value: String?) {
        storedValue = value
    }

    var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
