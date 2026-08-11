@testable import ComiNavi
import Automerge
import Foundation
import XCTest

final class SharedPlanSyncTransportTests: XCTestCase {
    func testProductionSocketSendsJSONEnvelopeAsTextFrame() throws {
        let envelope = Data(#"{"v":1,"type":"sync"}"#.utf8)

        switch try URLSessionSharedPlanSyncSocket.outboundMessage(for: envelope) {
        case .string(let value):
            XCTAssertEqual(value, #"{"v":1,"type":"sync"}"#)
        case .data:
            XCTFail("The Worker accepts Shared Plan envelopes as WebSocket text frames")
        @unknown default:
            XCTFail("Unexpected URLSession WebSocket message type")
        }

        XCTAssertThrowsError(
            try URLSessionSharedPlanSyncSocket.outboundMessage(for: Data([0xFF]))
        ) { error in
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }
    }

    func testNegotiationReceiptNeverAcknowledgesSemanticOperations() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bootstrap = await seed.save()
        let client = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let server = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let operationID = UUID()
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_001))
        _ = try await client.addCircle(
            key,
            operationID: operationID,
            actorUserID: "user-client",
            authoredAt: Date(timeIntervalSince1970: 1)
        )

        let sessionID = UUID()
        let session = SharedPlanSyncSession(planID: planID, document: client)
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        await server.beginSyncSession(id: sessionID)

