@testable import ComiNavi
import CryptoKit
import Foundation
import XCTest

final class SharedPlanSwiftScalarConflictFixtureTests: XCTestCase {
    func testGenerateAndValidateDeterministicScalarConflictFixture() async throws {
        let sourceData = try loadFixtureData(named: "automerge-sync-v1")
        let source = try JSONDecoder().decode(ScalarSourceFixture.self, from: sourceData)
        let generated = try await makeFixture(source: source, sourceData: sourceData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(generated) + Data("\n".utf8)

        guard let checkedIn = try? loadFixtureData(
            named: "automerge-swift-scalar-conflicts-v1"
        ) else {
            attach(encoded)
            XCTFail("Install the generated scalar-conflict fixture from the xcresult attachment")
            return
        }
        if encoded != checkedIn { attach(encoded) }
        XCTAssertEqual(encoded, checkedIn)
        XCTAssertEqual(generated.vectors.count, 15)
        XCTAssertEqual(
            Dictionary(grouping: generated.vectors, by: \.field).mapValues(\.count),
            [
                .presence: 3,
                .wantedQuantity: 3,
                .buyerAllocation: 3,
                .fulfilledQuantity: 3,
                .communication: 3,
            ]
        )

        for vector in generated.vectors {
            try await assertVectorReplays(
                vector,
                planID: generated.planID,
                comiketNo: generated.comiketNo
            )
        }
    }

    private func makeFixture(
        source: ScalarSourceFixture,
        sourceData: Data
    ) async throws -> SwiftScalarConflictFixture {
        let bootstrap = try unwrapBase64URL(source.bootstrap.document)
        let setup = try SharedPlanAutomergeDocument(
            data: bootstrap,
            replicaID: Self.setupReplicaID
        )
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: source.comiketNo, wcID: 9_301)
        )
        let needID = UUID(uuidString: "13131313-1313-4313-8313-131313131313")!
        let setupOperations: [(UUID, SharedPlanDurableMutation)] = [
            (
                operationID(1),
                .setCirclePresence(circle, .active)
            ),
            (
                operationID(2),
                .createNeed(
                    SharedPlanPurchaseNeed(
                        id: needID,
                        requesterUserID: Self.actorUserID,
                        wantedQuantity: 3,
                        buyerAllocations: [:],
                        fulfilledQuantity: 0
                    ),
                    circle: circle
                )
            ),
        ]
        for (index, entry) in setupOperations.enumerated() {
            _ = try await setup.performDurableMutation(
                entry.1,
                operationID: entry.0,
                actorUserID: Self.actorUserID,
                authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_000 + index)),
                pendingOperationIDs: [entry.0]
            ) { _, _ in }
        }
        let baseDocument = await setup.save()

        var vectors: [SwiftScalarConflictVector] = []
        let fields: [ScalarField] = [
            .wantedQuantity,
            .buyerAllocation,
            .fulfilledQuantity,
            .communication,
        ]
        for (fieldOffset, field) in fields.enumerated() {
            let seed = try await makeConflictSeed(
                field: field,
                baseDocument: baseDocument,
                circle: circle,
                needID: needID,
                operationBase: 100 + fieldOffset * 10
            )
            let visible = try await visibleValue(
                field: field,
                document: seed.document,
                circle: circle,
                needID: needID
            )
            let losing = try XCTUnwrap(
                seed.conflict.candidates.map(\.value).first(where: { $0 != visible })
            )
            let choices: [(ScalarChoice, SharedPlanJSONValue)] = [
                (.visibleWinner, visible),
                (.losingCandidate, losing),
                (.newValue, newValue(for: field)),
            ]
            for (choiceOffset, choice) in choices.enumerated() {
                vectors.append(try await authorResolutionVector(
                    field: field,
                    choice: choice.0,
                    selectedValue: choice.1,
                    seed: seed,
                    circle: circle,
                    needID: needID,
                    operationID: operationID(500 + fieldOffset * 10 + choiceOffset),
                    authoredAt: Date(
                        timeIntervalSince1970: TimeInterval(
                            1_710_001_000 + fieldOffset * 10 + choiceOffset
                        )
                    )
                ))
            }
        }

        let oppositePresenceSeed = try await makePresenceConflictSeed(
            baseDocument: baseDocument,
            circle: circle,
            operationBase: 900,
            oppositeStates: true
        )
        let visiblePresence = try await visibleValue(
            field: .presence,
            document: oppositePresenceSeed.document,
            circle: circle,
            needID: needID
        )
        let losingPresence = try XCTUnwrap(
            oppositePresenceSeed.conflict.candidates
                .compactMap { $0.value.objectValue?["state"] }
                .first(where: { $0 != visiblePresence })
        )
        for (offset, choice) in [
            (ScalarChoice.visibleWinner, visiblePresence),
            (ScalarChoice.losingCandidate, losingPresence),
        ].enumerated() {
            vectors.append(try await authorResolutionVector(
                field: .presence,
                choice: choice.0,
                selectedValue: choice.1,
                seed: oppositePresenceSeed,
                circle: circle,
                needID: needID,
                operationID: operationID(990 + offset),
                authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_001_990 + offset))
            ))
        }

        let sameStatePresenceSeed = try await makePresenceConflictSeed(
            baseDocument: baseDocument,
            circle: circle,
            operationBase: 950,
            oppositeStates: false
        )
        vectors.append(try await authorResolutionVector(
            field: .presence,
            choice: .sameState,
            selectedValue: .string(SharedPlanPresenceState.removed.rawValue),
            seed: sameStatePresenceSeed,
            circle: circle,
            needID: needID,
            operationID: operationID(999),
            authoredAt: Date(timeIntervalSince1970: 1_710_001_999)
        ))

        return SwiftScalarConflictFixture(
            fixtureVersion: 1,
            producer: .init(package: "automerge-swift", version: "0.7.2"),
            sourceFixtureSHA256: SHA256.hash(data: sourceData).hexString,
            planID: source.planID,
            comiketNo: source.comiketNo,
            circleWCID: circle.wcID,
            needID: needID.uuidString.lowercased(),
            buyerUserID: Self.buyerUserID,
            communicationKey: Self.communicationKey,
            vectors: vectors.sorted {
                if $0.field != $1.field { return $0.field.rawValue < $1.field.rawValue }
                return $0.choice.rawValue < $1.choice.rawValue
            }
        )
    }

    private func makeConflictSeed(
        field: ScalarField,
        baseDocument: Data,
        circle: SharedPlanCircleKey,
        needID: UUID,
        operationBase: Int
    ) async throws -> ScalarConflictSeed {
        let left = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.leftReplicaID
        )
        let right = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.rightReplicaID
        )
        let leftID = operationID(operationBase)
        let rightID = operationID(operationBase + 1)
        let leftChange = try await authorOneChange(
            document: left,
            mutation: mutation(
                for: field,
                value: competingValues(for: field).0,
                circle: circle,
                needID: needID
            ),
            operationID: leftID,
            authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_100 + operationBase))
        )
        let rightChange = try await authorOneChange(
            document: right,
            mutation: mutation(
                for: field,
                value: competingValues(for: field).1,
                circle: circle,
                needID: needID
            ),
            operationID: rightID,
            authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_200 + operationBase))
        )
        let merged = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.resolutionReplicaID
        )
        try await merged.applyEncodedChanges(leftChange.bytes)
        try await merged.applyEncodedChanges(rightChange.bytes)
        let inventory = try await merged.conflictInventory()
        let expectedPath = path(for: field, circle: circle, needID: needID)
        let conflict = try XCTUnwrap(inventory.first(where: { $0.path == expectedPath }))
        XCTAssertEqual(conflict.kind, .scalar)
        XCTAssertEqual(conflict.candidates.count, 2)
        return ScalarConflictSeed(
            document: merged,
            beforeDocument: await merged.save(),
            beforeHeads: await merged.heads(),
            conflict: conflict,
            competingChanges: [leftChange, rightChange]
        )
    }

    private func makePresenceConflictSeed(
        baseDocument: Data,
        circle: SharedPlanCircleKey,
        operationBase: Int,
        oppositeStates: Bool
    ) async throws -> ScalarConflictSeed {
        let left = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.leftReplicaID
        )
        let right = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.rightReplicaID
        )
        let leftChange = try await authorOneChange(
            document: left,
            mutation: .setCirclePresence(circle, .removed),
            operationID: operationID(operationBase),
            authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_100 + operationBase))
        )
        var rightChanges = [try await authorOneChange(
            document: right,
            mutation: .setCirclePresence(circle, .removed),
            operationID: operationID(operationBase + 1),
            authoredAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_200 + operationBase))
        )]
        if oppositeStates {
            rightChanges.append(try await authorOneChange(
                document: right,
                mutation: .setCirclePresence(circle, .active),
                operationID: operationID(operationBase + 2),
                authoredAt: Date(
                    timeIntervalSince1970: TimeInterval(1_710_000_300 + operationBase)
                )
            ))
        }

        let merged = try SharedPlanAutomergeDocument(
            data: baseDocument,
            replicaID: Self.resolutionReplicaID
        )
        try await merged.applyEncodedChanges(leftChange.bytes)
        for change in rightChanges {
            try await merged.applyEncodedChanges(change.bytes)
        }
        let expectedPath = ["circles", String(circle.wcID), "presence"]
        let inventory = try await merged.conflictInventory()
        let conflict = try XCTUnwrap(inventory.first(where: { $0.path == expectedPath }))
        XCTAssertEqual(conflict.kind, .scalar)
        XCTAssertEqual(conflict.candidates.count, 2)
        return ScalarConflictSeed(
            document: merged,
            beforeDocument: await merged.save(),
            beforeHeads: await merged.heads(),
            conflict: conflict,
            competingChanges: [leftChange] + rightChanges
        )
    }

    private func authorResolutionVector(
        field: ScalarField,
        choice: ScalarChoice,
        selectedValue: SharedPlanJSONValue,
        seed: ScalarConflictSeed,
        circle: SharedPlanCircleKey,
        needID: UUID,
        operationID: UUID,
        authoredAt: Date
    ) async throws -> SwiftScalarConflictVector {
        let document = try SharedPlanAutomergeDocument(
            data: seed.beforeDocument,
            replicaID: Self.resolutionReplicaID
        )
        let visibleBefore = try await visibleValue(
            field: field,
            document: document,
            circle: circle,
            needID: needID
        )
        let historyCount = await document.historyCount()
        let result = try await document.performDurableMutation(
            mutation(for: field, value: selectedValue, circle: circle, needID: needID),
            operationID: operationID,
            actorUserID: Self.actorUserID,
            authoredAt: authoredAt,
            pendingOperationIDs: [operationID]
        ) { _, _ in }
        _ = try XCTUnwrap(result)
        let authoredChanges = try await document.encodedChanges(
            sinceHistoryIndex: historyCount
        )
        let change = try XCTUnwrap(authoredChanges.only)
        let remaining = try await document.conflictInventory().filter {
            $0.path == seed.conflict.path
        }
        XCTAssertTrue(remaining.isEmpty, "\(field.rawValue):\(choice.rawValue)")
        let records = try await document.operationRecords()
        let record = try XCTUnwrap(records.first(where: { $0.id == operationID }))
        return SwiftScalarConflictVector(
            field: field,
            choice: choice,
            visibleValueBefore: visibleBefore,
            selectedValue: selectedValue,
            conflict: seed.conflict,
            competingChanges: seed.competingChanges.map {
                .init(hash: $0.hash, bytes: $0.bytes.base64URLEncodedString)
            },
            operationID: operationID.uuidString.lowercased(),
            operation: .init(
                type: record.type,
                actorUserID: record.actorUserID,
                payload: record.payload
            ),
            beforeDocument: seed.beforeDocument.base64URLEncodedString,
            beforeHeads: seed.beforeHeads,
            change: change.bytes.base64URLEncodedString,
            changeHash: change.hash,
            changeActorID: change.actorID,
            changeMessage: change.message,
            changeTimestampUnixSeconds: Int64(change.timestamp.timeIntervalSince1970),
            afterDocument: await document.save().base64URLEncodedString,
            afterHeads: await document.heads()
        )
    }

    private func authorOneChange(
        document: SharedPlanAutomergeDocument,
        mutation: SharedPlanDurableMutation,
        operationID: UUID,
        authoredAt: Date
    ) async throws -> SharedPlanEncodedChange {
        let historyCount = await document.historyCount()
        let result = try await document.performDurableMutation(
            mutation,
            operationID: operationID,
            actorUserID: Self.actorUserID,
            authoredAt: authoredAt,
            pendingOperationIDs: [operationID]
        ) { _, _ in }
        _ = try XCTUnwrap(result)
        let changes = try await document.encodedChanges(sinceHistoryIndex: historyCount)
        return try XCTUnwrap(changes.only)
    }

    private func assertVectorReplays(
        _ vector: SwiftScalarConflictVector,
        planID: String,
        comiketNo: Int
    ) async throws {
        let replay = try SharedPlanAutomergeDocument(
            data: try unwrapBase64URL(vector.beforeDocument),
            replicaID: Self.verificationReplicaID
        )
        XCTAssertEqual(replay.planID, planID)
        XCTAssertEqual(replay.comiketNo, comiketNo)
        let beforeInventory = try await replay.conflictInventory()
        XCTAssertTrue(beforeInventory.contains(vector.conflict))
        try await replay.applyEncodedChanges(unwrapBase64URL(vector.change))
        let replayHeads = await replay.heads()
        let replaySave = await replay.save()
        XCTAssertEqual(replayHeads, vector.afterHeads)
        XCTAssertEqual(
            replaySave,
            try unwrapBase64URL(vector.afterDocument),
            "\(vector.field.rawValue):\(vector.choice.rawValue)"
        )
        let afterInventory = try await replay.conflictInventory()
        XCTAssertFalse(afterInventory.contains(where: { $0.id == vector.conflict.id }))
    }

    private func mutation(
        for field: ScalarField,
        value: SharedPlanJSONValue,
        circle: SharedPlanCircleKey,
        needID: UUID
    ) throws -> SharedPlanDurableMutation {
        switch field {
        case .presence:
            return .setCirclePresence(
                circle,
                try XCTUnwrap(SharedPlanPresenceState(rawValue: try value.requiredString()))
            )
        case .wantedQuantity:
            return .setWantedQuantity(
                try value.requiredInt(),
                needID: needID,
                circle: circle
            )
        case .buyerAllocation:
            return .setBuyerAllocation(
                try value.requiredInt(),
                buyerUserID: Self.buyerUserID,
                needID: needID,
                circle: circle
            )
        case .fulfilledQuantity:
            return .setFulfilledQuantity(
                try value.requiredInt(),
                needID: needID,
                circle: circle
            )
        case .communication:
            return .setCommunication(value, key: Self.communicationKey, circle: circle)
        }
    }

    private func visibleValue(
        field: ScalarField,
        document: SharedPlanAutomergeDocument,
        circle: SharedPlanCircleKey,
        needID: UUID
    ) async throws -> SharedPlanJSONValue {
        switch field {
        case .presence:
            let state = try await document.visiblePresenceState(for: circle)
            return .string(try XCTUnwrap(state).rawValue)
        case .wantedQuantity:
            let need = try await document.purchaseNeed(id: needID, circleKey: circle)
            return .integer(Int64(try XCTUnwrap(need?.wantedQuantity)))
        case .buyerAllocation:
            let need = try await document.purchaseNeed(id: needID, circleKey: circle)
            return .integer(Int64(try XCTUnwrap(
                need?.buyerAllocations[Self.buyerUserID]
            )))
        case .fulfilledQuantity:
            let need = try await document.purchaseNeed(id: needID, circleKey: circle)
            return .integer(Int64(try XCTUnwrap(need?.fulfilledQuantity)))
        case .communication:
            let content = try await document.circleContent(for: circle)
            return try XCTUnwrap(content?.communicationState[Self.communicationKey])
        }
    }

    private func competingValues(
        for field: ScalarField
    ) -> (SharedPlanJSONValue, SharedPlanJSONValue) {
        switch field {
        case .presence:
            (.string("removed"), .string("removed"))
        case .wantedQuantity:
            (.integer(4), .integer(5))
        case .buyerAllocation:
            (.integer(1), .integer(2))
        case .fulfilledQuantity:
            (.integer(1), .integer(2))
        case .communication:
            (.string("東"), .string("西"))
        }
    }

    private func newValue(for field: ScalarField) -> SharedPlanJSONValue {
        switch field {
        case .presence:
            .string("removed")
        case .wantedQuantity, .buyerAllocation, .fulfilledQuantity:
            .integer(3)
        case .communication:
            .string("中央")
        }
    }

    private func path(
        for field: ScalarField,
        circle: SharedPlanCircleKey,
        needID: UUID
    ) -> [String] {
        let circlePath = ["circles", String(circle.wcID)]
        let needPath = circlePath + ["needs", needID.uuidString.lowercased()]
        return switch field {
        case .presence:
            circlePath + ["presence"]
        case .wantedQuantity:
            needPath + ["wantedQuantity"]
        case .buyerAllocation:
            needPath + ["buyerAllocations", Self.buyerUserID]
        case .fulfilledQuantity:
            needPath + ["fulfilledQuantity"]
        case .communication:
            circlePath + ["communicationState", Self.communicationKey]
        }
    }

    private func operationID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
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

    private func attach(_ data: Data) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "automerge-swift-scalar-conflicts-v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let actorUserID = "11111111111111111111111111111111"
    private static let buyerUserID = "22222222222222222222222222222222"
    private static let communicationKey = "meeting.place"
    private static let setupReplicaID = UUID(
        uuidString: "51515151-5151-4151-8151-515151515151"
    )!
    private static let leftReplicaID = UUID(
        uuidString: "61616161-6161-4161-8161-616161616161"
    )!
    private static let rightReplicaID = UUID(
        uuidString: "71717171-7171-4171-8171-717171717171"
    )!
    private static let resolutionReplicaID = UUID(
        uuidString: "81818181-8181-4181-8181-818181818181"
    )!
    private static let verificationReplicaID = UUID(
        uuidString: "91919191-9191-4191-8191-919191919191"
    )!
}

