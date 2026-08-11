@testable import ComiNavi
import Automerge
import Foundation
import XCTest

final class SharedPlanOperationMessageIndexTests: XCTestCase {
    func testCanonicalNilMessageBootstrapIsAccepted() async throws {
        let document = try SharedPlanAutomergeDocument(
            data: forgedBootstrap(message: nil, forgery: .none),
            replicaID: Self.readerReplicaID
        )
        let records = try await document.operationRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testOperationMessageCannotMasqueradeAsBootstrap() throws {
        assertBootstrapRejected(try forgedBootstrap(
            message: semanticMessage(Self.operationID),
            forgery: .none
        ))
    }

    func testBootstrapCannotPreseedCircleContent() throws {
        assertBootstrapRejected(try forgedBootstrap(
            message: nil,
            forgery: .preseededCircle
        ))
    }

    func testBootstrapCannotAddRootKeys() throws {
        assertBootstrapRejected(try forgedBootstrap(
            message: nil,
            forgery: .extraRootKey
        ))
    }

    func testConcurrentBootstrapRootObjectsFailClosed() throws {
        let left = try Document(
            forgedBootstrap(
                message: nil,
                forgery: .none,
                actorID: Self.writerReplicaID
            )
        )
        let right = try Document(
            forgedBootstrap(
                message: nil,
                forgery: .none,
                actorID: Self.concurrentWriterReplicaID
            )
        )
        try left.merge(other: right)
        assertBootstrapRejected(left.save())
    }

    func testDurableReceiveRejectsSwappedMessagesBeforePersistence() async throws {
        let second = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        try await assertDurableReceiveRejects { document, _, operations in
            try self.appendOperation(Self.operationID, to: operations, in: document)
            document.commitWith(
                message: self.semanticMessage(second),
                timestamp: Date(timeIntervalSince1970: 1_730_100_000)
            )
            try self.appendOperation(second, to: operations, in: document)
            document.commitWith(
                message: self.semanticMessage(Self.operationID),
                timestamp: Date(timeIntervalSince1970: 1_730_100_001)
            )
        }
    }

    func testDurableReceiveRejectsUnmessagedInsertionAndLateClaim() async throws {
        try await assertDurableReceiveRejects { document, _, operations in
            let operation = try self.appendOperation(
                Self.operationID,
                to: operations,
                in: document
            )
            document.commitWith(
                message: nil,
                timestamp: Date(timeIntervalSince1970: 1_730_100_010)
            )
            try document.put(obj: operation, key: "lateProbe", value: .Int(1))
            document.commitWith(
                message: self.semanticMessage(Self.operationID),
                timestamp: Date(timeIntervalSince1970: 1_730_100_011)
            )
        }
    }

    func testDurableReceiveRejectsContentOnlyCanonicalChange() async throws {
        try await assertDurableReceiveRejects { document, circles, _ in
            _ = try document.putObject(obj: circles, key: "9001", ty: .Map)
            document.commitWith(
                message: self.semanticMessage(Self.operationID),
                timestamp: Date(timeIntervalSince1970: 1_730_100_020)
            )
        }
    }

    func testDurableReceiveRejectsNestedUUIDMapPutAsOperationInsertion() async throws {
        try await assertDurableReceiveRejects { document, circles, _ in
            let circle = try document.putObject(
                obj: circles,
                key: "9001",
                ty: .Map
            )
            _ = try document.putObject(
                obj: circle,
                key: Self.operationID.uuidString.lowercased(),
                ty: .Map
            )
            document.commitWith(
                message: self.semanticMessage(Self.operationID),
                timestamp: Date(timeIntervalSince1970: 1_730_100_025)
            )
        }
    }

    func testDurableReceiveRejectsRootMutationWithValidOperation() async throws {
        try await assertDurableReceiveRejects { document, _, operations in
            try self.appendOperation(Self.operationID, to: operations, in: document)
            try document.put(obj: .ROOT, key: "unexpected", value: .Int(1))
            document.commitWith(
                message: self.semanticMessage(Self.operationID),
                timestamp: Date(timeIntervalSince1970: 1_730_100_030)
            )
        }
    }

    func testExactCanonicalOperationMessageIndexesSemanticChange() async throws {
        let operationID = Self.operationID
        let bytes = try authoredDocument(
            message: semanticMessage(operationID),
            operationID: operationID
        )
        let document = try SharedPlanAutomergeDocument(
            data: bytes,
            replicaID: Self.readerReplicaID
        )

        let records = try await document.operationRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, operationID)
        XCTAssertNotNil(records[0].changeHash)
    }

