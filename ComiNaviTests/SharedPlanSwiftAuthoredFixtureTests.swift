@testable import ComiNavi
import CryptoKit
import Foundation
import XCTest

final class SharedPlanSwiftAuthoredFixtureTests: XCTestCase {
    func testGenerateNamedPurchaseRequestInteropFixture() async throws {
        let source = try loadSourceFixture()
        let document = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(source.bootstrap.document),
            replicaID: Self.clientReplicaID
        )
        let actorUserID = "11111111111111111111111111111111"
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: source.comiketNo, wcID: 9_102)
        )
        let circleOperationID = UUID(
            uuidString: "91919191-9191-4191-8191-919191919191"
        )!
        _ = try await authorVector(
            document: document,
            mutation: .setCirclePresence(circle, .active),
            operationID: circleOperationID,
            actorUserID: actorUserID,
            authoredAt: Date(timeIntervalSince1970: 1_700_001_000),
            pendingOperationIDs: [circleOperationID],
            scenario: "named purchase request setup",
            kind: "circle"
        )
        let needOperationID = UUID(
            uuidString: "92929292-9292-4292-8292-929292929292"
        )!
        let vector = try await authorVector(
            document: document,
            mutation: .createNeed(
                SharedPlanPurchaseNeed(
                    id: UUID(uuidString: "93939393-9393-4393-8393-939393939393")!,
                    requesterUserID: actorUserID,
                    itemName: "新刊セット",
                    unitPrice: 2_000,
                    wantedQuantity: 2
                ),
                circle: circle
            ),
            operationID: needOperationID,
            actorUserID: actorUserID,
            authoredAt: Date(timeIntervalSince1970: 1_700_001_001),
            pendingOperationIDs: [circleOperationID, needOperationID],
            scenario: "named purchase request",
            kind: "need"
        )
        let fixture = SwiftNamedNeedFixture(
            fixtureVersion: 1,
            planID: source.planID,
            comiketNo: source.comiketNo,
            replicaID: Self.clientReplicaID.uuidString.lowercased(),
            actorID: await document.actorID(),
            userPublicID: actorUserID,
            vector: vector
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(fixture) + Data("\n".utf8)
        let checkedIn = try loadFixtureData(named: "automerge-swift-named-need-v1")
        if encoded != checkedIn {
            let attachment = XCTAttachment(
                data: encoded,
                uniformTypeIdentifier: "public.json"
            )
            attachment.name = "automerge-swift-named-need-v1.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(encoded, checkedIn)
        try await assertVectorReplays(
            vector,
            planID: source.planID,
            comiketNo: source.comiketNo
        )
    }

    func testGenerateAndValidateDeterministicSwiftAuthoredFixture() async throws {
        let source = try loadSourceFixture()
        let generated = try await makeFixture(source: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(generated) + Data("\n".utf8)
        let checkedIn = try loadFixtureData(named: "automerge-swift-authored-v1")

        if encoded != checkedIn {
            let attachment = XCTAttachment(
                data: encoded,
                uniformTypeIdentifier: "public.json"
            )
            attachment.name = "automerge-swift-authored-v1.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(encoded, checkedIn)
        XCTAssertEqual(generated.fixtureVersion, 1)
        XCTAssertEqual(generated.producer.package, "automerge-swift")
        XCTAssertEqual(generated.producer.version, "0.7.2")
        XCTAssertEqual(generated.operationVectors.count, 8)
        XCTAssertEqual(Set(generated.operationVectors.map(\.operation.type)).count, 8)
        XCTAssertEqual(generated.resolverVectors.count, 4)
        XCTAssertEqual(
            Set(
                generated.operationVectors.map(\.operation.type)
                    + generated.resolverVectors.map(\.operation.type)
            ),
            Set(SharedPlanOperationType.allCases)
        )
        XCTAssertEqual(generated.unicode.memo, Self.unicodeMemo)
        XCTAssertEqual(generated.unicode.unicodeScalarCount, Self.unicodeMemo.unicodeScalars.count)
        XCTAssertEqual(generated.swiftSync.convergedHeads, generated.operationVectors.last?.afterHeads)
        XCTAssertEqual(generated.javascriptSync.status, "complete")
        XCTAssertEqual(generated.javascriptSync.responsePayloads.count, 2)

        for vector in generated.operationVectors + generated.resolverVectors {
            try await assertVectorReplays(vector, planID: source.planID, comiketNo: source.comiketNo)
        }
        try await assertJavaScriptSyncHandoffReplays(generated)
    }

    private func makeFixture(source: SourceFixture) async throws -> SwiftAuthoredFixture {
        let bootstrapData = try unwrapBase64URL(source.bootstrap.document)
        let document = try SharedPlanAutomergeDocument(
            data: bootstrapData,
            replicaID: Self.clientReplicaID
        )
        let actorID = await document.actorID()
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: source.comiketNo, wcID: 9_101)
        )
        let needID = UUID(uuidString: "31313131-3131-4131-8131-313131313131")!
        let actorUserID = "11111111111111111111111111111111"
        var pendingOperationIDs: [UUID] = []
        var operationVectors: [SwiftAuthoredOperationVector] = []
        let operations: [(UUID, SharedPlanDurableMutation)] = [
            (
                UUID(uuidString: "10101010-1010-4010-8010-101010101010")!,
                .setCirclePresence(circle, .active)
            ),
            (
                UUID(uuidString: "20202020-2020-4020-8020-202020202020")!,
                .spliceMemo(circle: circle, index: 0, deleteCount: 0, text: Self.unicodeMemo)
            ),
            (
                UUID(uuidString: "30303030-3030-4030-8030-303030303030")!,
                .createNeed(
                    SharedPlanPurchaseNeed(
                        id: needID,
                        requesterUserID: actorUserID,
                        wantedQuantity: 3,
                        buyerAllocations: [:],
                        fulfilledQuantity: 0
                    ),
                    circle: circle
                )
            ),
            (
                UUID(uuidString: "40404040-4040-4040-8040-404040404040")!,
                .setWantedQuantity(4, needID: needID, circle: circle)
            ),
            (
                UUID(uuidString: "50505050-5050-4050-8050-505050505050")!,
                .setBuyerAllocation(
                    2,
                    buyerUserID: "22222222222222222222222222222222",
                    needID: needID,
                    circle: circle
                )
            ),
            (
                UUID(uuidString: "60606060-6060-4060-8060-606060606060")!,
                .setFulfilledQuantity(1, needID: needID, circle: circle)
            ),
            (
                UUID(uuidString: "70707070-7070-4070-8070-707070707070")!,
                .setCommunication(.string("連絡済み"), key: "meeting.status", circle: circle)
            ),
            (
                UUID(uuidString: "80808080-8080-4080-8080-808080808080")!,
                .deleteNeed(needID, circle: circle)
            ),
        ]

        for (index, entry) in operations.enumerated() {
            pendingOperationIDs.append(entry.0)
            operationVectors.append(
                try await authorVector(
                    document: document,
                    mutation: entry.1,
                    operationID: entry.0,
                    actorUserID: actorUserID,
                    authoredAt: Date(
                        timeIntervalSince1970: TimeInterval(Self.authoredAtUnixSeconds + Int64(index))
                    ),
                    pendingOperationIDs: pendingOperationIDs,
                    scenario: nil,
                    kind: nil
                )
            )
        }

        let resolverSources = source.nestedParentResolutionVectors
        XCTAssertEqual(resolverSources.count, 4)
        let resolverOperationIDs = [
            UUID(uuidString: "90909090-9090-4090-8090-909090909090")!,
            UUID(uuidString: "a0a0a0a0-a0a0-40a0-80a0-a0a0a0a0a0a0")!,
            UUID(uuidString: "b0b0b0b0-b0b0-40b0-80b0-b0b0b0b0b0b0")!,
            UUID(uuidString: "c0c0c0c0-c0c0-40c0-80c0-c0c0c0c0c0c0")!,
        ]
        var resolverVectors: [SwiftAuthoredOperationVector] = []
        for (index, resolverSource) in resolverSources.enumerated() {
            let resolverDocument = try SharedPlanAutomergeDocument(
                data: try unwrapBase64URL(resolverSource.beforeDocument),
                replicaID: Self.clientReplicaID
            )
            let mutation = try resolverMutation(from: resolverSource.operation)
            let operationID = resolverOperationIDs[index]
            resolverVectors.append(
                try await authorVector(
                    document: resolverDocument,
                    mutation: mutation,
                    operationID: operationID,
                    actorUserID: actorUserID,
                    authoredAt: Date(
                        timeIntervalSince1970: TimeInterval(
                            Self.authoredAtUnixSeconds + 100 + Int64(index)
                        )
                    ),
                    pendingOperationIDs: [operationID],
                    scenario: resolverSource.scenario,
                    kind: resolverSource.kind
                )
            )
        }

        let finalClientDocument = try XCTUnwrap(operationVectors.last?.afterDocument)
        let sync = try await makeSyncDialogue(
            planID: source.planID,
            bootstrapDocument: source.bootstrap.document,
            clientDocument: finalClientDocument
        )
        let sourceData = try loadSourceFixtureData()
        return SwiftAuthoredFixture(
            fixtureVersion: 1,
            producer: .init(package: "automerge-swift", version: "0.7.2", runtime: "Swift"),
            sourceFixtureSHA256: SHA256.hash(data: sourceData).hexString,
            planID: source.planID,
            comiketNo: source.comiketNo,
            replicaID: Self.clientReplicaID.uuidString.lowercased(),
            actorID: actorID,
            authoredAtUnixSeconds: Self.authoredAtUnixSeconds,
            bootstrap: source.bootstrap,
            operationVectors: operationVectors,
            resolverVectors: resolverVectors,
            unicode: .init(
                memo: Self.unicodeMemo,
                unicodeScalarCount: Self.unicodeMemo.unicodeScalars.count,
                utf8ByteCount: Self.unicodeMemo.utf8.count,
                memoOperationID: operations[1].0.uuidString.lowercased()
            ),
            swiftSync: sync,
            javascriptSync: .init(
                beforeDocument: sync.serverBeforeDocument,
                clientDocument: sync.clientBeforeDocument,
                clientToServerPayloads: sync.clientToServerPayloads,
                responsePayloads: Self.javaScriptResponsePayloads,
                serverDocument: sync.clientBeforeDocument,
                convergedDocument: sync.clientBeforeDocument,
                convergedHeads: Self.javaScriptConvergedHeads,
                status: "complete"
            ),
            transportReceipts: makeTransportReceipts(planID: source.planID, sync: sync)
        )
    }

    private func assertJavaScriptSyncHandoffReplays(
        _ fixture: SwiftAuthoredFixture
    ) async throws {
        let handoff = fixture.javascriptSync
        let client = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(handoff.clientDocument),
            replicaID: Self.clientReplicaID
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: fixture.swiftSync.sessionID))
        await client.beginSyncSession(id: sessionID)

        let negotiation = try await requiredSyncMessage(
            from: client,
            sessionID: sessionID,
            context: "JavaScript handoff client negotiation"
        )
        XCTAssertEqual(
            negotiation.base64URLEncodedString,
            handoff.clientToServerPayloads[0]
        )
        try await client.receiveSyncMessage(
            sessionID: sessionID,
            message: try unwrapBase64URL(handoff.responsePayloads[0])
        )
        let changes = try await requiredSyncMessage(
            from: client,
            sessionID: sessionID,
            context: "JavaScript handoff client changes"
        )
        XCTAssertEqual(changes.base64URLEncodedString, handoff.clientToServerPayloads[1])
        try await client.receiveSyncMessage(
            sessionID: sessionID,
            message: try unwrapBase64URL(handoff.responsePayloads[1])
        )

        let convergedHeads = await client.heads()
        let convergedDocument = await client.save().base64URLEncodedString
        XCTAssertEqual(convergedHeads, handoff.convergedHeads)
        XCTAssertEqual(convergedDocument, handoff.convergedDocument)
        XCTAssertEqual(handoff.serverDocument, handoff.convergedDocument)
    }

    private func authorVector(
        document: SharedPlanAutomergeDocument,
        mutation: SharedPlanDurableMutation,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        pendingOperationIDs: [UUID],
        scenario: String?,
        kind: String?
    ) async throws -> SwiftAuthoredOperationVector {
        let beforeDocument = await document.save()
        let beforeHeads = await document.heads()
        let beforeHistoryCount = await document.historyCount()
        let result = try await document.performDurableMutation(
            mutation,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            pendingOperationIDs: pendingOperationIDs
        ) { _, _ in }
        _ = try XCTUnwrap(result)
        let changes = try await document.encodedChanges(sinceHistoryIndex: beforeHistoryCount)
        let change = try XCTUnwrap(changes.only)
        let afterDocument = await document.save()
        let afterHeads = await document.heads()
        let records = try await document.operationRecords()
        let record = try XCTUnwrap(records.first(where: { $0.id == operationID }))
        XCTAssertEqual(change.hash, try XCTUnwrap(afterHeads.only))
        XCTAssertEqual(change.timestamp, authoredAt)
        return SwiftAuthoredOperationVector(
            scenario: scenario,
            kind: kind,
            operationID: operationID.uuidString.lowercased(),
            operation: .init(
                type: record.type,
                actorUserID: record.actorUserID,
                payload: record.payload
            ),
            beforeDocument: beforeDocument.base64URLEncodedString,
            beforeHeads: beforeHeads,
            change: change.bytes.base64URLEncodedString,
            changeHash: change.hash,
            changeActorID: change.actorID,
            changeMessage: change.message,
            changeTimestampUnixSeconds: Int64(change.timestamp.timeIntervalSince1970),
            afterDocument: afterDocument.base64URLEncodedString,
            afterHeads: afterHeads
        )
    }

    private func assertVectorReplays(
        _ vector: SwiftAuthoredOperationVector,
        planID: String,
        comiketNo: Int
    ) async throws {
        let replay = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(vector.beforeDocument),
            replicaID: Self.serverReplicaID
        )
        XCTAssertEqual(replay.planID, planID, vector.operationID)
        XCTAssertEqual(replay.comiketNo, comiketNo, vector.operationID)
        try await replay.applyEncodedChanges(unwrapBase64URL(vector.change))
        let heads = await replay.heads()
        let saved = await replay.save()
        let records = try await replay.operationRecords()
        let operationID = try XCTUnwrap(UUID(uuidString: vector.operationID))
        let record = try XCTUnwrap(records.first(where: { $0.id == operationID }))
        XCTAssertEqual(heads, vector.afterHeads, vector.operationID)
        XCTAssertEqual(saved, try unwrapBase64URL(vector.afterDocument), vector.operationID)
        XCTAssertEqual(record.type, vector.operation.type, vector.operationID)
        XCTAssertEqual(record.actorUserID, vector.operation.actorUserID, vector.operationID)
        XCTAssertEqual(record.payload, vector.operation.payload, vector.operationID)
    }

    private func resolverMutation(from operation: SourceOperation) throws -> SharedPlanDurableMutation {
        let payload = operation.payload
        let wcID = try payload.requiredInteger("wcID")
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: 108, wcID: Int(wcID))
        )
        let selectedParentOperationID = try XCTUnwrap(
            UUID(uuidString: payload.requiredString("selectedParentOperationID"))
        )
        let state = try XCTUnwrap(
            SharedPlanPresenceState(rawValue: payload.requiredString("state"))
        )
        let nestedResolutions = try payload.requiredArray("nestedResolutions").map { value in
            let object = try value.requiredObject()
            return SharedPlanNestedConflictResolution(
                conflictID: try object.requiredString("conflictID"),
                path: try object.requiredArray("path").map { try $0.requiredString() },
                selectedChangeHash: try object.requiredString("selectedChangeHash"),
                value: try object.requiredValue("value")
            )
        }
        switch operation.type {
        case .circleResolveParent:
            return .resolveCircleParent(
                circle: circle,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions
            )
        case .needResolveParent:
            return .resolveNeedParent(
                needID: try XCTUnwrap(UUID(uuidString: payload.requiredString("needID"))),
                circle: circle,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions
            )
        default:
            throw SharedPlanError.syncProtocolViolation
        }
    }

    private func makeSyncDialogue(
        planID: String,
        bootstrapDocument: String,
        clientDocument: String
    ) async throws -> SwiftSyncDialogue {
        let server = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(bootstrapDocument),
            replicaID: Self.serverReplicaID
        )
        let client = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(clientDocument),
            replicaID: Self.clientReplicaID
        )
        let sessionID = UUID(uuidString: "d0d0d0d0-d0d0-40d0-80d0-d0d0d0d0d0d0")!
        await server.beginSyncSession(id: sessionID)
        await client.beginSyncSession(id: sessionID)

        let clientNegotiation = try await requiredSyncMessage(
            from: client,
            sessionID: sessionID,
            context: "Swift dialogue client negotiation"
        )
        try await server.receiveSyncMessage(sessionID: sessionID, message: clientNegotiation)
        let serverNeed = try await requiredSyncMessage(
            from: server,
            sessionID: sessionID,
            context: "Swift dialogue server need"
        )
        try await client.receiveSyncMessage(sessionID: sessionID, message: serverNeed)
        let clientChanges = try await requiredSyncMessage(
            from: client,
            sessionID: sessionID,
            context: "Swift dialogue client changes"
        )
        try await server.receiveSyncMessage(sessionID: sessionID, message: clientChanges)

        let clientHeads = await client.heads()
        let serverHeads = await server.heads()
        XCTAssertEqual(clientHeads, serverHeads)
        return SwiftSyncDialogue(
            sessionID: sessionID.uuidString.lowercased(),
            serverBeforeDocument: bootstrapDocument,
            clientBeforeDocument: clientDocument,
            clientToServerPayloads: [
                clientNegotiation.base64URLEncodedString,
                clientChanges.base64URLEncodedString,
            ],
            // Both documents have converged after the accepted client frame.
            // Automerge may or may not emit a redundant final server message,
            // so the deterministic dialogue intentionally stops here.
            serverToClientPayloads: [serverNeed.base64URLEncodedString],
            serverAfterDocument: await server.save().base64URLEncodedString,
            clientAfterDocument: await client.save().base64URLEncodedString,
            convergedHeads: clientHeads
        )
    }

    private func requiredSyncMessage(
        from document: SharedPlanAutomergeDocument,
        sessionID: UUID,
        context: String
    ) async throws -> Data {
        let generated = try await document.generateSyncMessage(sessionID: sessionID)
        return try XCTUnwrap(generated, context)
    }

    private func makeTransportReceipts(
        planID: String,
        sync: SwiftSyncDialogue
    ) -> SwiftTransportReceipts {
        let sessionID = UUID(uuidString: sync.sessionID)!
        let accepted = SharedPlanClientSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            replicaID: Self.clientReplicaID,
            actorID: Self.clientReplicaID.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            seq: 2,
            frameID: UUID(uuidString: "e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e0e0")!,
            payload: sync.clientToServerPayloads[1]
        )
        let receiptViolation = SharedPlanClientSyncFrame(
            v: accepted.v,
            type: accepted.type,
            planID: accepted.planID,
            sessionID: accepted.sessionID,
            replicaID: accepted.replicaID,
            actorID: accepted.actorID,
            seq: accepted.seq,
            frameID: accepted.frameID,
            payload: sync.clientToServerPayloads[0]
        )
        let sequenceGap = SharedPlanClientSyncFrame(
            v: accepted.v,
            type: accepted.type,
            planID: accepted.planID,
            sessionID: accepted.sessionID,
            replicaID: accepted.replicaID,
            actorID: accepted.actorID,
            seq: 4,
            frameID: UUID(uuidString: "f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f0f0")!,
            payload: accepted.payload
        )
        return SwiftTransportReceipts(
            acceptedEnvelope: accepted,
            exactDuplicateEnvelope: accepted,
            receiptViolationEnvelope: receiptViolation,
            sequenceGapEnvelope: sequenceGap,
            acknowledgement: SharedPlanSyncAcknowledgement(
                v: 1,
                type: "ack",
                sessionID: sessionID,
                ackSeq: accepted.seq,
                frameID: accepted.frameID,
                documentHeads: sync.convergedHeads
            ),
            restart: .init(
                newSessionID: "d1d1d1d1-d1d1-41d1-81d1-d1d1d1d1d1d1",
                discardsPriorFrameID: accepted.frameID.uuidString.lowercased(),
                requiresFreshFrameID: true,
                requiresFreshSyncState: true
            )
        )
    }

    private func loadSourceFixture() throws -> SourceFixture {
        try JSONDecoder().decode(SourceFixture.self, from: loadSourceFixtureData())
    }

    private func loadSourceFixtureData() throws -> Data {
        try loadFixtureData(named: "automerge-sync-v1")
    }

    private func loadFixtureData(named name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(
                    forResource: name,
                    withExtension: "json",
                    subdirectory: "Fixtures"
                )
        )
        return try Data(contentsOf: url)
    }

    private func unwrapBase64URL(_ value: String) throws -> Data {
        try XCTUnwrap(Data(base64URLString: value))
    }

    private static let authoredAtUnixSeconds: Int64 = 1_700_000_000
    private static let clientReplicaID = UUID(
        uuidString: "33333333-3333-4333-8333-333333333333"
    )!
    private static let serverReplicaID = UUID(
        uuidString: "44444444-4444-4444-8444-444444444444"
    )!
    private static let unicodeMemo = "👩‍👩‍👧‍👦🏳️‍🌈日本語 é "
    private static let javaScriptResponsePayloads = [
        "QwH5AY1Gf7yshG9qDkXtqyyU_BtCrXdzVPc899mwYqMeFgHO6Bw85e_zO6IwGw_4Su5JN3HMDFdSmZHm8MLdXrDvmQEABQEKB1iHAAIChA",
        "QwHO6Bw85e_zO6IwGw_4Su5JN3HMDFdSmZHm8MLdXrDvmQABAc7oHDzl7_M7ojAbD_hK7kk3ccwMV1KZkebwwt1esO-ZAAACAoQ",
    ]
    private static let javaScriptConvergedHeads = [
        "cee81c3ce5eff33ba2301b0ff84aee493771cc0c57529991e6f0c2dd5eb0ef99",
    ]
}