        let generatedNegotiation = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let negotiation = try XCTUnwrap(generatedNegotiation)
        XCTAssertEqual(negotiation.seq, 1)
        let retriedNegotiation = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        XCTAssertEqual(
            retriedNegotiation,
            negotiation,
            "A live-session retry must preserve the exact frame and payload"
        )
        try await server.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: negotiation.payload))
        )
        let generatedServerNegotiation = try await server.generateSyncMessage(
            sessionID: sessionID
        )
        let serverNegotiation = try XCTUnwrap(generatedServerNegotiation)
        _ = try await session.receiveServerFrame(SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 1,
            frameID: UUID(),
            payload: serverNegotiation.base64URLEncodedString
        ))

        let generatedChanges = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let changes = try XCTUnwrap(generatedChanges)
        XCTAssertEqual(changes.seq, 2)
        XCTAssertNotEqual(changes.frameID, negotiation.frameID)

        let recorder = AcknowledgedOperationRecorder()
        let negotiationAcknowledgement = try await session.receiveAcknowledgement(
            SharedPlanSyncAcknowledgement(
                v: 1,
                type: "ack",
                sessionID: sessionID,
                ackSeq: negotiation.seq,
                frameID: negotiation.frameID,
                documentHeads: await server.heads()
            )
        ) { ids in
            await recorder.record(ids)
        }
        XCTAssertTrue(negotiationAcknowledgement.isEmpty)
        let recordedAfterNegotiation = await recorder.values
        XCTAssertEqual(recordedAfterNegotiation, [[]])

        let changeAcknowledgement = try await session.receiveAcknowledgement(
            SharedPlanSyncAcknowledgement(
                v: 1,
                type: "ack",
                sessionID: sessionID,
                ackSeq: changes.seq,
                frameID: changes.frameID,
                documentHeads: await client.heads()
            )
        ) { ids in
            await recorder.record(ids)
        }
        XCTAssertEqual(changeAcknowledgement, [operationID])
        let recordedAfterChanges = await recorder.values
        XCTAssertEqual(recordedAfterChanges, [[], [operationID]])
    }

    func testAcknowledgementWithoutCausalLocalHeadsCannotClearSemanticOperation() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bootstrap = await seed.save()
        let bootstrapHeads = await seed.heads()
        let client = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let server = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let operationID = UUID()
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_002))
        _ = try await client.addCircle(
            key,
            operationID: operationID,
            actorUserID: "user-client",
            authoredAt: Date(timeIntervalSince1970: 2)
        )

        let sessionID = UUID()
        let session = SharedPlanSyncSession(planID: planID, document: client)
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        await server.beginSyncSession(id: sessionID)

        let generatedGreeting = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let greeting = try XCTUnwrap(generatedGreeting)
        try await server.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: greeting.payload))
        )
        let generatedServerGreeting = try await server.generateSyncMessage(
            sessionID: sessionID
        )
        let serverGreeting = try XCTUnwrap(generatedServerGreeting)
        _ = try await session.receiveServerFrame(SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 1,
            frameID: UUID(),
            payload: serverGreeting.base64URLEncodedString
        ))
        let generatedChanges = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let changes = try XCTUnwrap(generatedChanges)
        let recorder = AcknowledgedOperationRecorder()

        do {
            _ = try await session.receiveAcknowledgement(
                SharedPlanSyncAcknowledgement(
                    v: 1,
                    type: "ack",
                    sessionID: sessionID,
                    ackSeq: changes.seq,
                    frameID: changes.frameID,
                    documentHeads: bootstrapHeads
                )
            ) { ids in
                await recorder.record(ids)
            }
            XCTFail("An ack that excludes the local edit cannot clear its durable operation ID")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }

        let recorded = await recorder.values
        let state = await session.state
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(
            state,
            .failed(code: "sync_protocol_violation", retryable: true)
        )
    }

    func testConcurrentServerHeadDefersAcknowledgementUntilFollowingSync() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bootstrap = await seed.save()
        let client = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let server = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let localOperationID = UUID()
        let localKey = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_003))
        _ = try await client.addCircle(
            localKey,
            operationID: localOperationID,
            actorUserID: "user-client",
            authoredAt: Date(timeIntervalSince1970: 3)
        )

        let sessionID = UUID()
        let session = SharedPlanSyncSession(planID: planID, document: client)
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        await server.beginSyncSession(id: sessionID)
        let generatedGreeting = try await session.nextOutboundFrame(
            pendingOperationIDs: [localOperationID]
        )
        let greeting = try XCTUnwrap(generatedGreeting)
        try await server.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: greeting.payload))
        )
        let generatedServerGreeting = try await server.generateSyncMessage(
            sessionID: sessionID
        )
        let serverGreeting = try XCTUnwrap(generatedServerGreeting)
        _ = try await session.receiveServerFrame(SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 1,
            frameID: UUID(),
            payload: serverGreeting.base64URLEncodedString
        ))

        let remoteKey = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_004))
        _ = try await server.addCircle(
            remoteKey,
            operationID: UUID(),
            actorUserID: "user-server",
            authoredAt: Date(timeIntervalSince1970: 4)
        )
        let generatedChanges = try await session.nextOutboundFrame(
            pendingOperationIDs: [localOperationID]
        )
        let changes = try XCTUnwrap(generatedChanges)
        try await server.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: changes.payload))
        )
        let recorder = AcknowledgedOperationRecorder()
        let initiallyAcknowledged = try await session.receiveAcknowledgement(
            SharedPlanSyncAcknowledgement(
                v: 1,
                type: "ack",
                sessionID: sessionID,
                ackSeq: changes.seq,
                frameID: changes.frameID,
                documentHeads: await server.heads()
            )
        ) { ids in
            await recorder.record(ids)
        }
        XCTAssertTrue(initiallyAcknowledged.isEmpty)

        let generatedServerChanges = try await server.generateSyncMessage(
            sessionID: sessionID
        )
        let serverChanges = try XCTUnwrap(generatedServerChanges)
        _ = try await session.receiveServerFrame(SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 2,
            frameID: UUID(),
            payload: serverChanges.base64URLEncodedString
        ))
        let resolved = try await session.resolveDeferredAcknowledgements { ids in
            await recorder.record(ids)
        }
        let recorded = await recorder.values
        XCTAssertEqual(resolved, [localOperationID])
        XCTAssertEqual(recorded, [[], [localOperationID]])
        let clientHeads = await client.heads()
        let serverHeads = await server.heads()
        XCTAssertEqual(clientHeads, serverHeads)
    }

    func testInboundFrameIDCannotBeReusedAtANewSequence() async throws {
        let planID = UUID().uuidString.lowercased()
        let client = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let server = try SharedPlanAutomergeDocument(
            data: await client.save(),
            replicaID: UUID()
        )
        let session = SharedPlanSyncSession(planID: planID, document: client)
        let sessionID = UUID()
        let frame = try await makeInboundChangeFrame(
            clientSession: session,
            serverDocument: server,
            planID: planID,
            sessionID: sessionID
        )
        _ = try await session.receiveServerFrame(frame)

        do {
            _ = try await session.receiveServerFrame(SharedPlanServerSyncFrame(
                v: frame.v,
                type: frame.type,
                planID: frame.planID,
                sessionID: frame.sessionID,
                seq: frame.seq + 1,
                frameID: frame.frameID,
                payload: frame.payload
            ))
            XCTFail("An exact duplicate is valid only at its original sequence")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }
    }

    func testRepeatedStartIsIdempotentAndQuietSocketDoesNotReconnect() async throws {
        let planID = UUID().uuidString.lowercased()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let sessionID = UUID()
        let socket = ScriptedSharedPlanSyncSocket()
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        )))
        let connector = CountingSharedPlanSyncConnector(socket: socket)
        let status = SharedPlanSyncStatusRecorder()
        let syncSession = SharedPlanSyncSession(planID: planID, document: document)
        let coordinator = SharedPlanSyncCoordinator(
            planID: planID,
            authorizer: StaticSharedPlanSyncAuthorizer(),
            connector: connector,
            session: syncSession,
            callbacks: SharedPlanSyncCoordinatorCallbacks(
                pendingOperationCount: { 0 },
                generateOutboundFrame: { session in
                    try await session.nextOutboundFrame()
                },
                receiveServerFrame: { session, frame in
                    try await session.receiveServerFrame(frame)
                },
                receiveAcknowledgement: { session, acknowledgement in
                    try await session.receiveAcknowledgement(acknowledgement)
                },
                receiveError: { _ in nil },
                updateStatus: { value in await status.record(value) }
            ),
            receiveTimeoutNanoseconds: 5_000_000,
            maximumExactFrameRetries: 0
        )

        await coordinator.start()
        await coordinator.start()
        let sent = await socket.waitForSentFrame(count: 1)
        let negotiation = try JSONDecoder().decode(
            SharedPlanClientSyncFrame.self,
            from: sent[0]
        )
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncAcknowledgement(
            v: 1,
            type: "ack",
            sessionID: sessionID,
            ackSeq: negotiation.seq,
            frameID: negotiation.frameID,
            documentHeads: await document.heads()
        )))
        await status.waitForSynchronized()

        try await Task.sleep(nanoseconds: 40_000_000)
        let connectionCount = await connector.connectionCount
        XCTAssertEqual(
            connectionCount,
            1,
            "Repeated starts and an idle healthy socket must keep one connection"
        )
        let closesBeforeStop = await socket.closeCount
        XCTAssertEqual(closesBeforeStop, 0)
        await coordinator.stop()
        let closesAfterStop = await socket.closeCount
        XCTAssertEqual(closesAfterStop, 1)
    }

    func testReceiveDeadlineClosesCancellationIgnoringSocketAndReconnects() async throws {
        let planID = UUID().uuidString.lowercased()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let socket = ScriptedSharedPlanSyncSocket()
        let connector = CountingSharedPlanSyncConnector(socket: socket)
        let session = SharedPlanSyncSession(planID: planID, document: document)
        let coordinator = SharedPlanSyncCoordinator(
            planID: planID,
            authorizer: StaticSharedPlanSyncAuthorizer(),
            connector: connector,
            session: session,
            callbacks: SharedPlanSyncCoordinatorCallbacks(
                pendingOperationCount: { 0 },
                generateOutboundFrame: { session in
                    try await session.nextOutboundFrame()
                },
                receiveServerFrame: { session, frame in
                    try await session.receiveServerFrame(frame)
                },
                receiveAcknowledgement: { session, acknowledgement in
                    try await session.receiveAcknowledgement(acknowledgement)
                },
                receiveError: { _ in nil },
                updateStatus: { _ in }
            ),
            receiveTimeoutNanoseconds: 5_000_000,
            maximumExactFrameRetries: 0,
            reconnectBaseDelayNanoseconds: 1_000_000
        )

        await coordinator.start()
        await connector.waitForConnection(count: 2)
        let connectionCount = await connector.connectionCount
        let closeCount = await socket.closeCount
        XCTAssertEqual(connectionCount, 2)
        XCTAssertGreaterThanOrEqual(closeCount, 1)
        await coordinator.stop()
    }

    func testDisconnectDiscardsRawFrameAndRegeneratesWithFreshSessionState() async throws {
        let planID = UUID().uuidString.lowercased()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let operationID = UUID()
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 8_888))
        _ = try await document.addCircle(
            key,
            operationID: operationID,
            actorUserID: "offline-user",
            authoredAt: Date(timeIntervalSince1970: 2)
        )
        let session = SharedPlanSyncSession(planID: planID, document: document)
        let firstSessionID = UUID()
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: firstSessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        let firstGenerated = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let first = try XCTUnwrap(firstGenerated)
        let awaitingFirst = await session.outboundFrameAwaitingResponse()
        XCTAssertEqual(awaitingFirst, first)

        await session.disconnect()
        let awaitingAfterDisconnect = await session.outboundFrameAwaitingResponse()
        XCTAssertNil(awaitingAfterDisconnect)

        let secondSessionID = UUID()
        try await session.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: secondSessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        let secondGenerated = try await session.nextOutboundFrame(
            pendingOperationIDs: [operationID]
        )
        let second = try XCTUnwrap(secondGenerated)
        XCTAssertEqual(second.seq, 1)
        XCTAssertEqual(second.sessionID, secondSessionID)
        XCTAssertNotEqual(second.sessionID, first.sessionID)
        XCTAssertNotEqual(second.frameID, first.frameID)
    }

    func testInboundPersistenceFailureRollsBackDocumentAndSyncState() async throws {
        let planID = UUID().uuidString.lowercased()
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: UUID()
        )
        let bootstrap = await seed.save()
        let client = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let server = try SharedPlanAutomergeDocument(data: bootstrap, replicaID: UUID())
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 7_777))
        _ = try await server.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "remote-user",
            authoredAt: Date(timeIntervalSince1970: 3)
        )

        let rejectedSessionID = UUID()
        let rejected = SharedPlanSyncSession(planID: planID, document: client)
        let rejectedFrame = try await makeInboundChangeFrame(
            clientSession: rejected,
            serverDocument: server,
            planID: planID,
            sessionID: rejectedSessionID
        )
        do {
            _ = try await rejected.receiveServerFrame(rejectedFrame) { _, _ in
                throw SharedPlanError.persistenceFailed
            }
            XCTFail("An inbound change must not publish before durable persistence")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .persistenceFailed)
        }
        let keysAfterRejectedPersistence = try await client.circleKeys()
        XCTAssertTrue(keysAfterRejectedPersistence.isEmpty)
        let rejectedState = await rejected.state
        XCTAssertEqual(
            rejectedState,
            .failed(code: "sync_protocol_violation", retryable: true)
        )

        let freshSessionID = UUID()
        let fresh = SharedPlanSyncSession(planID: planID, document: client)
        let freshFrame = try await makeInboundChangeFrame(
            clientSession: fresh,
            serverDocument: server,
            planID: planID,
            sessionID: freshSessionID
        )
        _ = try await fresh.receiveServerFrame(freshFrame)
        let convergedKeys = try await client.circleKeys()
        XCTAssertEqual(convergedKeys, [key])
    }

    @MainActor
    func testEnabledHandshakePersistsReplicaBoundOfflineAuthorityAndDisabledHandshakeRevokesIt() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await document.snapshot(pendingOperationIDs: []),
            removingWriteID: nil
        )

        let enabledSocket = ScriptedSharedPlanSyncSocket()
        await enabledSocket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: UUID(),
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        )))
        let enabledStore = SharedPlanStore(
            persistence: persistence,
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: CountingSharedPlanSyncConnector(socket: enabledSocket),
            actorUserID: { "user-1" }
        )
        await enabledStore.load()
        await enabledStore.startSync(planID: planID)
        _ = await enabledSocket.waitForSentFrame(count: 1)
        let enabledSnapshot = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(enabledSnapshot?.offlineMutationAuthority, true)

        await enabledStore.stopSync(planID: planID)
        let firstOfflineCircle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: 108, wcID: 6_660)
        )
        let firstOfflineMutation = try await enabledStore.addCircle(
            firstOfflineCircle,
            to: planID
        )
        XCTAssertTrue(firstOfflineMutation)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        let secondOfflineCircle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: 108, wcID: 6_661)
        )
        let secondOfflineMutation = try await relaunched.addCircle(
            secondOfflineCircle,
            to: planID
        )
        XCTAssertTrue(secondOfflineMutation)
        let relaunchedSnapshot = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(
            relaunchedSnapshot?.offlineMutationAuthority,
            true,
            "A temporary disconnect and cold launch retain authority only for the same replica"
        )

        let disabledSocket = ScriptedSharedPlanSyncSocket()
        await disabledSocket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: UUID(),
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: false
        )))
        let disabledStore = SharedPlanStore(
            persistence: persistence,
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: CountingSharedPlanSyncConnector(socket: disabledSocket),
            actorUserID: { "user-1" }
        )
        await disabledStore.load()
        await disabledStore.startSync(planID: planID)
        _ = await disabledSocket.waitForSentFrame(count: 1)
        XCTAssertFalse(disabledStore.permitsContentMutations(planID: planID))
        let disabledSnapshot = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(disabledSnapshot?.offlineMutationAuthority, false)
        await disabledStore.stopSync(planID: planID)

        let deniedAfterRelaunch = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "user-1" }
        )
        await deniedAfterRelaunch.load()
        do {
            _ = try await deniedAfterRelaunch.addCircle(
                try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 6_662)),
                to: planID
            )
            XCTFail("A server-disabled replica must remain read-only after relaunch")
        } catch {
            guard let sharedPlanError = error as? SharedPlanError,
                  case .documentLimit = sharedPlanError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testBacklogErrorIsDurablyQuarantinedAndBlocksFurtherEdits() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await document.snapshot(pendingOperationIDs: []),
            removingWriteID: nil
        )
        let socket = ScriptedSharedPlanSyncSocket()
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: UUID(),
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        )))
        let connector = CountingSharedPlanSyncConnector(socket: socket)
        let store = SharedPlanStore(
            persistence: persistence,
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: connector,
            actorUserID: { "user-1" }
        )
        await store.load()
        await store.startSync(planID: planID)
        _ = await socket.waitForSentFrame(count: 1)
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncErrorFrame(
            v: 1,
            type: "error",
            code: "plan_sync_backlog_limit",
            message: "too many changes",
            retryable: false,
            details: .init(
                maximumNewOperationsPerSyncFrame: 1_000,
                receivedChanges: 1_001
            )
        )))
        await socket.waitForClose(count: 1)
        let connectionsBeforeReentry = await connector.connectionCount
        await store.startSync(planID: planID)
        try await Task.sleep(nanoseconds: 20_000_000)
        let connectionsAfterReentry = await connector.connectionCount
        XCTAssertEqual(connectionsBeforeReentry, 1)
        XCTAssertEqual(
            connectionsAfterReentry,
            connectionsBeforeReentry,
            "Re-entering a quarantined plan must not restart its poisoned sync branch"
        )

        XCTAssertEqual(
            store.documentSnapshots[planID]?.syncIssue,
            .backlogLimit(maximum: 1_000, received: 1_001)
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 6_666))
        do {
            _ = try await store.addCircle(key, to: planID)
            XCTFail("A quarantined backlog must remain read-only")
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .planSyncBacklogLimit(maximum: 1_000, received: 1_001)
            )
        }

        let relaunched = SharedPlanStore(
            persistence: persistence,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        _ = try await relaunched.documentForSync(planID: planID)
        XCTAssertEqual(
            relaunched.documentSnapshots[planID]?.syncIssue,
            .backlogLimit(maximum: 1_000, received: 1_001)
        )
    }

    @MainActor
    func testLocalOneThousandOperationLimitPersistsButLegalBacklogStillSyncs() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        let pending = (0..<SharedPlanAutomergeDocument.maximumUnacknowledgedOperations)
            .map { index in
                UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012x",
                    index
                ))!
            }
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await document.snapshot(pendingOperationIDs: pending),
            removingWriteID: nil
        )

        let socket = ScriptedSharedPlanSyncSocket()
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: UUID(),
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        )))
        let connector = CountingSharedPlanSyncConnector(socket: socket)
        let store = SharedPlanStore(
            persistence: persistence,
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: connector,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        XCTAssertNil(store.documentSnapshots[planID]?.syncIssue)
        XCTAssertEqual(
            store.localEditLimit(planID: planID),
            .syncBacklog(maximum: 1_000, pending: 1_000)
        )
        let normalizedSnapshot = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(
            normalizedSnapshot?.localEditLimit,
            .syncBacklog(maximum: 1_000, pending: 1_000),
            "A legacy exact-limit snapshot must gain a durable local edit marker"
        )

        await store.startSync(planID: planID)
        await connector.waitForConnection(count: 1)
        let beforeRejectedEdit = try await persistence.loadDocument(planID: planID)
        do {
            _ = try await store.addCircle(
                try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 6_667)),
                to: planID
            )
            XCTFail("The 1,001st edit must be refused before persistence")
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .planSyncBacklogLimit(maximum: 1_000, received: 1_001)
            )
        }
        let afterRejectedEdit = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(
            afterRejectedEdit,
            beforeRejectedEdit,
            "Refusing edit 1,001 must not alter the legal source branch"
        )
        let localLimitConnectionCount = await connector.connectionCount
        XCTAssertEqual(localLimitConnectionCount, 1)
        await store.stopSync(planID: planID)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        XCTAssertEqual(
            relaunched.localEditLimit(planID: planID),
            .syncBacklog(maximum: 1_000, pending: 1_000)
        )
        try await relaunched.acknowledgeOperations(Set(pending), planID: planID)
        XCTAssertNil(relaunched.localEditLimit(planID: planID))
        let acknowledgedSnapshot = try await persistence.loadDocument(planID: planID)
        XCTAssertNil(acknowledgedSnapshot?.localEditLimit)
    }

    @MainActor
    func testServerCompactionErrorIsTerminalAcrossReentryAndReachability() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: try await persistence.replicaID()
        )
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await document.snapshot(pendingOperationIDs: []),
            removingWriteID: nil
        )
        let socket = ScriptedSharedPlanSyncSocket()
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: UUID(),
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        )))
        let connector = CountingSharedPlanSyncConnector(socket: socket)
        let store = SharedPlanStore(
            persistence: persistence,
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: connector,
            actorUserID: { "user-1" }
        )
        await store.load()
        await store.startSync(planID: planID)
        _ = await socket.waitForSentFrame(count: 1)
        await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncErrorFrame(
            v: 1,
            type: "error",
            code: "plan_compaction_required",
            message: "compact before continuing",
            retryable: false,
            details: nil
        )))
        await socket.waitForClose(count: 1)

        XCTAssertEqual(
            store.documentSnapshots[planID]?.syncIssue,
            .serverCompactionRequired
        )
        XCTAssertNil(store.localEditLimit(planID: planID))
        await store.startSync(planID: planID)
        await store.networkBecameReachable()
        try await Task.sleep(nanoseconds: 20_000_000)
        let terminalConnectionCount = await connector.connectionCount
        XCTAssertEqual(
            terminalConnectionCount,
            1,
            "A terminal server compaction issue must restart only after explicit recovery"
        )
    }

    @MainActor
    func testExplicitRebaseReplaysLedgerAndDiscardUsesServerBootstrap() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let replicaID = try await persistence.replicaID()
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        let serverBootstrap = SharedPlanSyncBootstrap(
            v: 1,
            document: await serverDocument.save().base64URLEncodedString,
            heads: await serverDocument.heads()
        )
        let localDocument = try SharedPlanAutomergeDocument(
            data: await serverDocument.save(),
            replicaID: replicaID
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 5_555))
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await localDocument.snapshot(pendingOperationIDs: []),
            removingWriteID: nil
        )
        let currentReplicaDraft = SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: key,
            text: "破棄する下書き",
            generation: 1,
            reason: .staged,
            updatedAt: Date(timeIntervalSince1970: 1),
            recoveryMessage: nil
        )
        let predecessorDraft = SharedPlanMemoDraft(
            planID: planID,
            replicaID: UUID(),
            circle: key,
            text: "前の参加世代から回収する下書き",
            generation: 1,
            reason: .authorityLost,
            updatedAt: Date(timeIntervalSince1970: 2),
            recoveryMessage: "参加世代が変わりました。"
        )
        try await persistence.saveMemoDraft(currentReplicaDraft)
        try await persistence.saveMemoDraft(predecessorDraft)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(
                plan: plan,
                bootstrap: serverBootstrap
            ),
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()
        _ = try await store.editorSnapshot(planID: planID)
        _ = try await store.addCircle(key, to: planID)
        let originalPending = try XCTUnwrap(
            store.documentSnapshots[planID]?.pendingOperationIDs
        )
        XCTAssertEqual(originalPending.count, 1)
        try await store.recordSyncIssue(.compactionRequired, planID: planID)

        try await store.rebaseUnsyncedContent(
            planID: planID,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(store.plans.first?.circleKeys, [key])
        XCTAssertEqual(
            store.documentSnapshots[planID]?.pendingOperationIDs,
            originalPending
        )
        XCTAssertNil(store.documentSnapshots[planID]?.syncIssue)

        try await store.recordSyncIssue(.compactionRequired, planID: planID)
        try await store.discardUnsyncedContentAndRebootstrap(planID: planID)
        XCTAssertTrue(store.plans.first?.circleKeys.isEmpty == true)
        XCTAssertEqual(store.documentSnapshots[planID]?.pendingOperationIDs, [])
        XCTAssertNil(store.documentSnapshots[planID]?.syncIssue)
        let draftsAfterDiscard = try await persistence.loadMemoDrafts(planID: planID)
        XCTAssertEqual(draftsAfterDiscard, [predecessorDraft])
        let editorAfterDiscard = try await store.editorSnapshot(planID: planID)
        XCTAssertEqual(editorAfterDiscard.memoDrafts, [predecessorDraft])
    }

    @MainActor
    func testColdVisibleOneThousandOneBacklogCanRebaseOnlyWhenResultFits() async throws {
        let fixture = try await makeCanonicalLegacyBacklogFixture(
            serverContainsFirstOperation: true
        )
        let plan = fixture.plan
        let planID = plan.id
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveBootstrappedPlan(
            plan,
            document: fixture.snapshot,
            removingWriteID: nil
        )
        let otherPlan = makePlan(id: UUID().uuidString.lowercased())
        let otherDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: otherPlan.id,
            comiketNo: otherPlan.comiketNo,
            replicaID: UUID()
        )
        let otherSnapshot = await otherDocument.snapshot(pendingOperationIDs: [UUID()])
        try await persistence.saveBootstrappedPlan(
            otherPlan,
            document: otherSnapshot,
            removingWriteID: nil
        )

        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(
                plan: plan,
                bootstrap: fixture.serverBootstrap
            ),
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        let source = try await store.editorSnapshot(planID: planID)
        XCTAssertEqual(source.pendingOperationCount, 1_001)
        XCTAssertEqual(
            source.localEditLimit,
            .syncBacklog(maximum: 1_000, pending: 1_001)
        )
        XCTAssertFalse(source.circles.isEmpty)
        XCTAssertNotNil(source.recoveryDocument)
        XCTAssertTrue(store.recoveryDocuments.contains { $0.planID == planID })
        do {
            _ = try await store.addCircle(
                try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_999)),
                to: planID
            )
            XCTFail("A cold over-limit branch must not admit normal editing")
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .planSyncBacklogLimit(maximum: 1_000, received: 1_002)
            )
        }

        try await store.rebaseUnsyncedContent(planID: planID)

        let rebuilt = try XCTUnwrap(store.documentSnapshots[planID])
        XCTAssertEqual(rebuilt.pendingOperationIDs.count, 1_000)
        XCTAssertNil(rebuilt.syncIssue)
        XCTAssertEqual(
            rebuilt.localEditLimit,
            .syncBacklog(maximum: 1_000, pending: 1_000)
        )
        let persistedOtherSnapshot = try await persistence.loadDocument(planID: otherPlan.id)
        XCTAssertEqual(persistedOtherSnapshot, otherSnapshot)

        let relaunched = SharedPlanStore(
            persistence: persistence,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await relaunched.load()
        let relaunchedSource = try await relaunched.editorSnapshot(planID: planID)
        XCTAssertEqual(relaunchedSource.pendingOperationCount, 1_000)
        XCTAssertNotNil(relaunchedSource.recoveryDocument)
    }

    @MainActor
    func testColdBacklogFailedRebasePreservesExactSourceThenDiscardRemainsUsable() async throws {
        let fixture = try await makeCanonicalLegacyBacklogFixture(
            serverContainsFirstOperation: false
        )
        let plan = fixture.plan
        let planID = plan.id
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveBootstrappedPlan(
            plan,
            document: fixture.snapshot,
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(
                plan: plan,
                bootstrap: fixture.serverBootstrap
            ),
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()
        let loadedBefore = try await persistence.loadDocument(planID: planID)
        let before = try XCTUnwrap(loadedBefore)
        let exportBefore = try XCTUnwrap(store.syncRecoveryDocument(planID: planID)?.exportText)

        do {
            try await store.rebaseUnsyncedContent(planID: planID)
            XCTFail("A rebase that still contains 1,001 pending operations must fail")
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .planSyncBacklogLimit(maximum: 1_000, received: 1_001)
            )
        }

        let persistedAfterFailure = try await persistence.loadDocument(planID: planID)
        XCTAssertEqual(persistedAfterFailure, before)
        XCTAssertEqual(store.documentSnapshots[planID], before)
        XCTAssertEqual(store.syncRecoveryDocument(planID: planID)?.exportText, exportBefore)

        try await store.discardUnsyncedContentAndRebootstrap(planID: planID)
        let discarded = try XCTUnwrap(store.documentSnapshots[planID])
        XCTAssertTrue(discarded.pendingOperationIDs.isEmpty)
        XCTAssertNil(discarded.localEditLimit)
        XCTAssertNil(discarded.syncIssue)
    }

    @MainActor
    func testColdCompactionMarkerKeepsVisibleProjectionAndRecovery() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 8_888))
        _ = try await document.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "user-1",
            authoredAt: Date(timeIntervalSince1970: 1)
        )
        let snapshot = await document.snapshot(
            pendingOperationIDs: [],
            localEditLimit: .compactionRequired
        )
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        let source = try await store.editorSnapshot(planID: planID)
        XCTAssertEqual(source.circles.map(\.key), [key])
        XCTAssertEqual(source.localEditLimit, .compactionRequired)
        XCTAssertNotNil(source.recoveryDocument)
        XCTAssertTrue(store.recoveryDocuments.contains { $0.planID == planID })
        do {
            _ = try await store.removeCircle(key, from: planID)
            XCTFail("A compaction-marked branch must remain read-only")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .planCompactionRequired)
        }
    }

    @MainActor
    func testFirstColdEditorLoadExposesRealRetainedPayloadOverflowAndAllowsRebase() async throws {
        let fixture = try await makeRetainedPayloadOverflowFixture()
        XCTAssertGreaterThan(
            fixture.retainedPayloadBytes,
            SharedPlanAutomergeDocument.maximumRetainedOperationPayloadUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            fixture.snapshot.document.count,
            SharedPlanAutomergeDocument.maximumSavedDocumentBytes
        )
        XCTAssertThrowsError(try SharedPlanAutomergeDocument(
            data: fixture.snapshot.document,
            replicaID: fixture.snapshot.replicaID
        )) { error in
            guard case .documentLimit = error as? SharedPlanError else {
                return XCTFail("Expected the normal reader to reject retained payload overflow")
            }
        }

        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveBootstrappedPlan(
            fixture.plan,
            document: fixture.snapshot,
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(
                plan: fixture.plan,
                bootstrap: fixture.serverBootstrap
            ),
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        // No marker is preseeded and no second load is needed: this call both
        // quarantines the strict decode and returns the relaxed projection.
        let source = try await store.editorSnapshot(planID: fixture.plan.id)
        XCTAssertEqual(source.plan.id, fixture.plan.id)
        XCTAssertEqual(source.syncIssue, .compactionRequired)
        XCTAssertFalse(source.permitsContentMutations)
        XCTAssertTrue(source.recoveryRebaseAvailable)
        XCTAssertNotNil(source.recoveryDocument)
        XCTAssertEqual(
            source.circles.first?.communicationState[fixture.lastField],
            .string(fixture.lastValue)
        )
        let export = try decodeRecoveryExport(source.recoveryDocument)
        XCTAssertEqual(export.automergeSaveByteCount, fixture.snapshot.document.count)
        XCTAssertFalse(export.automergeSaveOmittedForSafety)
        XCTAssertEqual(
            try XCTUnwrap(export.automergeSave),
            fixture.snapshot.document.base64URLEncodedString
        )

        try await store.rebaseUnsyncedContent(planID: fixture.plan.id)
        let rebased = try await store.editorSnapshot(planID: fixture.plan.id)
        XCTAssertNil(rebased.syncIssue)
        XCTAssertNil(rebased.localEditLimit)
        XCTAssertEqual(rebased.pendingOperationCount, 1)
        XCTAssertNil(rebased.recoveryDocument)
        XCTAssertEqual(
            rebased.circles.first?.communicationState[fixture.lastField],
            .string(fixture.lastValue)
        )
    }

    @MainActor
    func testFirstColdEditorLoadKeepsMalformedBytesOpaqueAndDiscardOnly() async throws {
        let plan = makePlan(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let malformed = Data("not-an-automerge-document".utf8)
        let snapshot = SharedPlanDocumentSnapshot(
            planID: plan.id,
            replicaID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            actorID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            document: malformed,
            pendingOperationIDs: [UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!]
        )
        let bootstrap = try await emptyBootstrap(for: plan)
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(plan: plan, bootstrap: bootstrap),
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        let source = try await store.editorSnapshot(planID: plan.id)
        XCTAssertEqual(source.plan.id, plan.id)
        XCTAssertTrue(source.circles.isEmpty)
        guard case .unavailable = source.syncIssue else {
            return XCTFail("Malformed bytes must be durably unavailable")
        }
        XCTAssertFalse(source.permitsContentMutations)
        XCTAssertFalse(source.recoveryRebaseAvailable)
        let export = try decodeRecoveryExport(source.recoveryDocument)
        XCTAssertEqual(export.automergeSaveByteCount, malformed.count)
        XCTAssertFalse(export.automergeSaveOmittedForSafety)
        XCTAssertEqual(export.automergeSave, malformed.base64URLEncodedString)
        guard case .unavailable = store.documentSnapshots[plan.id]?.syncIssue else {
            return XCTFail("The first failed decode must persist its recovery marker")
        }

        do {
            try await store.rebaseUnsyncedContent(planID: plan.id)
            XCTFail("Malformed retained bytes must not enter relaxed rebase")
        } catch {
            // The opaque source remains byte-identical until explicit discard.
            XCTAssertEqual(store.documentSnapshots[plan.id]?.document, malformed)
        }
        try await store.discardUnsyncedContentAndRebootstrap(planID: plan.id)
        XCTAssertNil(store.documentSnapshots[plan.id]?.syncIssue)
        XCTAssertTrue(store.documentSnapshots[plan.id]?.pendingOperationIDs.isEmpty == true)
    }

    @MainActor
    func testFirstColdEditorLoadOmitsUnboundedRawBytesFromRecoveryExport() async throws {
        let plan = makePlan(id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        let oversized = Data(
            repeating: 0xA5,
            count: SharedPlanAutomergeDocument.maximumSavedDocumentBytes + 1
        )
        let snapshot = SharedPlanDocumentSnapshot(
            planID: plan.id,
            replicaID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
            actorID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            document: oversized,
            pendingOperationIDs: []
        )
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: nil
        )
        let store = SharedPlanStore(
            persistence: persistence,
            allowsUnconnectedContentMutations: true,
            actorUserID: { "user-1" }
        )
        await store.load()

        let source = try await store.editorSnapshot(planID: plan.id)
        XCTAssertEqual(source.syncIssue, .compactionRequired)
        XCTAssertFalse(source.recoveryRebaseAvailable)
        XCTAssertFalse(source.permitsContentMutations)
        let export = try decodeRecoveryExport(source.recoveryDocument)
        XCTAssertEqual(export.automergeSaveByteCount, oversized.count)
        XCTAssertTrue(export.automergeSaveOmittedForSafety)
        XCTAssertNil(export.automergeSave)
    }

    @MainActor
    func testConnectedDiscardCreatesSessionBoundOnlyToRebuiltDocument() async throws {
        let planID = UUID().uuidString.lowercased()
        let plan = makePlan(id: planID)
        let persistence = InMemorySharedPlanPersistence()
        let serverDocument = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        let bootstrap = SharedPlanSyncBootstrap(
            v: 1,
            document: await serverDocument.save().base64URLEncodedString,
            heads: await serverDocument.heads()
        )
        let localDocument = try SharedPlanAutomergeDocument(
            data: await serverDocument.save(),
            replicaID: UUID()
        )
        let discardedOperationID = UUID()
        _ = try await localDocument.addCircle(
            try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 7_001)),
            operationID: discardedOperationID,
            actorUserID: "user-1",
            authoredAt: Date(timeIntervalSince1970: 1)
        )
        try await persistence.saveBootstrappedPlan(
            plan,
            document: await localDocument.snapshot(
                pendingOperationIDs: [discardedOperationID]
            ),
            removingWriteID: nil
        )

        let firstSocket = ScriptedSharedPlanSyncSocket()
        let secondSocket = ScriptedSharedPlanSyncSocket()
        for socket in [firstSocket, secondSocket] {
            await socket.enqueue(try JSONEncoder().encode(SharedPlanSyncHello(
                v: 1,
                type: "hello",
                planID: planID,
                sessionID: UUID(),
                nextClientSeq: 1,
                nextServerSeq: 1,
                mutationsEnabled: true
            )))
        }
        let connector = SequencedSharedPlanSyncConnector(
            sockets: [firstSocket, secondSocket]
        )
        let store = SharedPlanStore(
            persistence: persistence,
            remote: RebootstrapSharedPlanRemoteStub(plan: plan, bootstrap: bootstrap),
            syncRequestAuthorizer: StaticSharedPlanSyncAuthorizer(),
            syncConnector: connector,
            actorUserID: { "user-1" }
        )
        await store.load()
        await store.startSync(planID: planID)
        _ = await firstSocket.waitForSentFrame(count: 1)
        try await store.recordSyncIssue(.compactionRequired, planID: planID)

        try await store.discardUnsyncedContentAndRebootstrap(planID: planID)
        await connector.waitForConnection(count: 2)
        let rebuiltFrames = await secondSocket.waitForSentFrame(count: 1)
        let rebuiltFrame = try JSONDecoder().decode(
            SharedPlanClientSyncFrame.self,
            from: try XCTUnwrap(rebuiltFrames.first)
        )
        let rebuiltSnapshot = try XCTUnwrap(store.documentSnapshots[planID])
        let rebuiltDocument = try SharedPlanAutomergeDocument(
            data: rebuiltSnapshot.document,
            replicaID: rebuiltSnapshot.replicaID
        )
        let activeIdentity = await store.activeSyncDocumentIdentity(planID: planID)
        let identity = try XCTUnwrap(activeIdentity)
        let rebuiltHeads = await rebuiltDocument.heads()
        let rebuiltOperationIDs = await rebuiltDocument.semanticOperationIDs()

        XCTAssertEqual(rebuiltSnapshot.pendingOperationIDs, [])
        XCTAssertEqual(rebuiltFrame.replicaID, rebuiltSnapshot.replicaID)
        XCTAssertEqual(rebuiltFrame.actorID, rebuiltSnapshot.actorID)
        XCTAssertEqual(identity.replicaID, rebuiltSnapshot.replicaID)
        XCTAssertEqual(identity.actorID, rebuiltSnapshot.actorID)
        XCTAssertEqual(identity.heads, rebuiltHeads)
        XCTAssertFalse(rebuiltOperationIDs.contains(discardedOperationID))

        await firstSocket.enqueue(try JSONEncoder().encode(SharedPlanSyncErrorFrame(
            v: 1,
            type: "error",
            code: "plan_sync_backlog_limit",
            message: "stale old-session error",
            retryable: false,
            details: .init(maximumNewOperationsPerSyncFrame: 1_000, receivedChanges: 1_001)
        )))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.documentSnapshots[planID]?.syncIssue)
        let oldSessionSentFrameCount = await firstSocket.sentFrameCount
        XCTAssertEqual(oldSessionSentFrameCount, 1)
    }

    @MainActor
    private func makeCanonicalLegacyBacklogFixture(
        serverContainsFirstOperation: Bool
    ) async throws -> (
        plan: SharedPlan,
        snapshot: SharedPlanDocumentSnapshot,
        serverBootstrap: SharedPlanSyncBootstrap
    ) {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(
            bundle.url(forResource: "automerge-sync-v1", withExtension: "json")
                ?? bundle.url(
                    forResource: "automerge-sync-v1",
                    withExtension: "json",
                    subdirectory: "Fixtures"
                )
        )
        let fixture = try JSONDecoder().decode(
            CanonicalBacklogFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let vector = try XCTUnwrap(
            fixture.backlogLimitVectors.vectors.first {
                $0.changeCount
                    == SharedPlanAutomergeDocument.maximumUnacknowledgedOperations + 1
            }
        )
        let clientBytes = try XCTUnwrap(Data(base64URLString: vector.clientDocument))
        let baseBytes = try XCTUnwrap(
            Data(base64URLString: fixture.backlogLimitVectors.baseDocument)
        )
        let local = try SharedPlanAutomergeDocument(data: clientBytes, replicaID: UUID())
        let server = try SharedPlanAutomergeDocument(data: baseBytes, replicaID: UUID())
        let baseOperationIDs = await server.semanticOperationIDs()
        let operationIDs = await local.semanticOperationIDs()
            .subtracting(baseOperationIDs)
            .sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(
            operationIDs.count,
            SharedPlanAutomergeDocument.maximumUnacknowledgedOperations + 1
        )
        if serverContainsFirstOperation {
            let firstOperationID = try XCTUnwrap(operationIDs.first)
            let localRecords = try await local.operationRecords()
            let firstRecord = try XCTUnwrap(
                localRecords.first { $0.id == firstOperationID }
            )
            _ = try await server.applyRebasedMutation(
                firstRecord.durableMutation(comiketNo: fixture.comiketNo),
                operationID: firstOperationID,
                actorUserID: firstRecord.actorUserID,
                authoredAt: Date(timeIntervalSince1970: 1_786_302_000)
            )
        }
        let plan = SharedPlan(
            id: fixture.planID,
            name: "同期テスト",
            comiketNo: fixture.comiketNo,
            ownership: .owned,
            role: .owner,
            lifecycle: .active,
            revision: 1,
            circleKeys: try await local.circleKeys(),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return (
            plan,
            await local.snapshot(
                pendingOperationIDs: operationIDs,
                localEditLimit: .syncBacklog(
                    maximum: SharedPlanAutomergeDocument.maximumUnacknowledgedOperations,
                    pending: operationIDs.count
                )
            ),
            SharedPlanSyncBootstrap(
                v: 1,
                document: await server.save().base64URLEncodedString,
                heads: await server.heads()
            )
        )
    }

    @MainActor
    private func makeRetainedPayloadOverflowFixture() async throws -> (
        plan: SharedPlan,
        snapshot: SharedPlanDocumentSnapshot,
        serverBootstrap: SharedPlanSyncBootstrap,
        retainedPayloadBytes: Int,
        lastField: String,
        lastValue: String
    ) {
        let planID = "99999999-9999-4999-8999-999999999999"
        let replicaID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 4_242))
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: planID,
            comiketNo: 108,
            replicaID: replicaID
        )
        _ = try await seed.addCircle(
            key,
            operationID: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
            actorUserID: "user-1",
            authoredAt: Date(timeIntervalSince1970: 1_786_302_000)
        )
        let serverDocument = await seed.save()
        let serverHeads = await seed.heads()
        let raw = try Document(serverDocument)
        raw.actor = ActorId(uuid: replicaID)
        guard case let .Object(circles, .Map) = try raw.get(obj: .ROOT, key: "circles"),
              case let .Object(circle, .Map) = try raw.get(
                  obj: circles,
                  key: String(key.wcID)
              ),
              case let .Object(communication, .Map) = try raw.get(
                  obj: circle,
                  key: "communicationState"
              ),
              case let .Object(operations, .Map) = try raw.get(
                  obj: .ROOT,
                  key: "operations"
              )
        else { throw SharedPlanError.syncProtocolViolation }

        var retainedPayloadBytes = 0
        var lastOperationID = UUID(uuidString: "80000000-0000-4000-8000-000000000000")!
        var lastField = ""
        var lastValue = ""
        for index in 1...130 {
            let operationID = UUID(uuidString: String(
                format: "80000000-0000-4000-8000-%012x",
                index
            ))!
            let field = String(format: "recovery.%03d", index)
            let prefix = String(format: "%04x", index)
            let value = prefix + String(repeating: "x", count: 4_096 - prefix.utf8.count)
            let visible = try raw.putObject(obj: communication, key: field, ty: .Text)
            try raw.spliceText(obj: visible, start: 0, delete: 0, value: value)

            let operation = try raw.putObject(
                obj: operations,
                key: operationID.uuidString.lowercased(),
                ty: .Map
            )
            try putText(
                SharedPlanOperationType.circleCommunicationSet.rawValue,
                in: operation,
                key: "type",
                document: raw
            )
            try putText("user-1", in: operation, key: "actorUserID", document: raw)
            let payloadObject = try raw.putObject(obj: operation, key: "payload", ty: .Map)
            try raw.put(obj: payloadObject, key: "v", value: .Int(1))
            try raw.put(obj: payloadObject, key: "wcID", value: .Int(Int64(key.wcID)))
            try putText(field, in: payloadObject, key: "key", document: raw)
            try putText(value, in: payloadObject, key: "value", document: raw)
            raw.commitWith(
                message: "operation:\(operationID.uuidString.lowercased())",
                timestamp: Date(timeIntervalSince1970: 1_786_302_000 + TimeInterval(index))
            )
            retainedPayloadBytes += try SharedPlanCanonicalJSON.payloadBytes([
                "v": .integer(1),
                "wcID": .integer(Int64(key.wcID)),
                "key": .string(field),
                "value": .string(value),
            ])
            lastOperationID = operationID
            lastField = field
            lastValue = value
        }
        let retainedDocument = raw.save()
        let relaxed = try SharedPlanAutomergeDocument(
            data: retainedDocument,
            replicaID: replicaID,
            allowingPolicyLimitOverflow: true
        )
        let plan = SharedPlan(
            id: planID,
            name: "保持上限テスト",
            comiketNo: 108,
            ownership: .owned,
            role: .owner,
            lifecycle: .active,
            revision: 1,
            circleKeys: [key],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return (
            plan,
            await relaxed.snapshot(pendingOperationIDs: [lastOperationID]),
            SharedPlanSyncBootstrap(
                v: 1,
                document: serverDocument.base64URLEncodedString,
                heads: serverHeads
            ),
            retainedPayloadBytes,
            lastField,
            lastValue
        )
    }

    @MainActor
    private func emptyBootstrap(for plan: SharedPlan) async throws -> SharedPlanSyncBootstrap {
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: plan.id,
            comiketNo: plan.comiketNo,
            replicaID: UUID()
        )
        return SharedPlanSyncBootstrap(
            v: 1,
            document: await document.save().base64URLEncodedString,
            heads: await document.heads()
        )
    }

    private func putText(
        _ value: String,
        in object: ObjId,
        key: String,
        document: Document
    ) throws {
        let text = try document.putObject(obj: object, key: key, ty: .Text)
        try document.spliceText(obj: text, start: 0, delete: 0, value: value)
    }

    private func decodeRecoveryExport(
        _ recovery: SharedPlanRecoveryDocument?
    ) throws -> RecoveryExportProbe {
        let recovery = try XCTUnwrap(recovery)
        return try JSONDecoder().decode(
            RecoveryExportProbe.self,
            from: try XCTUnwrap(recovery.exportText.data(using: .utf8))
        )
    }

    private func makeInboundChangeFrame(
        clientSession: SharedPlanSyncSession,
        serverDocument: SharedPlanAutomergeDocument,
        planID: String,
        sessionID: UUID
    ) async throws -> SharedPlanServerSyncFrame {
        try await clientSession.receiveHello(SharedPlanSyncHello(
            v: 1,
            type: "hello",
            planID: planID,
            sessionID: sessionID,
            nextClientSeq: 1,
            nextServerSeq: 1,
            mutationsEnabled: true
        ))
        await serverDocument.beginSyncSession(id: sessionID)
        let generatedClientGreeting = try await clientSession.nextOutboundFrame()
        let clientGreeting = try XCTUnwrap(generatedClientGreeting)
        try await serverDocument.receiveSyncMessage(
            sessionID: sessionID,
            message: try XCTUnwrap(Data(base64URLString: clientGreeting.payload))
        )
        let generated = try await serverDocument.generateSyncMessage(sessionID: sessionID)
        return SharedPlanServerSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            seq: 1,
            frameID: UUID(),
            payload: try XCTUnwrap(generated).base64URLEncodedString
        )
    }

    private func makePlan(id: String) -> SharedPlan {
        SharedPlan(
            id: id,
            name: "同期テスト",
            comiketNo: 108,
            ownership: .owned,
            role: .owner,
            lifecycle: .active,
            revision: 1,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct CanonicalBacklogFixture: Decodable {
    let planID: String
    let comiketNo: Int
    let backlogLimitVectors: CanonicalBacklogLimitVectors
}

private struct CanonicalBacklogLimitVectors: Decodable {
    let baseDocument: String
    let vectors: [CanonicalBacklogVector]
}

private struct CanonicalBacklogVector: Decodable {
    let changeCount: Int
    let clientDocument: String
}

private struct RecoveryExportProbe: Decodable {
    let automergeSave: String?
    let automergeSaveByteCount: Int
    let automergeSaveOmittedForSafety: Bool
}

private actor AcknowledgedOperationRecorder {
    private(set) var values: [Set<UUID>] = []

    func record(_ value: Set<UUID>) {
        values.append(value)
    }
}

private struct StaticSharedPlanSyncAuthorizer: SharedPlanSyncRequestAuthorizing {
    func sharedPlanSyncWebSocketRequest(planID: String) async throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "wss://cominavi.net/api/v2/plans/\(planID)/sync"
        )))
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        return request
    }
}