    func testSemanticIndexSurvivesActorTableReindexingInBothDirections() async throws {
        let bootstrapReplicaID = UUID(
            uuidString: "22222222-2222-4222-8222-222222222222"
        )!
        let seed = try SharedPlanAutomergeDocument(
            fixturePlanID: Self.bootstrapPlanID,
            comiketNo: 108,
            replicaID: bootstrapReplicaID
        )
        let bootstrap = await seed.save()
        let actorCases: [(replicaID: UUID, operationID: UUID, wcID: Int)] = [
            (
                UUID(uuidString: "01f9af86-e16e-45f4-abcc-4d50b00fa65d")!,
                UUID(uuidString: "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                81
            ),
            (
                UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                UUID(uuidString: "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
                82
            ),
        ]

        for actorCase in actorCases {
            let document = try SharedPlanAutomergeDocument(
                data: bootstrap,
                replicaID: actorCase.replicaID
            )
            let key = try XCTUnwrap(
                SharedPlanCircleKey(comiketNo: 108, wcID: actorCase.wcID)
            )
            _ = try await document.addCircle(
                key,
                operationID: actorCase.operationID,
                actorUserID: Self.actorUserID,
                authoredAt: Date(timeIntervalSince1970: 1_730_000_000)
            )

            let records = try await document.operationRecords()
            XCTAssertEqual(records.map(\.id), [actorCase.operationID])
            XCTAssertNotNil(records[0].changeHash)
        }
    }

    func testMissingOperationMessageFailsClosed() async throws {
        await assertMalformedHistory(try authoredDocument(
                message: "Set circle presence",
                operationID: Self.operationID
            ))
    }

    func testMalformedOrUppercaseOperationMessageFailsClosed() async throws {
        for message in [
            "operation:not-a-uuid",
            "operation:\(Self.operationID.uuidString)",
        ] {
            await assertMalformedHistory(
                try authoredDocument(
                    message: message,
                    operationID: Self.operationID
                ),
                message
            )
        }
    }

    func testDuplicateOperationMessageFailsClosed() async throws {
        let bytes = try authoredDocument(
            message: semanticMessage(Self.operationID),
            operationID: Self.operationID,
            trailingMessage: semanticMessage(Self.operationID)
        )
        await assertMalformedHistory(bytes)
    }

    func testExtraOperationMessageFailsClosed() async throws {
        let extra = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let bytes = try authoredDocument(
            message: semanticMessage(Self.operationID),
            operationID: Self.operationID,
            trailingMessage: semanticMessage(extra)
        )
        await assertMalformedHistory(bytes)
    }

    func testSwappedCanonicalMessagesCannotClaimAnotherChangesOperation() async throws {
        let second = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let document = try SharedPlanAutomergeDocument(
            data: misattributedDocument(
                firstOperationID: Self.operationID,
                firstMessage: semanticMessage(second),
                secondOperationID: second,
                secondMessage: semanticMessage(Self.operationID)
            ),
            replicaID: Self.readerReplicaID
        )
        await assertProtocolViolation(document)
    }

    func testProseInsertionCannotBeClaimedByLaterUnrelatedMessage() async throws {
        await assertMalformedHistory(try misattributedDocument(
                firstOperationID: Self.operationID,
                firstMessage: "Set circle presence",
                secondOperationID: nil,
                secondMessage: semanticMessage(Self.operationID)
            ))
    }

    private func authoredDocument(
        message: String,
        operationID: UUID,
        trailingMessage: String? = nil
    ) throws -> Data {
        let fixture = try loadSourceFixture()
        let document = try Document(
            try XCTUnwrap(Data(base64URLString: fixture.bootstrap.document))
        )
        document.actor = ActorId(uuid: Self.writerReplicaID)
        guard case let .Object(operations, .Map) = try document.get(
            obj: .ROOT,
            key: "operations"
        ) else {
            throw SharedPlanError.syncProtocolViolation
        }

        try appendOperation(operationID, to: operations, in: document)
        document.commitWith(message: message, timestamp: Date(timeIntervalSince1970: 1_730_000_000))

        if let trailingMessage {
            try document.put(obj: .ROOT, key: "messageIndexProbe", value: .Int(1))
            document.commitWith(
                message: trailingMessage,
                timestamp: Date(timeIntervalSince1970: 1_730_000_001)
            )
        }
        return document.save()
    }

    private enum BootstrapForgery {
        case none
        case preseededCircle
        case extraRootKey
    }

    private func forgedBootstrap(
        message: String?,
        forgery: BootstrapForgery,
        actorID: UUID? = nil
    ) throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        document.actor = ActorId(uuid: actorID ?? Self.writerReplicaID)
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Int(1))
        try document.put(
            obj: .ROOT,
            key: "planID",
            value: .String(Self.bootstrapPlanID)
        )
        try document.put(obj: .ROOT, key: "comiketNo", value: .Int(108))
        let circles = try document.putObject(
            obj: .ROOT,
            key: "circles",
            ty: .Map
        )
        _ = try document.putObject(
            obj: .ROOT,
            key: "operations",
            ty: .Map
        )
        switch forgery {
        case .none:
            break
        case .preseededCircle:
            _ = try document.putObject(obj: circles, key: "9001", ty: .Map)
        case .extraRootKey:
            try document.put(obj: .ROOT, key: "unexpected", value: .Int(1))
        }
        document.commitWith(
            message: message,
            timestamp: Date(timeIntervalSince1970: 1_729_000_000)
        )
        return document.save()
    }

