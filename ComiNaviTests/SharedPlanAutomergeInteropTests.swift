@testable import ComiNavi
import Foundation
import XCTest

final class SharedPlanAutomergeInteropTests: XCTestCase {
    func testLiteralJavaScriptBootstrapLoadsWithCanonicalRootMetadata() async throws {
        let fixture = try loadFixture()
        let bootstrap = try XCTUnwrap(Data(base64URLString: fixture.bootstrap.document))
        let document = try SharedPlanAutomergeDocument(
            data: bootstrap,
            replicaID: Self.replicaID
        )

        XCTAssertEqual(document.planID, fixture.planID)
        XCTAssertEqual(document.comiketNo, fixture.comiketNo)
        let heads = await document.heads()
        let saved = await document.save()
        let operationIDs = await document.semanticOperationIDs()
        let hasRootConflict = try await document.hasConcurrentRootObjects()
        XCTAssertEqual(heads, fixture.bootstrap.heads)
        XCTAssertEqual(saved, bootstrap)
        XCTAssertTrue(operationIDs.isEmpty)
        XCTAssertFalse(hasRootConflict)
    }

    func testEveryLiteralJavaScriptBaseOperationAppliesAndDecodesExactly() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.operationExamples.count, 8)
        XCTAssertEqual(fixture.operationVectors.count, 8)

        for vector in fixture.operationVectors {
            let before = try XCTUnwrap(Data(base64URLString: vector.beforeDocument))
            let change = try XCTUnwrap(Data(base64URLString: vector.change))
            let after = try XCTUnwrap(Data(base64URLString: vector.afterDocument))
            let document = try SharedPlanAutomergeDocument(
                data: before,
                replicaID: Self.replicaID
            )

            let beforeHeads = await document.heads()
            XCTAssertEqual(beforeHeads, vector.beforeHeads, vector.operationID)
            try await document.applyEncodedChanges(change)
            let afterHeads = await document.heads()
            XCTAssertEqual(afterHeads, vector.afterHeads, vector.operationID)
            let fixtureAfter = try SharedPlanAutomergeDocument(
                data: after,
                replicaID: Self.replicaID
            )
            let fixtureAfterHeads = await fixtureAfter.heads()
            XCTAssertEqual(fixtureAfterHeads, afterHeads, vector.operationID)

            let operationID = try XCTUnwrap(UUID(uuidString: vector.operationID))
            let records = try await document.operationRecords()
            let record = try XCTUnwrap(records.first(where: { $0.id == operationID }))
            XCTAssertEqual(record.type, vector.operation.type, vector.operationID)
            XCTAssertEqual(record.actorUserID, vector.operation.actorUserID, vector.operationID)
            XCTAssertEqual(record.payload, vector.operation.payload, vector.operationID)
            XCTAssertEqual(
                record.changeHash,
                vector.afterHeads.count == 1 ? vector.afterHeads[0] : nil,
                vector.operationID
            )
        }
    }

    func testLiteralMemoVectorUsesUnicodeScalarIndicesAndText() async throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(
            fixture.operationVectors.first(where: {
                $0.operation.type == .circleMemoSplice
            })
        )
        let document = try SharedPlanAutomergeDocument(
            data: try XCTUnwrap(Data(base64URLString: vector.afterDocument)),
            replicaID: Self.replicaID
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: 9_001))

        let memo = try await document.memo(for: key)
        XCTAssertEqual(memo, "日本語 é ")
        XCTAssertEqual("日本語 é ".unicodeScalars.count, 7)
    }

    func testEveryLiteralParentResolutionAppliesAndDecodesExactly() async throws {
        let fixture = try loadFixture()
        let vectors = fixture.parentResolutionVectors + fixture.nestedParentResolutionVectors
        XCTAssertEqual(vectors.count, 6)

        for vector in vectors {
            let context = vector.scenario.map { "\(vector.operationID) [\($0)]" }
                ?? vector.operationID
            let document = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.beforeDocument, context: context),
                replicaID: Self.replicaID
            )

            let beforeHeads = await document.heads()
            XCTAssertEqual(beforeHeads, vector.beforeHeads, context)
            try await document.applyEncodedChanges(
                decodeBase64URL(vector.change, context: context)
            )
            let afterHeads = await document.heads()
            XCTAssertEqual(afterHeads, vector.afterHeads, context)

            let fixtureAfter = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.afterDocument, context: context),
                replicaID: Self.replicaID
            )
            let fixtureAfterHeads = await fixtureAfter.heads()
            XCTAssertEqual(fixtureAfterHeads, afterHeads, context)

            let operationID = try XCTUnwrap(UUID(uuidString: vector.operationID), context)
            let records = try await document.operationRecords()
            let record = try XCTUnwrap(
                records.first(where: { $0.id == operationID }),
                context
            )
            XCTAssertEqual(record.type, vector.operation.type, context)
            XCTAssertEqual(record.actorUserID, vector.operation.actorUserID, context)
            XCTAssertEqual(record.payload, vector.operation.payload, context)
            XCTAssertFalse(vector.beforeConflicts.isEmpty, context)
            XCTAssertTrue(vector.afterConflicts.isEmpty, context)
        }
    }

    func testProductionConflictInventoryMatchesEveryLiteralConflictVector() async throws {
        let fixture = try loadFixture()
        for vector in fixture.parentResolutionVectors + fixture.nestedParentResolutionVectors {
            let context = vector.scenario ?? vector.operationID
            let document = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.beforeDocument, context: context),
                replicaID: Self.replicaID
            )
            let inventory = try await document.conflictInventory()
            let projected = inventory.map {
                SharedPlanConflict(
                    conflictID: $0.conflictID,
                    path: $0.path,
                    changeHashes: $0.changeHashes
                )
            }
            XCTAssertEqual(projected, vector.beforeConflicts, context)

            let selectedRaw = try XCTUnwrap(
                vector.operation.payload["selectedParentOperationID"]?.stringValue,
                context
            )
            let selected = try XCTUnwrap(UUID(uuidString: selectedRaw), context)
            let wcID = try XCTUnwrap(
                Int(exactly: try XCTUnwrap(
                    vector.operation.payload["wcID"]?.integerValue,
                    context
                )),
                context
            )
            let circle = try XCTUnwrap(
                SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: wcID),
                context
            )
            let parentInventory: SharedPlanParentResolutionInventory
            switch vector.operation.type {
            case .circleResolveParent:
                parentInventory = try await document.circleParentResolutionInventory(
                    circle,
                    selectedParentOperationID: selected
                )
            case .needResolveParent:
                let rawNeedID = try XCTUnwrap(
                    vector.operation.payload["needID"]?.stringValue,
                    context
                )
                parentInventory = try await document.needParentResolutionInventory(
                    try XCTUnwrap(UUID(uuidString: rawNeedID), context),
                    circle: circle,
                    selectedParentOperationID: selected
                )
            default:
                XCTFail("Unexpected resolver type: \(context)")
                continue
            }
            let expectedNested = try XCTUnwrap(
                vector.operation.payload["nestedResolutions"]?.arrayValue,
                context
            ).compactMap(\.objectValue)
            XCTAssertEqual(
                parentInventory.requiredNestedConflicts.map(\.conflictID).sorted(),
                expectedNested.compactMap { $0["conflictID"]?.stringValue }.sorted(),
                context
            )
            for expected in expectedNested {
                let conflictID = try XCTUnwrap(expected["conflictID"]?.stringValue, context)
                let selectedHash = try XCTUnwrap(
                    expected["selectedChangeHash"]?.stringValue,
                    context
                )
                let value = try XCTUnwrap(expected["value"], context)
                let conflict = try XCTUnwrap(
                    parentInventory.requiredNestedConflicts.first {
                        $0.conflictID == conflictID
                    },
                    context
                )
                XCTAssertTrue(
                    conflict.candidates.contains {
                        $0.changeHash == selectedHash && $0.value == value
                    },
                    "\(context): expected \(selectedHash)=\(value), candidates=\(conflict.candidates)"
                )
            }
        }

        for vector in fixture.semanticConflictVectors {
            let context = "\(vector.kind):\(vector.descendantOperationType.rawValue)"
            for order in [
                [vector.removalChange, vector.descendantChange],
                [vector.descendantChange, vector.removalChange],
            ] {
                let document = try SharedPlanAutomergeDocument(
                    data: try decodeBase64URL(vector.baseDocument, context: context),
                    replicaID: Self.replicaID
                )
                for change in order {
                    try await document.applyEncodedChanges(
                        decodeBase64URL(change, context: context)
                    )
                }
                let inventory = try await document.conflictInventory()
                let projected = inventory.map {
                    SharedPlanConflict(
                        conflictID: $0.conflictID,
                        path: $0.path,
                        changeHashes: $0.changeHashes
                    )
                }
                XCTAssertEqual(projected, vector.conflicts, context)

                let restarted = try SharedPlanAutomergeDocument(
                    data: await document.save(),
                    replicaID: Self.serverReplicaID
                )
                let restartedInventory = try await restarted.conflictInventory()
                XCTAssertEqual(
                    restartedInventory,
                    inventory,
                    context
                )
            }
        }
    }

    func testParentResolverRejectsIncompleteOrUnprovenNestedChoicesBeforeMutation() async throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(
            fixture.nestedParentResolutionVectors.first(where: {
                $0.scenario == "nested-scalar"
                    && $0.operation.type == .circleResolveParent
            })
        )
        let payload = vector.operation.payload
        let wcID = try XCTUnwrap(Int(exactly: try XCTUnwrap(payload["wcID"]?.integerValue)))
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: wcID)
        )
        let selected = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(payload["selectedParentOperationID"]?.stringValue))
        )
        let state = try XCTUnwrap(
            SharedPlanPresenceState(
                rawValue: try XCTUnwrap(payload["state"]?.stringValue)
            )
        )
        let originalObject = try XCTUnwrap(
            try XCTUnwrap(payload["nestedResolutions"]?.arrayValue).first?.objectValue
        )
        let original = SharedPlanNestedConflictResolution(
            conflictID: try XCTUnwrap(originalObject["conflictID"]?.stringValue),
            path: try XCTUnwrap(originalObject["path"]?.arrayValue).map {
                try XCTUnwrap($0.stringValue)
            },
            selectedChangeHash: try XCTUnwrap(
                originalObject["selectedChangeHash"]?.stringValue
            ),
            value: try XCTUnwrap(originalObject["value"])
        )
        let invalidCases: [[SharedPlanNestedConflictResolution]] = [
            [],
            [original, original],
            [SharedPlanNestedConflictResolution(
                conflictID: String(repeating: "0", count: 64),
                path: original.path,
                selectedChangeHash: original.selectedChangeHash,
                value: original.value
            )],
            [SharedPlanNestedConflictResolution(
                conflictID: original.conflictID,
                path: original.path + ["extra"],
                selectedChangeHash: original.selectedChangeHash,
                value: original.value
            )],
            [SharedPlanNestedConflictResolution(
                conflictID: original.conflictID,
                path: original.path,
                selectedChangeHash: String(repeating: "0", count: 64),
                value: original.value
            )],
            [SharedPlanNestedConflictResolution(
                conflictID: original.conflictID,
                path: original.path,
                selectedChangeHash: original.selectedChangeHash,
                value: .string("選択できない値")
            )],
        ]

        for (index, invalid) in invalidCases.enumerated() {
            let document = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.beforeDocument, context: "case \(index)"),
                replicaID: Self.replicaID
            )
            let before = await document.save()
            do {
                _ = try await document.resolveCircleParent(
                    circle,
                    selectedParentOperationID: selected,
                    state: state,
                    nestedResolutions: invalid,
                    operationID: UUID(),
                    actorUserID: vector.operation.actorUserID,
                    authoredAt: Date(timeIntervalSince1970: 1_700_001_000),
                    allowingDurableMutation: true
                )
                XCTFail("Invalid resolver case \(index) was accepted")
            } catch {
                XCTAssertEqual(
                    error as? SharedPlanError,
                    .syncProtocolViolation,
                    "case \(index)"
                )
            }
            let after = await document.save()
            XCTAssertEqual(after, before, "case \(index)")
        }
    }

    func testEveryLiteralRemovalConflictConvergesInEitherArrivalOrder() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.semanticConflictVectors.count, 10)

        for vector in fixture.semanticConflictVectors {
            let context = "\(vector.kind):\(vector.descendantOperationType.rawValue)"
            let base = try decodeBase64URL(vector.baseDocument, context: context)
            let removal = try decodeBase64URL(vector.removalChange, context: context)
            let descendant = try decodeBase64URL(vector.descendantChange, context: context)

            let removalFirst = try SharedPlanAutomergeDocument(
                data: base,
                replicaID: Self.replicaID
            )
            try await removalFirst.applyEncodedChanges(removal)
            try await removalFirst.applyEncodedChanges(descendant)
            let removalFirstHeads = await removalFirst.heads()

            let descendantFirst = try SharedPlanAutomergeDocument(
                data: base,
                replicaID: Self.replicaID
            )
            try await descendantFirst.applyEncodedChanges(descendant)
            try await descendantFirst.applyEncodedChanges(removal)
            let descendantFirstHeads = await descendantFirst.heads()

            let fixtureMerged = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.mergedDocument, context: context),
                replicaID: Self.replicaID
            )
            let fixtureHeads = await fixtureMerged.heads()
            XCTAssertEqual(removalFirstHeads, vector.mergedHeads, context)
            XCTAssertEqual(descendantFirstHeads, vector.mergedHeads, context)
            XCTAssertEqual(fixtureHeads, vector.mergedHeads, context)
            XCTAssertFalse(vector.conflicts.isEmpty, context)

            let records = try await removalFirst.operationRecords()
            XCTAssertTrue(
                records.contains(where: { $0.type == vector.descendantOperationType }),
                context
            )
        }
    }

    func testEveryLiteralRemovalConflictSupportsBothExplicitPresenceChoices() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.semanticConflictVectors.count, 10)

        for (vectorIndex, vector) in fixture.semanticConflictVectors.enumerated() {
            let path = try XCTUnwrap(vector.conflicts.only?.path)
            let wcID = try XCTUnwrap(Int(path[1]))
            let circle = try XCTUnwrap(
                SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: wcID)
            )
            for (orderIndex, order) in [
                [vector.removalChange, vector.descendantChange],
                [vector.descendantChange, vector.removalChange],
            ].enumerated() {
                for (choiceIndex, choice) in [
                    SharedPlanPresenceState.active,
                    .removed,
                ].enumerated() {
                    let context = [
                        vector.kind,
                        vector.descendantOperationType.rawValue,
                        "order-\(orderIndex)",
                        choice.rawValue,
                    ].joined(separator: ":")
                    let document = try SharedPlanAutomergeDocument(
                        data: try decodeBase64URL(vector.baseDocument, context: context),
                        replicaID: Self.replicaID
                    )
                    for change in order {
                        try await document.applyEncodedChanges(
                            decodeBase64URL(change, context: context)
                        )
                    }
                    let beforeInventory = try await document.conflictInventory()
                    XCTAssertEqual(beforeInventory.count, 1, context)
                    XCTAssertEqual(beforeInventory[0].kind, .removalVersusEdit, context)
                    XCTAssertEqual(beforeInventory[0].path, path, context)
                    let beforeSave = await document.save()
                    let beforeHistoryCount = await document.historyCount()
                    let beforeCircle = try await document.circleContent(for: circle)

                    let operationID = try XCTUnwrap(
                        UUID(uuidString: String(
                            format: "90909090-9090-4090-8090-%012x",
                            vectorIndex * 4 + orderIndex * 2 + choiceIndex + 1
                        )),
                        context
                    )
                    let expectedType: SharedPlanOperationType
                    if vector.kind == "circle-removal" {
                        expectedType = .circlePresence
                        let didResolve = try await document.setCirclePresence(
                            choice,
                            for: circle,
                            operationID: operationID,
                            actorUserID: Self.actorUserID,
                            authoredAt: Date(timeIntervalSince1970: 1_740_000_000)
                        )
                        XCTAssertTrue(didResolve, context)
                    } else {
                        let needID = try XCTUnwrap(UUID(uuidString: path[3]), context)
                        let storedNeed = try await document.purchaseNeed(
                            id: needID,
                            circleKey: circle
                        )
                        let retainedNeed = try XCTUnwrap(storedNeed, context)
                        if choice == .active {
                            expectedType = .needCreate
                            let didResolve = try await document.createNeed(
                                retainedNeed,
                                for: circle,
                                operationID: operationID,
                                actorUserID: Self.actorUserID,
                                authoredAt: Date(timeIntervalSince1970: 1_740_000_000)
                            )
                            XCTAssertTrue(didResolve, context)
                        } else {
                            expectedType = .needDelete
                            let didResolve = try await document.deleteNeed(
                                needID,
                                for: circle,
                                operationID: operationID,
                                actorUserID: Self.actorUserID,
                                authoredAt: Date(timeIntervalSince1970: 1_740_000_000)
                            )
                            XCTAssertTrue(didResolve, context)
                        }
                        let afterNeed = try await document.purchaseNeed(
                            id: needID,
                            circleKey: circle
                        )
                        XCTAssertEqual(
                            afterNeed,
                            retainedNeed,
                            "\(context): descendant need data changed"
                        )
                    }

                    let changes = try await document.encodedChanges(
                        sinceHistoryIndex: beforeHistoryCount
                    )
                    let change = try XCTUnwrap(changes.only, context)
                    XCTAssertEqual(
                        change.message,
                        "operation:\(operationID.uuidString.lowercased())",
                        context
                    )
                    let records = try await document.operationRecords()
                    let record = try XCTUnwrap(
                        records.first { $0.id == operationID },
                        context
                    )
                    XCTAssertEqual(record.type, expectedType, context)
                    let afterInventory = try await document.conflictInventory()
                    XCTAssertTrue(afterInventory.isEmpty, context)

                    let afterCircle = try await document.circleContent(for: circle)
                    XCTAssertEqual(afterCircle?.memo, beforeCircle?.memo, context)
                    if vector.kind == "circle-removal" {
                        XCTAssertEqual(afterCircle?.needs, beforeCircle?.needs, context)
                    }
                    XCTAssertEqual(
                        afterCircle?.communicationState,
                        beforeCircle?.communicationState,
                        context
                    )

                    let replay = try SharedPlanAutomergeDocument(
                        data: beforeSave,
                        replicaID: Self.serverReplicaID
                    )
                    try await replay.applyEncodedChanges(change.bytes)
                    let replayHeads = await replay.heads()
                    let documentHeads = await document.heads()
                    let replayInventory = try await replay.conflictInventory()
                    XCTAssertEqual(replayHeads, documentHeads, context)
                    XCTAssertTrue(replayInventory.isEmpty, context)
                    let replayRecord = try await replay.operationRecords().first {
                        $0.id == operationID
                    }
                    XCTAssertEqual(
                        replayRecord,
                        record,
                        context
                    )
                }
            }
        }
    }

    func testLiteralBacklogVectorsAndLocalOneThousandOperationGate() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.backlogLimitVectors.vectors.map(\.changeCount), [1_000, 1_001])

        for vector in fixture.backlogLimitVectors.vectors {
            let context = "changeCount=\(vector.changeCount)"
            let clientDocument = try SharedPlanAutomergeDocument(
                data: try decodeBase64URL(vector.clientDocument, context: context),
                replicaID: Self.replicaID
            )
            let operationCount = await clientDocument.semanticOperationIDs().count
            XCTAssertEqual(operationCount, vector.changeCount + 1, context)
            XCTAssertEqual(
                try decodeBase64URL(vector.clientChangesPayload, context: context).count,
                vector.clientChangesPayloadBytes,
                context
            )
            XCTAssertNotNil(
                Data(base64URLString: vector.clientHavePayload),
                context
            )
            XCTAssertNotNil(
                Data(base64URLString: vector.serverNeedPayload),
                context
            )

            if vector.changeCount == 1_000 {
                XCTAssertEqual(vector.expected.status, "accepted", context)
                XCTAssertNil(vector.expected.error, context)
            } else {
                XCTAssertEqual(vector.expected.status, "rejected", context)
                XCTAssertEqual(vector.expected.closeCode, 4_422, context)
                XCTAssertEqual(vector.expected.error?.code, "plan_sync_backlog_limit", context)
                XCTAssertEqual(
                    vector.expected.error?.details?.maximumNewOperationsPerSyncFrame,
                    1_000,
                    context
                )
                XCTAssertEqual(vector.expected.error?.details?.receivedChanges, 1_001, context)
            }
        }

        let document = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(
                fixture.backlogLimitVectors.baseDocument,
                context: "local backlog base"
            ),
            replicaID: Self.replicaID
        )
        let before = await document.save()
        let operationID = UUID(uuidString: "00000000-0000-4000-8000-000000001001")!
        var pending = (0..<1_000).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
        }
        pending.append(operationID)
        let probe = PersistenceProbe()
        do {
            _ = try await document.performDurableMutation(
                .setCirclePresence(
                    try XCTUnwrap(
                        SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: 9_001)
                    ),
                    .removed
                ),
                operationID: operationID,
                actorUserID: "11111111111111111111111111111111",
                authoredAt: Date(timeIntervalSince1970: 0),
                pendingOperationIDs: pending
            ) { _, _ in
                await probe.recordPersistence()
            }
            XCTFail("The 1,001st unacknowledged operation must be rejected")
        } catch let error as SharedPlanError {
            XCTAssertEqual(
                error,
                .planSyncBacklogLimit(maximum: 1_000, received: 1_001)
            )
        }
        let after = await document.save()
        let persistenceCount = await probe.persistenceCount
        XCTAssertEqual(after, before)
        XCTAssertEqual(persistenceCount, 0)
    }

    func testLiteralRestartAndOfflineUnicodeSyncPayloadsConverge() async throws {
        let fixture = try loadFixture()

        let restartServer = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(fixture.restart.serverDocument, context: "restart server"),
            replicaID: Self.serverReplicaID
        )
        let restartClient = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(fixture.restart.clientDocument, context: "restart client"),
            replicaID: Self.replicaID
        )
        let restartSession = UUID(uuidString: "12121212-1212-4212-8212-121212121212")!
        await restartServer.beginSyncSession(id: restartSession)
        await restartClient.beginSyncSession(id: restartSession)
        for payload in fixture.restart.clientToServerPayloads {
            try await restartServer.receiveSyncMessage(
                sessionID: restartSession,
                message: decodeBase64URL(payload, context: "restart client to server")
            )
        }
        for payload in fixture.restart.serverToClientPayloads {
            try await restartClient.receiveSyncMessage(
                sessionID: restartSession,
                message: decodeBase64URL(payload, context: "restart server to client")
            )
        }
        let restartServerHeads = await restartServer.heads()
        let restartClientHeads = await restartClient.heads()
        XCTAssertEqual(restartServerHeads, fixture.restart.convergedHeads)
        XCTAssertEqual(restartClientHeads, fixture.restart.convergedHeads)

        let offline = fixture.offlineConcurrentText
        let clientA = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(offline.clientADocument, context: "offline client A"),
            replicaID: Self.replicaID
        )
        let clientB = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(offline.clientBDocument, context: "offline client B"),
            replicaID: Self.serverReplicaID
        )
        let syncSession = UUID(uuidString: "13131313-1313-4313-8313-131313131313")!
        await clientA.beginSyncSession(id: syncSession)
        await clientB.beginSyncSession(id: syncSession)
        for payload in offline.clientAToBPayloads {
            try await clientB.receiveSyncMessage(
                sessionID: syncSession,
                message: decodeBase64URL(payload, context: "offline A to B")
            )
        }
        for payload in offline.clientBToAPayloads {
            try await clientA.receiveSyncMessage(
                sessionID: syncSession,
                message: decodeBase64URL(payload, context: "offline B to A")
            )
        }

        let converged = try SharedPlanAutomergeDocument(
            data: try decodeBase64URL(offline.convergedDocument, context: "offline converged"),
            replicaID: Self.replicaID
        )
        let key = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: 9_001)
        )
        let clientAHeads = await clientA.heads()
        let clientBHeads = await clientB.heads()
        let convergedHeads = await converged.heads()
        let clientAMemo = try await clientA.memo(for: key)
        let clientBMemo = try await clientB.memo(for: key)
        let convergedMemo = try await converged.memo(for: key)
        let convergedOperationIDs = await converged.semanticOperationIDs()
            .map { $0.uuidString.lowercased() }
        XCTAssertEqual(clientAHeads, offline.convergedHeads)
        XCTAssertEqual(clientBHeads, offline.convergedHeads)
        XCTAssertEqual(convergedHeads, offline.convergedHeads)
        XCTAssertEqual(clientAMemo, offline.convergedMemo)
        XCTAssertEqual(clientBMemo, offline.convergedMemo)
        XCTAssertEqual(convergedMemo, offline.convergedMemo)
        XCTAssertEqual(
            Set(convergedOperationIDs),
            Set(offline.operationIDs + ["77777777-7777-4777-8777-777777777777"])
        )
    }

    func testLiteralTransportDialogueAndReceiptVectorsDecodeExactly() throws {
        let fixture = try loadFixture()
        let session = fixture.initialSession

        XCTAssertEqual(session.hello.v, 1)
        XCTAssertEqual(session.hello.type, "hello")
        XCTAssertEqual(session.hello.planID, fixture.planID)
        XCTAssertFalse(session.hello.mutationsEnabled)
        XCTAssertEqual(session.clientNegotiationEnvelope.seq, 1)
        XCTAssertEqual(session.serverNeedEnvelope.seq, 1)
        XCTAssertEqual(session.acceptedEnvelope.seq, 2)
        XCTAssertEqual(session.serverResponseEnvelope.seq, 2)
        XCTAssertEqual(session.ack.ackSeq, 2)
        XCTAssertEqual(session.ack.documentHeads, session.acceptedHeads)
        XCTAssertNotNil(Data(base64URLString: session.acceptedDocument))

        for payload in [
            session.clientNegotiationEnvelope.payload,
            session.serverNeedEnvelope.payload,
            session.acceptedEnvelope.payload,
            session.serverResponseEnvelope.payload,
        ] {
            XCTAssertNotNil(Data(base64URLString: payload))
        }

        XCTAssertEqual(
            fixture.transportReceipts.exactDuplicateEnvelope,
            session.acceptedEnvelope
        )
        XCTAssertEqual(
            fixture.transportReceipts.receiptViolationEnvelope.frameID,
            session.acceptedEnvelope.frameID
        )
        XCTAssertEqual(
            fixture.transportReceipts.receiptViolationEnvelope.seq,
            session.acceptedEnvelope.seq
        )
        XCTAssertNotEqual(
            fixture.transportReceipts.receiptViolationEnvelope.payload,
            session.acceptedEnvelope.payload
        )
        XCTAssertGreaterThan(
            fixture.transportReceipts.sequenceGapEnvelope.seq,
            session.acceptedEnvelope.seq + 1
        )
    }

    func testFirstDeterministicSwiftAuthoredChangeRoundTripsFromJavaScriptBootstrap() async throws {
        let fixture = try loadFixture()
        let bootstrap = try decodeBase64URL(fixture.bootstrap.document, context: "Swift bootstrap")
        let document = try SharedPlanAutomergeDocument(
            data: bootstrap,
            replicaID: Self.replicaID
        )
        let key = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: 9_101)
        )
        let operationID = UUID(uuidString: "10101010-1010-4010-8010-101010101010")!
        let actorUserID = "11111111111111111111111111111111"
        let authoredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let beforeHistoryCount = await document.historyCount()
        let beforeHeads = await document.heads()
        let probe = PersistenceProbe()

        let result = try await document.performDurableMutation(
            .setCirclePresence(key, .active),
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            pendingOperationIDs: [operationID]
        ) { snapshot, _ in
            await probe.recordPersistence(snapshot: snapshot)
        }
        let durableResult = try XCTUnwrap(result)
        let changes = try await document.encodedChanges(sinceHistoryIndex: beforeHistoryCount)
        XCTAssertEqual(
            changes.count,
            1,
            "A durable mutation emitted: \(changes.map { $0.message ?? "<nil>" })"
        )
        let change = try XCTUnwrap(changes.only)
        let afterHeads = await document.heads()
        let afterSave = await document.save()
        let persistedSnapshot = await probe.lastSnapshot

        XCTAssertEqual(beforeHeads, fixture.bootstrap.heads)
        XCTAssertEqual(change.actorID, Self.replicaID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        XCTAssertEqual(
            change.message,
            "operation:\(operationID.uuidString.lowercased())"
        )
        XCTAssertEqual(change.timestamp, authoredAt)
        XCTAssertEqual(change.hash, try XCTUnwrap(afterHeads.only))
        XCTAssertEqual(durableResult.snapshot.document, afterSave)
        XCTAssertEqual(persistedSnapshot?.document, afterSave)
        XCTAssertEqual(persistedSnapshot?.pendingOperationIDs, [operationID])

        let replay = try SharedPlanAutomergeDocument(
            data: bootstrap,
            replicaID: Self.serverReplicaID
        )
        try await replay.applyEncodedChanges(change.bytes)
        let replayHeads = await replay.heads()
        let replayRecords = try await replay.operationRecords()
        let replayRecord = try XCTUnwrap(replayRecords.first(where: { $0.id == operationID }))
        let replayPresence = try await replay.presence(for: key)
        XCTAssertEqual(replayHeads, afterHeads)
        XCTAssertEqual(replayRecord.type, .circlePresence)
        XCTAssertEqual(replayRecord.actorUserID, actorUserID)
        XCTAssertEqual(
            replayRecord.payload,
            [
                "v": .integer(1),
                "wcID": .integer(9_101),
                "state": .string("active"),
            ]
        )
        XCTAssertEqual(replayPresence, .present)
    }

    func testNeedCreateRejectsNondefaultDescendantsBeforePersistence() async throws {
        let fixture = try loadFixture()
        let circleVector = try XCTUnwrap(
            fixture.operationVectors.first(where: {
                $0.operation.type == .circlePresence
                    && $0.operation.payload["state"] == .string("active")
            })
        )
        let document = try SharedPlanAutomergeDocument(
            data: try XCTUnwrap(Data(base64URLString: circleVector.afterDocument)),
            replicaID: Self.replicaID
        )
        let rawWCID = try XCTUnwrap(circleVector.operation.payload["wcID"]?.integerValue)
        let wcID = try XCTUnwrap(Int(exactly: rawWCID))
        let key = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: wcID)
        )
        let operationID = UUID(uuidString: "17171717-1717-4717-8717-171717171717")!
        let invalidNeed = SharedPlanPurchaseNeed(
            id: UUID(uuidString: "18181818-1818-4818-8818-181818181818")!,
            requesterUserID: "member-a",
            wantedQuantity: 2,
            buyerAllocations: ["buyer-a": 1],
            fulfilledQuantity: 1
        )
        let beforeSave = await document.save()
        let beforeHistoryCount = await document.historyCount()
        let probe = PersistenceProbe()

        do {
            _ = try await document.performDurableMutation(
                .createNeed(invalidNeed, circle: key),
                operationID: operationID,
                actorUserID: "member-a",
                authoredAt: Date(timeIntervalSince1970: 1_700_000_010),
                pendingOperationIDs: [operationID]
            ) { snapshot, _ in
                await probe.recordPersistence(snapshot: snapshot)
            }
            XCTFail("need.create cannot smuggle allocation or fulfillment writes")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }

        let afterSave = await document.save()
        let afterHistoryCount = await document.historyCount()
        let afterOperationIDs = await document.semanticOperationIDs()
        let persistenceCount = await probe.persistenceCount
        XCTAssertEqual(afterSave, beforeSave)
        XCTAssertEqual(afterHistoryCount, beforeHistoryCount)
        XCTAssertFalse(afterOperationIDs.contains(operationID))
        XCTAssertEqual(persistenceCount, 0)
    }

    func testRemovedNeedReactivationRetainsDescendantsAndEmitsExactCreatePatch() async throws {
        let document = try SharedPlanAutomergeDocument(
            fixturePlanID: UUID().uuidString.lowercased(),
            comiketNo: 108,
            replicaID: Self.replicaID
        )
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 9_109))
        let needID = UUID(uuidString: "19191919-1919-4919-8919-191919191919")!
        _ = try await document.addCircle(
            key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_011)
        )
        _ = try await document.createNeed(
            SharedPlanPurchaseNeed(
                id: needID,
                requesterUserID: "member-a",
                wantedQuantity: 2
            ),
            for: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_012)
        )
        _ = try await document.setBuyerAllocation(
            2,
            buyerUserID: "buyer-a",
            needID: needID,
            circle: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_013)
        )
        _ = try await document.setFulfilledQuantity(
            1,
            needID: needID,
            circle: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_014)
        )
        _ = try await document.deleteNeed(
            needID,
            for: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_015)
        )

        let operationID = UUID(uuidString: "20202020-2020-4020-8020-202020202020")!
        let beforeHistoryCount = await document.historyCount()
        let reactivated = SharedPlanPurchaseNeed(
            id: needID,
            requesterUserID: "member-b",
            wantedQuantity: 3,
            buyerAllocations: ["buyer-a": 2],
            fulfilledQuantity: 1
        )
        let didReactivate = try await document.createNeed(
            reactivated,
            for: key,
            operationID: operationID,
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_016)
        )
        XCTAssertTrue(didReactivate)

        let storedNeed = try await document.purchaseNeed(id: needID, circleKey: key)
        let changes = try await document.encodedChanges(sinceHistoryIndex: beforeHistoryCount)
        let records = try await document.operationRecords()
        let record = try XCTUnwrap(records.first(where: { $0.id == operationID }))
        XCTAssertEqual(storedNeed, reactivated)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(record.type, .needCreate)
        XCTAssertEqual(
            record.payload,
            [
                "v": .integer(1),
                "wcID": .integer(Int64(key.wcID)),
                "needID": .string(needID.uuidString.lowercased()),
                "requesterUserID": .string("member-b"),
                "wantedQuantity": .integer(3),
            ]
        )

        _ = try await document.deleteNeed(
            needID,
            for: key,
            operationID: UUID(),
            actorUserID: "owner",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_017)
        )
        let beforeRejectedSave = await document.save()
        do {
            _ = try await document.createNeed(
                SharedPlanPurchaseNeed(
                    id: needID,
                    requesterUserID: "member-b",
                    wantedQuantity: 3
                ),
                for: key,
                operationID: UUID(),
                actorUserID: "owner",
                authoredAt: Date(timeIntervalSince1970: 1_700_000_018)
            )
            XCTFail("Reactivation cannot imply clearing retained descendants")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .syncProtocolViolation)
        }
        let afterRejectedSave = await document.save()
        XCTAssertEqual(afterRejectedSave, beforeRejectedSave)
    }

    private static let replicaID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let serverReplicaID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let actorUserID = "11111111111111111111111111111111"

    private func decodeBase64URL(_ encoded: String, context: String) throws -> Data {
        try XCTUnwrap(Data(base64URLString: encoded), context)
    }

    private func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "automerge-sync-v1",
                withExtension: "json"
            ) ?? bundle.url(
                forResource: "automerge-sync-v1",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private struct Fixture: Decodable {
    let fixtureVersion: Int
    let planID: String
    let comiketNo: Int
    let bootstrap: DocumentFixture
    let operationExamples: [OperationExample]
    let operationVectors: [OperationVector]
    let parentResolutionVectors: [ResolutionVector]
    let nestedParentResolutionVectors: [ResolutionVector]
    let semanticConflictVectors: [SemanticConflictVector]
    let backlogLimitVectors: BacklogLimitVectors
    let restart: RestartVector
    let offlineConcurrentText: OfflineConcurrentTextVector
    let initialSession: InitialSessionVector
    let transportReceipts: TransportReceiptVectors
}

private struct DocumentFixture: Decodable {
    let document: String
    let heads: [String]
}

private struct OperationExample: Decodable {
    let operationID: String
    let type: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
}

private struct OperationVector: Decodable {
    let operationID: String
    let operation: OperationFixture
    let beforeDocument: String
    let beforeHeads: [String]
    let change: String
    let afterDocument: String
    let afterHeads: [String]
}

private struct OperationFixture: Decodable {
    let type: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
}

private struct ResolutionVector: Decodable {
    let kind: String
    let scenario: String?
    let operationID: String
    let operation: OperationFixture
    let beforeDocument: String
    let beforeHeads: [String]
    let beforeConflicts: [SharedPlanConflict]
    let change: String
    let afterDocument: String
    let afterHeads: [String]
    let afterConflicts: [SharedPlanConflict]
}

private struct SemanticConflictVector: Decodable {
    let kind: String
    let descendantOperationType: SharedPlanOperationType
    let baseDocument: String
    let removalChange: String
    let descendantChange: String
    let mergedDocument: String
    let mergedHeads: [String]
    let conflicts: [SharedPlanConflict]
}

private struct BacklogLimitVectors: Decodable {
    let baseDocument: String
    let vectors: [BacklogVector]
}

private struct BacklogVector: Decodable {
    let changeCount: Int
    let clientDocument: String
    let clientHavePayload: String
    let serverNeedPayload: String
    let clientChangesPayload: String
    let clientChangesPayloadBytes: Int
    let expected: BacklogExpected
}

private struct BacklogExpected: Decodable {
    let status: String
    let closeCode: Int?
    let error: BacklogError?
}

private struct BacklogError: Decodable {
    let code: String
    let details: BacklogErrorDetails?
}

private struct BacklogErrorDetails: Decodable {
    let maximumNewOperationsPerSyncFrame: Int
    let receivedChanges: Int
}

private struct RestartVector: Decodable {
    let serverDocument: String
    let clientDocument: String
    let clientToServerPayloads: [String]
    let serverToClientPayloads: [String]
    let convergedHeads: [String]
}

private struct OfflineConcurrentTextVector: Decodable {
    let clientADocument: String
    let clientBDocument: String
    let clientAToBPayloads: [String]
    let clientBToAPayloads: [String]
    let convergedDocument: String
    let convergedHeads: [String]
    let convergedMemo: String
    let operationIDs: [String]
}

private struct InitialSessionVector: Decodable {
    let hello: FixtureHello
    let clientNegotiationEnvelope: SharedPlanClientSyncFrame
    let serverNeedEnvelope: SharedPlanServerSyncFrame
    let acceptedEnvelope: SharedPlanClientSyncFrame
    let serverResponseEnvelope: SharedPlanServerSyncFrame
    let ack: SharedPlanSyncAcknowledgement
    let acceptedDocument: String
    let acceptedHeads: [String]
}

private struct FixtureHello: Decodable {
    let v: Int
    let type: String
    let planID: String
    let sessionID: String
    let nextClientSeq: UInt64
    let nextServerSeq: UInt64
    let mutationsEnabled: Bool
}

private struct TransportReceiptVectors: Decodable {
    let exactDuplicateEnvelope: SharedPlanClientSyncFrame
    let receiptViolationEnvelope: SharedPlanClientSyncFrame
    let sequenceGapEnvelope: SharedPlanClientSyncFrame
}

private actor PersistenceProbe {
    private(set) var persistenceCount = 0
    private(set) var lastSnapshot: SharedPlanDocumentSnapshot?

    func recordPersistence(snapshot: SharedPlanDocumentSnapshot? = nil) {
        persistenceCount += 1
        lastSnapshot = snapshot
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