private struct ScalarConflictSeed {
    let document: SharedPlanAutomergeDocument
    let beforeDocument: Data
    let beforeHeads: [String]
    let conflict: SharedPlanDocumentConflict
    let competingChanges: [SharedPlanEncodedChange]
}

private struct ScalarSourceFixture: Decodable {
    let planID: String
    let comiketNo: Int
    let bootstrap: ScalarBootstrap
}

private struct ScalarBootstrap: Decodable {
    let document: String
}

private struct SwiftScalarConflictFixture: Codable {
    let fixtureVersion: Int
    let producer: ScalarFixtureProducer
    let sourceFixtureSHA256: String
    let planID: String
    let comiketNo: Int
    let circleWCID: Int
    let needID: String
    let buyerUserID: String
    let communicationKey: String
    let vectors: [SwiftScalarConflictVector]
}

private struct ScalarFixtureProducer: Codable {
    let package: String
    let version: String
}

private enum ScalarField: String, Codable, Hashable {
    case presence
    case wantedQuantity
    case buyerAllocation
    case fulfilledQuantity
    case communication
}

private enum ScalarChoice: String, Codable {
    case visibleWinner
    case losingCandidate
    case newValue
    case sameState
}

private struct ScalarChangeFixture: Codable {
    let hash: String
    let bytes: String
}

private struct ScalarOperationFixture: Codable {
    let type: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
}

private struct SwiftScalarConflictVector: Codable {
    let field: ScalarField
    let choice: ScalarChoice
    let visibleValueBefore: SharedPlanJSONValue
    let selectedValue: SharedPlanJSONValue
    let conflict: SharedPlanDocumentConflict
    let competingChanges: [ScalarChangeFixture]
    let operationID: String
    let operation: ScalarOperationFixture
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

private extension SharedPlanJSONValue {
    func requiredString() throws -> String {
        guard case let .string(value) = self else {
            throw SharedPlanError.syncProtocolViolation
        }
        return value
    }

    func requiredInt() throws -> Int {
        guard case let .integer(value) = self, let exact = Int(exactly: value) else {
            throw SharedPlanError.syncProtocolViolation
        }
        return exact
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