private struct SourceFixture: Decodable {
    let planID: String
    let comiketNo: Int
    let bootstrap: SwiftDocumentFixture
    let nestedParentResolutionVectors: [SourceResolverVector]
}

private struct SourceResolverVector: Decodable {
    let scenario: String
    let kind: String
    let beforeDocument: String
    let operation: SourceOperation
}

private struct SourceOperation: Decodable {
    let type: SharedPlanOperationType
    let payload: [String: SharedPlanJSONValue]
}

private struct SwiftAuthoredFixture: Codable {
    let fixtureVersion: Int
    let producer: SwiftFixtureProducer
    let sourceFixtureSHA256: String
    let planID: String
    let comiketNo: Int
    let replicaID: String
    let actorID: String
    let authoredAtUnixSeconds: Int64
    let bootstrap: SwiftDocumentFixture
    let operationVectors: [SwiftAuthoredOperationVector]
    let resolverVectors: [SwiftAuthoredOperationVector]
    let unicode: SwiftUnicodeFixture
    let swiftSync: SwiftSyncDialogue
    let javascriptSync: JavaScriptSyncHandoff
    let transportReceipts: SwiftTransportReceipts
}

private struct SwiftNamedNeedFixture: Codable {
    let fixtureVersion: Int
    let planID: String
    let comiketNo: Int
    let replicaID: String
    let actorID: String
    let userPublicID: String
    let vector: SwiftAuthoredOperationVector
}