    private func assertBootstrapRejected(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SharedPlanAutomergeDocument(
                data: data,
                replicaID: Self.readerReplicaID
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SharedPlanError,
                .syncProtocolViolation,
                file: file,
                line: line
            )
        }
    }

    private func misattributedDocument(
        firstOperationID: UUID,
        firstMessage: String,
        secondOperationID: UUID?,
        secondMessage: String
    ) throws -> Data {
        let fixture = try loadSourceFixture()
        let document = try Document(
            try XCTUnwrap(Data(base64URLString: fixture.bootstrap.document))
        )
        document.actor = ActorId(uuid: Self.writerReplicaID)
        guard case let .Object(operations, .Map) = try document.get(
            obj: .ROOT,
            key: "operations"
        ) else { throw SharedPlanError.syncProtocolViolation }

        try appendOperation(firstOperationID, to: operations, in: document)
        document.commitWith(
            message: firstMessage,
            timestamp: Date(timeIntervalSince1970: 1_730_000_010)
        )
        if let secondOperationID {
            try appendOperation(secondOperationID, to: operations, in: document)
        } else {
            try document.put(obj: .ROOT, key: "messageIndexProbe", value: .Int(1))
        }
        document.commitWith(
            message: secondMessage,
            timestamp: Date(timeIntervalSince1970: 1_730_000_011)
        )
        return document.save()
    }

    @discardableResult
    private func appendOperation(
        _ operationID: UUID,
        to operations: ObjId,
        in document: Document
    ) throws -> ObjId {
        let operation = try document.putObject(
            obj: operations,
            key: operationID.uuidString.lowercased(),
            ty: .Map
        )
        try putText(
            "shared_plan.circle.presence.v1",
            in: operation,
            key: "type",
            document: document
        )
        try putText(Self.actorUserID, in: operation, key: "actorUserID", document: document)
        let payload = try document.putObject(obj: operation, key: "payload", ty: .Map)
        try document.put(obj: payload, key: "v", value: .Int(1))
        try document.put(obj: payload, key: "wcID", value: .Int(9_001))
        try putText("active", in: payload, key: "state", document: document)
        return operation
    }

    private func assertDurableReceiveRejects(
        _ mutate: (Document, ObjId, ObjId) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try loadSourceFixture()
        let bootstrap = try XCTUnwrap(
            Data(base64URLString: fixture.bootstrap.document)
        )
        let client = try SharedPlanAutomergeDocument(
            data: bootstrap,
            replicaID: Self.readerReplicaID
        )
        let peer = try Document(bootstrap)
        peer.actor = ActorId(uuid: Self.writerReplicaID)
        guard case let .Object(circles, .Map) = try peer.get(
            obj: .ROOT,
            key: "circles"
        ), case let .Object(operations, .Map) = try peer.get(
            obj: .ROOT,
            key: "operations"
        ) else { throw SharedPlanError.syncProtocolViolation }
        try mutate(peer, circles, operations)

        let sessionID = UUID()
        await client.beginSyncSession(id: sessionID)
        let savedBefore = await client.save()
        let headsBefore = await client.heads()
        let peerState = SyncState()
        let generatedGreeting = try await client.generateSyncMessage(
            sessionID: sessionID
        )
        let greeting = try XCTUnwrap(generatedGreeting)
        try peer.receiveSyncMessage(state: peerState, message: greeting)
        let maliciousMessage = try XCTUnwrap(
            peer.generateSyncMessage(state: peerState)
        )
        let recorder = DurableReceivePersistRecorder()

        do {
            try await client.receiveSyncMessageDurably(
                sessionID: sessionID,
                message: maliciousMessage,
                pendingOperationIDs: [],
                syncIssue: nil,
                localEditLimit: nil
            ) { _, _ in
                await recorder.record()
            }
            XCTFail("Malformed sync message was durably accepted", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .syncProtocolViolation,
                file: file,
                line: line
            )
        }

        let persistCount = await recorder.count
        let savedAfter = await client.save()
        let headsAfter = await client.heads()
        XCTAssertEqual(persistCount, 0, file: file, line: line)
        XCTAssertEqual(savedAfter, savedBefore, file: file, line: line)
        XCTAssertEqual(headsAfter, headsBefore, file: file, line: line)
        do {
            _ = try await client.generateSyncMessage(sessionID: sessionID)
            XCTFail("Rejected session state remained usable", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .syncProtocolViolation,
                file: file,
                line: line
            )
        }
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

    private func assertProtocolViolation(
        _ document: SharedPlanAutomergeDocument,
        _ context: String = ""
    ) async {
        do {
            _ = try await document.operationRecords()
            XCTFail("Malformed operation message was accepted: \(context)")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation, context)
        }
    }

    private func assertMalformedHistory(
        _ data: Data,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let document = try SharedPlanAutomergeDocument(
                data: data,
                replicaID: Self.readerReplicaID
            )
            await assertProtocolViolation(document, context)
        } catch {
            XCTAssertEqual(
                error as? SharedPlanError,
                .syncProtocolViolation,
                context,
                file: file,
                line: line
            )
        }
    }

    private func loadSourceFixture() throws -> SourceFixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "automerge-sync-v1",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(SourceFixture.self, from: Data(contentsOf: url))
    }

    private func semanticMessage(_ operationID: UUID) -> String {
        "operation:\(operationID.uuidString.lowercased())"
    }

    private static let operationID = UUID(
        uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    )!
    private static let writerReplicaID = UUID(
        uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    )!
    private static let readerReplicaID = UUID(
        uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    )!
    private static let concurrentWriterReplicaID = UUID(
        uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    )!
    private static let bootstrapPlanID = "11111111-1111-4111-8111-111111111111"
    private static let actorUserID = "0123456789abcdef0123456789abcdef"
}

private struct SourceFixture: Decodable {
    let bootstrap: SourceBootstrap
}

private struct SourceBootstrap: Decodable {
    let document: String
}

private actor DurableReceivePersistRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