private actor CountingSharedPlanSyncConnector: SharedPlanSyncConnecting {
    private let socket: ScriptedSharedPlanSyncSocket
    private(set) var connectionCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(socket: ScriptedSharedPlanSyncSocket) {
        self.socket = socket
    }

    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket {
        connectionCount += 1
        let ready = waiters.filter { connectionCount >= $0.0 }
        waiters.removeAll { connectionCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        return socket
    }

    func waitForConnection(count: Int) async {
        if connectionCount >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor SequencedSharedPlanSyncConnector: SharedPlanSyncConnecting {
    private var sockets: [ScriptedSharedPlanSyncSocket]
    private(set) var connectionCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(sockets: [ScriptedSharedPlanSyncSocket]) {
        self.sockets = sockets
    }

    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket {
        guard !sockets.isEmpty else { throw URLError(.cannotConnectToHost) }
        connectionCount += 1
        let socket = sockets.removeFirst()
        let ready = waiters.filter { connectionCount >= $0.0 }
        waiters.removeAll { connectionCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        return socket
    }

    func waitForConnection(count: Int) async {
        if connectionCount >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor ScriptedSharedPlanSyncSocket: SharedPlanSyncSocket {
    private var receivedQueue: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data, Error>] = []
    private var sentFrames: [Data] = []
    private var sentWaiters: [(Int, CheckedContinuation<[Data], Never>)] = []
    private var isClosed = false
    private(set) var closeCount = 0
    private var closeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var sentFrameCount: Int { sentFrames.count }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw CancellationError() }
        sentFrames.append(data)
        let ready = sentWaiters.filter { sentFrames.count >= $0.0 }
        sentWaiters.removeAll { sentFrames.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume(returning: sentFrames) }
    }

    func receive() async throws -> Data {
        if !receivedQueue.isEmpty { return receivedQueue.removeFirst() }
        guard !isClosed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func close() {
        closeCount += 1
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        let ready = closeWaiters.filter { closeCount >= $0.0 }
        closeWaiters.removeAll { closeCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func enqueue(_ data: Data) {
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            receivedQueue.append(data)
        }
    }

    func waitForSentFrame(count: Int) async -> [Data] {
        if sentFrames.count >= count { return sentFrames }
        return await withCheckedContinuation { continuation in
            sentWaiters.append((count, continuation))
        }
    }

    func waitForClose(count: Int) async {
        if closeCount >= count { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append((count, continuation))
        }
    }
}

private actor SharedPlanSyncStatusRecorder {
    private var statuses: [SharedPlanSyncConnectionStatus] = []
    private var synchronizedWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: SharedPlanSyncConnectionStatus) {
        statuses.append(value)
        guard case .synchronized = value else { return }
        let waiters = synchronizedWaiters
        synchronizedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForSynchronized() async {
        if statuses.contains(where: {
            if case .synchronized = $0 { return true }
            return false
        }) { return }
        await withCheckedContinuation { continuation in
            synchronizedWaiters.append(continuation)
        }
    }
}

private actor RebootstrapSharedPlanRemoteStub: SharedPlanRemoteServicing {
    private let plan: SharedPlan
    private let bootstrap: SharedPlanSyncBootstrap

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
        throw SharedPlanError.syncProtocolViolation
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.syncProtocolViolation
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.syncProtocolViolation
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw SharedPlanError.syncProtocolViolation
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