private struct SwiftFixtureProducer: Codable {
    let package: String
    let version: String
    let runtime: String
}

private struct SwiftDocumentFixture: Codable {
    let document: String
    let heads: [String]
}

private struct SwiftAuthoredOperationVector: Codable {
    let scenario: String?
    let kind: String?
    let operationID: String
    let operation: SwiftOperationFixture
    let beforeDocument: String
    let beforeHeads: [String]
    let change: String
    let changeHash: String
    let changeActorID: String
    let changeMessage: String?
    let changeTimestampUnixSeconds: Int64
    let afterDocument: String
    let afterHeads: [String]
}

private struct SwiftOperationFixture: Codable {
    let type: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
}

private struct SwiftUnicodeFixture: Codable {
    let memo: String
    let unicodeScalarCount: Int
    let utf8ByteCount: Int
    let memoOperationID: String
}

private struct SwiftSyncDialogue: Codable {
    let sessionID: String
    let serverBeforeDocument: String
    let clientBeforeDocument: String
    let clientToServerPayloads: [String]
    let serverToClientPayloads: [String]
    let serverAfterDocument: String
    let clientAfterDocument: String
    let convergedHeads: [String]
}

private struct JavaScriptSyncHandoff: Codable {
    let beforeDocument: String
    let clientDocument: String
    let clientToServerPayloads: [String]
    let responsePayloads: [String]
    let serverDocument: String
    let convergedDocument: String
    let convergedHeads: [String]
    let status: String
}

private struct SwiftTransportReceipts: Codable {
    let acceptedEnvelope: SharedPlanClientSyncFrame
    let exactDuplicateEnvelope: SharedPlanClientSyncFrame
    let receiptViolationEnvelope: SharedPlanClientSyncFrame
    let sequenceGapEnvelope: SharedPlanClientSyncFrame
    let acknowledgement: SharedPlanSyncAcknowledgement
    let restart: SwiftRestartFixture
}

private struct SwiftRestartFixture: Codable {
    let newSessionID: String
    let discardsPriorFrameID: String
    let requiresFreshFrameID: Bool
    let requiresFreshSyncState: Bool
}

private extension Dictionary where Key == String, Value == SharedPlanJSONValue {
    func requiredValue(_ key: String) throws -> SharedPlanJSONValue {
        guard let value = self[key] else { throw SharedPlanError.syncProtocolViolation }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        try requiredValue(key).requiredString()
    }

    func requiredInteger(_ key: String) throws -> Int64 {
        guard case let .integer(value) = try requiredValue(key) else {
            throw SharedPlanError.syncProtocolViolation
        }
        return value
    }

    func requiredArray(_ key: String) throws -> [SharedPlanJSONValue] {
        guard case let .array(value) = try requiredValue(key) else {
            throw SharedPlanError.syncProtocolViolation
        }
        return value
    }
}

private extension SharedPlanJSONValue {
    func requiredString() throws -> String {
        guard case let .string(value) = self else {
            throw SharedPlanError.syncProtocolViolation
        }
        return value
    }

    func requiredObject() throws -> [String: SharedPlanJSONValue] {
        guard case let .object(value) = self else {
            throw SharedPlanError.syncProtocolViolation
        }
        return value
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
