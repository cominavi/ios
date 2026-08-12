import Automerge
import CryptoKit
import Foundation

enum SharedPlanDurableMutation: Sendable {
    case setCirclePresence(SharedPlanCircleKey, SharedPlanPresenceState)
    /// Compatibility wrapper for the memo editor. It is persisted as one
    /// scalar-indexed `shared_plan.circle.memo.splice.v1` operation.
    case replaceMemo(String, circle: SharedPlanCircleKey)
    case spliceMemo(
        circle: SharedPlanCircleKey,
        index: Int,
        deleteCount: Int,
        text: String
    )
    case createNeed(SharedPlanPurchaseNeed, circle: SharedPlanCircleKey)
    /// Compatibility wrapper for the existing form. It emits one exact
    /// granular need operation and rejects multi-field replacements.
    case setPurchaseNeed(SharedPlanPurchaseNeed, circle: SharedPlanCircleKey)
    case deleteNeed(UUID, circle: SharedPlanCircleKey)
    case setWantedQuantity(Int, needID: UUID, circle: SharedPlanCircleKey)
    case setBuyerAllocation(Int, buyerUserID: String, needID: UUID, circle: SharedPlanCircleKey)
    case setFulfilledQuantity(Int, needID: UUID, circle: SharedPlanCircleKey)
    case setCommunication(SharedPlanJSONValue, key: String, circle: SharedPlanCircleKey)
    case resolveCircleParent(
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution]
    )
    case resolveNeedParent(
        needID: UUID,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution]
    )
}

enum SharedPlanAcknowledgedHeadProof: Equatable, Sendable {
    case contained
    case missing
    case unknown
}

struct SharedPlanDocumentSnapshot: Equatable, Sendable {
    let planID: String
    let replicaID: UUID
    let actorID: String
    let document: Data
    let pendingOperationIDs: [UUID]
    let syncIssue: SharedPlanSyncIssue?
    let localEditLimit: SharedPlanLocalEditLimit?
    /// Durable proof that this exact replica/membership generation has
    /// completed a server handshake with content mutations enabled. It allows
    /// edits while temporarily offline without granting authority to a fresh,
    /// revoked, or re-instated replica.
    let offlineMutationAuthority: Bool

    init(
        planID: String,
        replicaID: UUID,
        actorID: String,
        document: Data,
        pendingOperationIDs: [UUID],
        syncIssue: SharedPlanSyncIssue? = nil,
        localEditLimit: SharedPlanLocalEditLimit? = nil,
        offlineMutationAuthority: Bool = false
    ) {
        self.planID = planID
        self.replicaID = replicaID
        self.actorID = actorID
        self.document = document
        self.pendingOperationIDs = pendingOperationIDs
        self.syncIssue = syncIssue
        self.localEditLimit = localEditLimit
        self.offlineMutationAuthority = offlineMutationAuthority
    }
}

struct SharedPlanDurableMutationResult: Sendable {
    let snapshot: SharedPlanDocumentSnapshot
    let circleKeys: [SharedPlanCircleKey]
}

struct SharedPlanEncodedChange: Equatable, Sendable {
    let hash: String
    let actorID: String
    let message: String?
    let timestamp: Date
    let bytes: Data
}

enum SharedPlanCirclePresence: Equatable, Sendable {
    case present
    case removed
    case conflicted
}

/// Actor-isolated CRDT authority for one Shared Plan.
///
/// The mutable Automerge `Document` and every peer `SyncState` stay inside this
/// actor. Each domain mutator emits one Automerge change containing both the
/// substantive patch and exactly one immutable semantic operation record.
actor SharedPlanAutomergeDocument {
    static let schemaVersion: Int64 = 1
    static let maximumMemoUTF8Bytes = 64 * 1_024
    static let maximumQuantity = 999
    static let maximumCircles = 2_000
    static let maximumOperations = 10_000
    static let maximumUnacknowledgedOperations = 1_000
    static let maximumRetainedOperationPayloadUTF8Bytes = 512 * 1_024
    static let maximumSavedDocumentBytes = 1_500_000
    static let maximumDecodedSyncMessageBytes = 1_024 * 1_024
    private static let semanticChangeMessagePrefix = "operation:"
    private static let canonicalBootstrapRootKeys: Set<String> = [
        "schemaVersion", "planID", "comiketNo", "circles", "operations",
    ]

    private enum Key {
        static let schemaVersion = "schemaVersion"
        static let planID = "planID"
        static let comiketNo = "comiketNo"
        static let circles = "circles"
        static let operations = "operations"
        static let circleWCID = "WCID"
        static let wcID = "wcID"
        static let presence = "presence"
        static let state = "state"
        static let memo = "memo"
        static let needs = "needs"
        static let communicationState = "communicationState"
        static let rootOperationID = "rootOperationID"
        static let operationID = "operationID"
        static let requesterUserID = "requesterUserID"
        static let itemName = "itemName"
        static let unitPrice = "unitPrice"
        static let wantedQuantity = "wantedQuantity"
        static let buyerAllocations = "buyerAllocations"
        static let fulfilledQuantity = "fulfilledQuantity"
        static let operationType = "type"
        static let actorUserID = "actorUserID"
        static let payload = "payload"
        static let version = "v"
        static let index = "index"
        static let deleteCount = "deleteCount"
        static let text = "text"
        static let needID = "needID"
        static let buyerUserID = "buyerUserID"
        static let quantity = "quantity"
        static let key = "key"
        static let value = "value"
        static let selectedParentOperationID = "selectedParentOperationID"
        static let nestedResolutions = "nestedResolutions"
        static let conflictID = "conflictID"
        static let path = "path"
        static let selectedChangeHash = "selectedChangeHash"
    }

    nonisolated let planID: String
    nonisolated let comiketNo: Int
    nonisolated let replicaID: UUID

    private var document: Document
    private var circlesObject: ObjId
    private var operationsObject: ObjId
    private var syncStates: [UUID: SyncState] = [:]
    private var isPersistingDurableMutation = false
    /// Automerge Swift does not expose `hashForOpID`. Build the equivalent
    /// index once from single-change patches, then extend it only for newly
    /// observed history. This avoids replaying/forking the full document for
    /// every semantic operation when conflict UI is opened.
    private var operationChangeHashes: [UUID: String] = [:]
    private var operationChangeHashHeads: [String]?
    /// A causally ordered shadow used to prove that each canonical change
    /// message names the exact operation map entry introduced by that change.
    /// The validated history prefix is extended when possible; concurrent
    /// insertion before that prefix rebuilds the shadow from the bootstrap.
    private var operationValidationShadow: Document?
    private var operationValidationHistoryHashes: [String] = []
    /// The exact dependency index built while validating the same history.
    /// Conflict inventory reuses it instead of crossing the Swift/Automerge
    /// bridge for every retained change a second time.
    private var operationValidationGraph: ChangeGraph?
    private var conflictInventoryHeads: [String]?
    private var cachedConflictInventory: [SharedPlanDocumentConflict] = []
    /// Canonical retained payload bytes keyed by immutable document heads.
    /// Local edits seed the next-head entry incrementally; remote/load paths
    /// validate and seed it with one fail-closed ledger scan.
    private var retainedPayloadBytesByHeads: [String: Int] = [:]
    private var pendingRetainedPayloadBytes: Int?
    private var offlineMutationAuthority: Bool

    private struct SemanticChangeCandidate: Sendable {
        let operationID: UUID
        let rawOperationID: String
        let changeHash: String
        let bytes: Data
    }

    private struct SemanticValidationChunk: @unchecked Sendable {
        let shadow: Document
        let candidates: [SemanticChangeCandidate]
        let expectedEndHeads: String
    }

    private final class SemanticValidationAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[UUID: String]?]
        private var failed = false

        init(count: Int) {
            values = Array(repeating: nil, count: count)
        }

        func record(_ value: [UUID: String], at index: Int) {
            lock.withLock { values[index] = value }
        }

        func recordFailure() {
            lock.withLock { failed = true }
        }

        func combined() -> [UUID: String]? {
            lock.withLock {
                guard !failed, values.allSatisfy({ $0 != nil }) else {
                    return nil
                }
                var combined: [UUID: String] = [:]
                for value in values.compactMap(\.self) {
                    for (operationID, hash) in value {
                        guard combined.updateValue(
                            hash,
                            forKey: operationID
                        ) == nil else {
                            return nil
                        }
                    }
                }
                return combined
            }
        }
    }

    /// Creates an independent root only for cross-language fixtures and tests.
    /// Production clients must initialize from the server's exact bootstrap
    /// bytes so `circles` and `operations` are never concurrent root objects.
    init(fixturePlanID planID: String, comiketNo: Int, replicaID: UUID) throws {
        guard !planID.isEmpty, comiketNo > 0 else { throw SharedPlanError.persistenceFailed }
        self.planID = planID
        self.comiketNo = comiketNo
        self.replicaID = replicaID

        let document = Document(textEncoding: .unicodeScalar)
        document.actor = ActorId(uuid: replicaID)
        try document.put(obj: .ROOT, key: Key.schemaVersion, value: .Int(Self.schemaVersion))
        try document.put(obj: .ROOT, key: Key.planID, value: .String(planID))
        try document.put(obj: .ROOT, key: Key.comiketNo, value: .Int(Int64(comiketNo)))
        circlesObject = try document.putObject(obj: .ROOT, key: Key.circles, ty: .Map)
        operationsObject = try document.putObject(obj: .ROOT, key: Key.operations, ty: .Map)
        document.commitWith(message: nil)
        self.document = document
        offlineMutationAuthority = false
        retainedPayloadBytesByHeads[Self.headCacheKey(document)] = 0
        let bootstrap = try Self.validateCanonicalBootstrap(
            in: document,
            expectedPlanID: planID,
            expectedComiketNo: comiketNo
        )
        operationValidationShadow = bootstrap.shadow
        operationValidationHistoryHashes = [bootstrap.changeHash]
        operationValidationGraph = try ChangeGraph(document: bootstrap.shadow)
    }

    init(
        data: Data,
        replicaID: UUID,
        allowingPolicyLimitOverflow: Bool = false,
        offlineMutationAuthority: Bool = false
    ) throws {
        guard data.count <= Self.maximumSavedDocumentBytes else {
            throw SharedPlanError.documentLimit(
                String(localized: "プランのデータが大きすぎます。")
            )
        }
        let document = try Document(data)
        document.actor = ActorId(uuid: replicaID)
        let metadata = try Self.metadata(in: document)
        let retainedPayloadBytes = try Self.validateBounds(
            document: document,
            circlesObject: metadata.circles,
            operationsObject: metadata.operations,
            allowingPolicyLimitOverflow: allowingPolicyLimitOverflow
        )

        planID = metadata.planID
        comiketNo = metadata.comiketNo
        self.replicaID = replicaID
        self.document = document
        self.offlineMutationAuthority = offlineMutationAuthority
        circlesObject = metadata.circles
        operationsObject = metadata.operations
        retainedPayloadBytesByHeads[Self.headCacheKey(document)] = retainedPayloadBytes
        let bootstrap = try Self.validateCanonicalBootstrap(
            in: document,
            expectedPlanID: metadata.planID,
            expectedComiketNo: metadata.comiketNo
        )
        operationValidationShadow = bootstrap.shadow
        operationValidationHistoryHashes = [bootstrap.changeHash]
        operationValidationGraph = try ChangeGraph(document: bootstrap.shadow)
    }

    func actorID() -> String { document.actor.description.lowercased() }

    func save() -> Data { document.save() }

    func setOfflineMutationAuthority(_ enabled: Bool) {
        offlineMutationAuthority = enabled
    }

    func heads() -> [String] {
        document.heads().map(\.debugDescription).sorted()
    }

    /// Returns true only when every required local head is known to be an
    /// ancestor of the heads reported by the server. Unknown heads fail
    /// closed; a following reconnect/sync can make them provable.
    func acknowledgedHeadProof(
        _ acknowledgedHeadStrings: [String],
        causallyContain requiredHeadStrings: [String]
    ) -> SharedPlanAcknowledgedHeadProof {
        guard let acknowledgedHeads = Self.changeHashes(acknowledgedHeadStrings),
              let requiredHeads = Self.changeHashes(requiredHeadStrings)
        else { return .missing }
        if requiredHeads.isEmpty { return .contained }

        var reachable: Set<ChangeHash> = []
        var frontier = Array(acknowledgedHeads)
        while let hash = frontier.popLast() {
            guard reachable.insert(hash).inserted else { continue }
            guard let change = document.change(hash: hash) else { return .unknown }
            frontier.append(contentsOf: change.deps)
        }
        return requiredHeads.isSubset(of: reachable) ? .contained : .missing
    }

    func snapshot(
        pendingOperationIDs: [UUID],
        syncIssue: SharedPlanSyncIssue? = nil,
        localEditLimit: SharedPlanLocalEditLimit? = nil
    ) -> SharedPlanDocumentSnapshot {
        SharedPlanDocumentSnapshot(
            planID: planID,
            replicaID: replicaID,
            actorID: document.actor.description.lowercased(),
            document: document.save(),
            pendingOperationIDs: pendingOperationIDs,
            syncIssue: syncIssue,
            localEditLimit: localEditLimit,
            offlineMutationAuthority: offlineMutationAuthority
        )
    }

    /// Applies a domain mutation to an isolated clone, persists the clone and
    /// its semantic operation, and only then swaps it into the live actor.
    /// Reads continue to see the prior document while persistence is pending.
    func performDurableMutation(
        _ mutation: SharedPlanDurableMutation,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        pendingOperationIDs: [UUID],
        persist: @Sendable (
            SharedPlanDocumentSnapshot,
            [SharedPlanCircleKey]
        ) async throws -> Void
    ) async throws -> SharedPlanDurableMutationResult? {
        guard pendingOperationIDs.count <= Self.maximumUnacknowledgedOperations else {
            throw SharedPlanError.planSyncBacklogLimit(
                maximum: Self.maximumUnacknowledgedOperations,
                received: pendingOperationIDs.count
            )
        }
        guard !isPersistingDurableMutation else {
            throw SharedPlanError.persistenceFailed
        }
        isPersistingDurableMutation = true
        defer { isPersistingDurableMutation = false }

        let liveDocument = document
        let liveCirclesObject = circlesObject
        let liveOperationsObject = operationsObject
        let liveRetainedPayloadBytes = try retainedOperationPayloadBytes()
        let stagedDocument = try Document(liveDocument.save())
        stagedDocument.actor = ActorId(uuid: replicaID)
        let stagedMetadata = try Self.metadata(in: stagedDocument)
        document = stagedDocument
        circlesObject = stagedMetadata.circles
        operationsObject = stagedMetadata.operations
        // Do not query the staged clone's heads before its first write:
        // Automerge Swift can otherwise materialize an empty actor change.
        pendingRetainedPayloadBytes = liveRetainedPayloadBytes

        do {
            let changed = try apply(
                mutation,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: true
            )
            guard changed else {
                pendingRetainedPayloadBytes = nil
                document = liveDocument
                circlesObject = liveCirclesObject
                operationsObject = liveOperationsObject
                return nil
            }

            let result = SharedPlanDurableMutationResult(
                snapshot: snapshot(
                    pendingOperationIDs: pendingOperationIDs,
                    localEditLimit: pendingOperationIDs.count
                        == Self.maximumUnacknowledgedOperations
                        ? .syncBacklog(
                            maximum: Self.maximumUnacknowledgedOperations,
                            pending: pendingOperationIDs.count
                        )
                        : nil
                ),
                circleKeys: try circleKeys()
            )
            // The unpersisted clone must not be observable during this await.
            document = liveDocument
            circlesObject = liveCirclesObject
            operationsObject = liveOperationsObject
            try await persist(result.snapshot, result.circleKeys)

            document = stagedDocument
            circlesObject = stagedMetadata.circles
            operationsObject = stagedMetadata.operations
            // SyncState belongs to the previous in-memory document. A caller
            // reconnects with fresh state and new raw frame IDs.
            syncStates.removeAll()
            return result
        } catch {
            pendingRetainedPayloadBytes = nil
            document = liveDocument
            circlesObject = liveCirclesObject
            operationsObject = liveOperationsObject
            throw error
        }
    }

    /// Replays one already-durable semantic operation into a fresh
    /// server-authored bootstrap during an explicit user-requested rebase.
    /// The caller persists and publishes the fully rebuilt document only after
    /// every operation has applied successfully.
    func applyRebasedMutation(
        _ mutation: SharedPlanDurableMutation,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date
    ) throws -> Bool {
        try apply(
            mutation,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            allowingDurableMutation: false
        )
    }

    private func apply(
        _ mutation: SharedPlanDurableMutation,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool
    ) throws -> Bool {
        switch mutation {
        case .setCirclePresence(let key, let state):
            try setCirclePresence(
                state,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .replaceMemo(let value, let key):
            try updateMemo(
                value,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .spliceMemo(let key, let index, let deleteCount, let text):
            try spliceMemo(
                for: key,
                index: index,
                deleteCount: deleteCount,
                text: text,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .createNeed(let need, let key):
            try createNeed(
                need,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .setPurchaseNeed(let need, let key):
            try setPurchaseNeed(
                need,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .deleteNeed(let needID, let key):
            try deleteNeed(
                needID,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .setWantedQuantity(let quantity, let needID, let key):
            try setWantedQuantity(
                quantity,
                needID: needID,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .setBuyerAllocation(let quantity, let buyerID, let needID, let key):
            try setBuyerAllocation(
                quantity,
                buyerUserID: buyerID,
                needID: needID,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .setFulfilledQuantity(let quantity, let needID, let key):
            try setFulfilledQuantity(
                quantity,
                needID: needID,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .setCommunication(let value, let communicationKey, let key):
            try setCommunication(
                value,
                key: communicationKey,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .resolveCircleParent(
            let key,
            let selectedParentOperationID,
            let state,
            let nestedResolutions
        ):
            try resolveCircleParent(
                key,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        case .resolveNeedParent(
            let needID,
            let key,
            let selectedParentOperationID,
            let state,
            let nestedResolutions
        ):
            try resolveNeedParent(
                needID,
                circle: key,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        }
    }

    func circleKeys() throws -> [SharedPlanCircleKey] {
        try allCircleEntries().compactMap { key, circleObject in
            guard try presence(for: circleObject) != .removed else { return nil }
            return try circleKey(for: circleObject, fallbackWCID: key)
        }
        .sorted { $0.wcID < $1.wcID }
    }

    func presence(for key: SharedPlanCircleKey) throws -> SharedPlanCirclePresence? {
        try validate(key)
        guard let circleObject = try circleObject(for: key) else { return nil }
        return try presence(for: circleObject)
    }

    /// The visible register value is used only to author an explicit scalar
    /// resolution. Conflict inventory remains the authority for every
    /// competing candidate; this accessor never hides or resolves the conflict.
    func visiblePresenceState(for key: SharedPlanCircleKey) throws -> SharedPlanPresenceState? {
        try validate(key)
        guard let circle = try circleObject(for: key),
              let presence = try mapObject(in: circle, key: Key.presence),
              let state = try Self.string(
                  in: document,
                  object: presence,
                  key: Key.state
              )
        else { return nil }
        return SharedPlanPresenceState(rawValue: state)
    }

    /// Returns retained text even when the circle is logically removed. This is
    /// necessary to surface and resolve deletion-versus-descendant-edit races.
    func memo(for key: SharedPlanCircleKey) throws -> String? {
        guard let circleObject = try circleObject(for: key),
              case let .Object(textObject, .Text) = try document.get(
                  obj: circleObject,
                  key: Key.memo
              )
        else { return nil }
        return try document.text(obj: textObject)
    }

    func purchaseNeed(
        id: UUID,
        circleKey: SharedPlanCircleKey
    ) throws -> SharedPlanPurchaseNeed? {
        guard let circleObject = try circleObject(for: circleKey),
              let needsObject = try mapObject(in: circleObject, key: Key.needs),
              let needObject = try mapObject(
                  in: needsObject,
                  key: id.uuidString.lowercased()
              ),
              let requester = try Self.string(
                  in: document,
                  object: needObject,
                  key: Key.requesterUserID
              ),
              let wanted = Self.int(
                  in: document,
                  object: needObject,
                  key: Key.wantedQuantity
              ),
              let fulfilled = Self.int(
                  in: document,
                  object: needObject,
                  key: Key.fulfilledQuantity
              ),
              let allocationsObject = try mapObject(
                  in: needObject,
                  key: Key.buyerAllocations
              )
        else { return nil }

        let itemName: String
        if try document.get(obj: needObject, key: Key.itemName) != nil {
            guard let storedItemName = try Self.string(
                in: document,
                object: needObject,
                key: Key.itemName
            ) else { return nil }
            itemName = storedItemName
        } else {
            itemName = ""
        }
        let unitPrice: Int?
        switch try document.get(obj: needObject, key: Key.unitPrice) {
        case let .Scalar(.Int(rawPrice)):
            guard let exactPrice = Int(exactly: rawPrice) else { return nil }
            unitPrice = exactPrice
        case .Scalar(.Null), nil:
            unitPrice = nil
        default:
            return nil
        }

        let allocations = try document.mapEntries(obj: allocationsObject).reduce(
            into: [String: Int]()
        ) { result, entry in
            guard case let .Scalar(.Int(quantity)) = entry.1,
                  let exact = Int(exactly: quantity)
            else { return }
            result[entry.0] = exact
        }
        return SharedPlanPurchaseNeed(
            id: id,
            requesterUserID: requester,
            itemName: itemName,
            unitPrice: unitPrice,
            wantedQuantity: wanted,
            buyerAllocations: allocations,
            fulfilledQuantity: fulfilled
        )
    }

    func circleContent(for key: SharedPlanCircleKey) throws -> SharedPlanCircleContent? {
        try validate(key)
        guard let circleObject = try circleObject(for: key) else { return nil }
        let circlePresence = try presence(for: circleObject)
        let memo = try memo(for: key) ?? ""

        var needs: [SharedPlanPurchaseNeed] = []
        if let needsObject = try mapObject(in: circleObject, key: Key.needs) {
            for rawID in document.keys(obj: needsObject).sorted() {
                guard let id = UUID(uuidString: rawID),
                      let needObject = try mapObject(in: needsObject, key: rawID),
                      try needPresence(in: needObject) == .active,
                      let need = try purchaseNeed(id: id, circleKey: key)
                else { continue }
                needs.append(need)
            }
        }

        var communication: [String: SharedPlanJSONValue] = [:]
        if let communicationObject = try mapObject(
            in: circleObject,
            key: Key.communicationState
        ) {
            for (field, value) in try document.mapEntries(obj: communicationObject) {
                communication[field] = try jsonValue(for: value)
            }
        }

        return SharedPlanCircleContent(
            key: key,
            presence: circlePresence,
            memo: memo,
            needs: needs,
            communicationState: communication
        )
    }

    @discardableResult
    func addCircle(
        _ key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try setCirclePresence(
            .active,
            for: key,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            allowingDurableMutation: allowingDurableMutation
        )
    }

    @discardableResult
    func removeCircle(
        _ key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try setCirclePresence(
            .removed,
            for: key,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            allowingDurableMutation: allowingDurableMutation
        )
    }

    @discardableResult
    func setCirclePresence(
        _ state: SharedPlanPresenceState,
        for key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validate(key)
        let existing = try circleObject(for: key)
        if existing == nil {
            guard state == .active else { return false }
            guard document.keys(obj: circlesObject).count < Self.maximumCircles else {
                throw SharedPlanError.documentLimit(
                    String(localized: "1つのプランに追加できるサークルは2,000件までです。")
                )
            }
        } else if let existing,
                  try presence(for: existing) == (state == .active ? .present : .removed),
                  try document.getAll(obj: existing, key: Key.presence).count == 1,
                  try !hasUnresolvedRemovalVersusEditConflict(
                      at: [Key.circles, String(key.wcID), Key.presence]
                  )
        {
            return false
        }

        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if let circle = existing {
                try replacePresence(in: circle, state: state, operationID: operationID)
            } else {
                let circle = try document.putObject(
                    obj: circlesObject,
                    key: String(key.wcID),
                    ty: .Map
                )
                try document.put(
                    obj: circle,
                    key: Key.comiketNo,
                    value: .Int(Int64(key.comiketNo))
                )
                try document.put(
                    obj: circle,
                    key: Key.circleWCID,
                    value: .Int(Int64(key.wcID))
                )
                try putText(operationID.uuidString.lowercased(), in: circle, key: Key.rootOperationID)
                try replacePresence(in: circle, state: state, operationID: operationID)
                _ = try document.putObject(obj: circle, key: Key.memo, ty: .Text)
                _ = try document.putObject(obj: circle, key: Key.needs, ty: .Map)
                _ = try document.putObject(obj: circle, key: Key.communicationState, ty: .Map)
            }
            try appendOperation(
                id: operationID,
                type: .circlePresence,
                actorUserID: actorUserID,
                payload: [
                    Key.version: .integer(Self.schemaVersion),
                    Key.wcID: .integer(Int64(key.wcID)),
                    Key.state: .string(state.rawValue),
                ]
            )
        }
        return true
    }

    @discardableResult
    func updateMemo(
        _ value: String,
        for key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        guard let previous = try memo(for: key), previous != value else { return false }
        let patch = Self.textPatch(from: previous, to: value)
        return try spliceMemo(
            for: key,
            index: Int(patch.start),
            deleteCount: Int(patch.deleteCount),
            text: patch.insert,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            allowingDurableMutation: allowingDurableMutation
        )
    }

    @discardableResult
    func spliceMemo(
        for key: SharedPlanCircleKey,
        index: Int,
        deleteCount: Int,
        text: String,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validate(key)
        guard index >= 0, deleteCount >= 0, deleteCount > 0 || !text.isEmpty,
              let circle = try activeCircleObject(for: key),
              case let .Object(memoObject, .Text) = try document.get(obj: circle, key: Key.memo)
        else { throw SharedPlanError.planNotFound }
        let current = try document.text(obj: memoObject)
        let scalarCount = current.unicodeScalars.count
        guard index <= scalarCount, deleteCount <= scalarCount - index else {
            throw SharedPlanError.syncProtocolViolation
        }
        var prospective = current
        let lower = prospective.unicodeScalars.index(
            prospective.unicodeScalars.startIndex,
            offsetBy: index
        )
        let upper = prospective.unicodeScalars.index(lower, offsetBy: deleteCount)
        prospective.replaceSubrange(lower..<upper, with: text)
        guard prospective.utf8.count <= Self.maximumMemoUTF8Bytes else {
            throw SharedPlanError.documentLimit(String(localized: "メモは64 KiB以内にしてください。"))
        }

        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            try document.spliceText(
                obj: memoObject,
                start: UInt64(index),
                delete: Int64(deleteCount),
                value: text
            )
            try appendOperation(
                id: operationID,
                type: .circleMemoSplice,
                actorUserID: actorUserID,
                payload: [
                    Key.version: .integer(Self.schemaVersion),
                    Key.wcID: .integer(Int64(key.wcID)),
                    Key.index: .integer(Int64(index)),
                    Key.deleteCount: .integer(Int64(deleteCount)),
                    Key.text: .string(text),
                ]
            )
        }
        return true
    }

    @discardableResult
    func setPurchaseNeed(
        _ need: SharedPlanPurchaseNeed,
        for key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try validate(need)
        guard let current = try purchaseNeed(id: need.id, circleKey: key) else {
            return try createNeed(
                need,
                for: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        }
        if current == need { return false }
        let changedWanted = current.wantedQuantity != need.wantedQuantity
        let changedFulfilled = current.fulfilledQuantity != need.fulfilledQuantity
        let changedAllocations = current.buyerAllocations != need.buyerAllocations
        guard current.requesterUserID == need.requesterUserID,
              current.itemName == need.itemName,
              current.unitPrice == need.unitPrice,
              [changedWanted, changedFulfilled, changedAllocations].filter({ $0 }).count == 1
        else { throw SharedPlanError.syncProtocolViolation }
        if changedWanted {
            return try setWantedQuantity(
                need.wantedQuantity,
                needID: need.id,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        }
        if changedFulfilled {
            return try setFulfilledQuantity(
                need.fulfilledQuantity,
                needID: need.id,
                circle: key,
                operationID: operationID,
                actorUserID: actorUserID,
                authoredAt: authoredAt,
                allowingDurableMutation: allowingDurableMutation
            )
        }
        let changedBuyers = Set(current.buyerAllocations.keys)
            .union(need.buyerAllocations.keys)
            .filter { (current.buyerAllocations[$0] ?? 0) != (need.buyerAllocations[$0] ?? 0) }
        guard changedBuyers.count == 1, let buyer = changedBuyers.first else {
            throw SharedPlanError.syncProtocolViolation
        }
        return try setBuyerAllocation(
            need.buyerAllocations[buyer] ?? 0,
            buyerUserID: buyer,
            needID: need.id,
            circle: key,
            operationID: operationID,
            actorUserID: actorUserID,
            authoredAt: authoredAt,
            allowingDurableMutation: allowingDurableMutation
        )
    }

    @discardableResult
    func createNeed(
        _ need: SharedPlanPurchaseNeed,
        for key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validate(key)
        try validate(need)
        guard need.itemName.isEmpty || actorUserID == need.requesterUserID else {
            throw SharedPlanError.syncProtocolViolation
        }
        guard let circle = try activeCircleObject(for: key),
              let needs = try mapObject(in: circle, key: Key.needs)
        else { throw SharedPlanError.planNotFound }
        let needKey = need.id.uuidString.lowercased()
        let current = try mapObject(in: needs, key: needKey)
        if let current {
            let currentPresence = try needPresence(in: current)
            let hasSemanticConflict = try hasUnresolvedRemovalVersusEditConflict(
                at: [
                    Key.circles, String(key.wcID), Key.needs, needKey,
                    Key.presence,
                ]
            )
            if currentPresence == .active, !hasSemanticConflict {
                return false
            }
            // Reactivation intentionally changes only the root request details.
            // Descendant allocation/fulfillment state is
            // retained, so a full-model caller must not imply that this one
            // operation also rewrites those fields.
            guard let retained = try purchaseNeed(id: need.id, circleKey: key),
                  retained.buyerAllocations == need.buyerAllocations,
                  retained.fulfilledQuantity == need.fulfilledQuantity
            else { throw SharedPlanError.syncProtocolViolation }
        } else {
            // The frozen need.create topology always initializes these fields
            // to their defaults. Subsequent edits use their own operations.
            guard need.buyerAllocations.isEmpty, need.fulfilledQuantity == 0 else {
                throw SharedPlanError.syncProtocolViolation
            }
        }

        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if let current {
                try replacePresence(in: current, state: .active, operationID: operationID)
                try putText(need.requesterUserID, in: current, key: Key.requesterUserID)
                if !need.itemName.isEmpty {
                    try putText(need.itemName, in: current, key: Key.itemName)
                    try putOptionalPrice(need.unitPrice, in: current)
                }
                try document.put(
                    obj: current,
                    key: Key.wantedQuantity,
                    value: .Int(Int64(need.wantedQuantity))
                )
            } else {
                let created = try document.putObject(obj: needs, key: needKey, ty: .Map)
                try putText(operationID.uuidString.lowercased(), in: created, key: Key.rootOperationID)
                try replacePresence(in: created, state: .active, operationID: operationID)
                try putText(need.requesterUserID, in: created, key: Key.requesterUserID)
                if !need.itemName.isEmpty {
                    try putText(need.itemName, in: created, key: Key.itemName)
                    try putOptionalPrice(need.unitPrice, in: created)
                }
                try document.put(
                    obj: created,
                    key: Key.wantedQuantity,
                    value: .Int(Int64(need.wantedQuantity))
                )
                _ = try document.putObject(
                    obj: created,
                    key: Key.buyerAllocations,
                    ty: .Map
                )
                try document.put(
                    obj: created,
                    key: Key.fulfilledQuantity,
                    value: .Int(0)
                )
            }
            var payload: [String: SharedPlanJSONValue] = [
                Key.version: .integer(Self.schemaVersion),
                Key.wcID: .integer(Int64(key.wcID)),
                Key.needID: .string(needKey),
                Key.requesterUserID: .string(need.requesterUserID),
                Key.wantedQuantity: .integer(Int64(need.wantedQuantity)),
            ]
            if !need.itemName.isEmpty {
                payload[Key.itemName] = .string(need.itemName)
                payload[Key.unitPrice] = need.unitPrice.map {
                    .integer(Int64($0))
                } ?? .null
            }
            try appendOperation(
                id: operationID,
                type: .needCreate,
                actorUserID: actorUserID,
                payload: payload
            )
        }
        return true
    }

    @discardableResult
    func deleteNeed(
        _ needID: UUID,
        for key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validate(key)
        guard let circle = try activeCircleObject(for: key),
              let needs = try mapObject(in: circle, key: Key.needs),
              try document.getAll(
                  obj: needs,
                  key: needID.uuidString.lowercased()
              ).count == 1,
              let need = try mapObject(
                  in: needs,
                  key: needID.uuidString.lowercased()
              ),
              let currentPresence = try needPresence(in: need)
        else { return false }
        if currentPresence == .removed {
            guard try hasUnresolvedRemovalVersusEditConflict(
                at: [
                    Key.circles, String(key.wcID), Key.needs,
                    needID.uuidString.lowercased(), Key.presence,
                ]
            ) else { return false }
        }
        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            try replacePresence(in: need, state: .removed, operationID: operationID)
            try appendNeedOperation(
                id: operationID,
                type: .needDelete,
                actorUserID: actorUserID,
                circle: key,
                needID: needID,
                fields: [:]
            )
        }
        return true
    }

    @discardableResult
    func setWantedQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validateQuantity(quantity)
        guard let need = try activeNeedObject(id: needID, circle: key) else {
            throw SharedPlanError.planNotFound
        }
        let conflict = try document.getAll(obj: need, key: Key.wantedQuantity).count > 1
        let current = Self.int(in: document, object: need, key: Key.wantedQuantity)
        guard current != quantity || conflict
        else { return false }
        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if conflict, current == quantity {
                try document.delete(obj: need, key: Key.wantedQuantity)
            }
            try document.put(obj: need, key: Key.wantedQuantity, value: .Int(Int64(quantity)))
            try appendNeedOperation(
                id: operationID,
                type: .needWantedQuantity,
                actorUserID: actorUserID,
                circle: key,
                needID: needID,
                fields: [Key.wantedQuantity: .integer(Int64(quantity))]
            )
        }
        return true
    }

    @discardableResult
    func setBuyerAllocation(
        _ quantity: Int,
        buyerUserID: String,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validateQuantity(quantity)
        guard !buyerUserID.isEmpty,
              let need = try activeNeedObject(id: needID, circle: key),
              let allocations = try mapObject(in: need, key: Key.buyerAllocations)
        else { throw SharedPlanError.planNotFound }
        let existing = Self.int(in: document, object: allocations, key: buyerUserID) ?? 0
        let conflict = try document.getAll(obj: allocations, key: buyerUserID).count > 1
        guard existing != quantity || conflict else { return false }
        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if conflict, existing == quantity {
                try document.delete(obj: allocations, key: buyerUserID)
            }
            try document.put(obj: allocations, key: buyerUserID, value: .Int(Int64(quantity)))
            try appendNeedOperation(
                id: operationID,
                type: .needBuyerAllocation,
                actorUserID: actorUserID,
                circle: key,
                needID: needID,
                fields: [
                    Key.buyerUserID: .string(buyerUserID),
                    Key.quantity: .integer(Int64(quantity)),
                ]
            )
        }
        return true
    }

    @discardableResult
    func setFulfilledQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try validateQuantity(quantity)
        guard let need = try activeNeedObject(id: needID, circle: key) else {
            throw SharedPlanError.planNotFound
        }
        let conflict = try document.getAll(obj: need, key: Key.fulfilledQuantity).count > 1
        let current = Self.int(in: document, object: need, key: Key.fulfilledQuantity)
        guard current != quantity || conflict
        else { return false }
        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if conflict, current == quantity {
                try document.delete(obj: need, key: Key.fulfilledQuantity)
            }
            try document.put(obj: need, key: Key.fulfilledQuantity, value: .Int(Int64(quantity)))
            try appendNeedOperation(
                id: operationID,
                type: .needFulfilledQuantity,
                actorUserID: actorUserID,
                circle: key,
                needID: needID,
                fields: [Key.fulfilledQuantity: .integer(Int64(quantity))]
            )
        }
        return true
    }

    @discardableResult
    func setCommunication(
        _ value: SharedPlanJSONValue,
        key communicationKey: String,
        circle key: SharedPlanCircleKey,
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        guard Self.isValidCommunicationKey(communicationKey),
              Self.isCommunicationScalar(value),
              let circle = try activeCircleObject(for: key),
              let communication = try mapObject(in: circle, key: Key.communicationState)
        else { throw SharedPlanError.syncProtocolViolation }
        let current = try jsonValue(in: communication, key: communicationKey)
        let conflict = try document.getAll(obj: communication, key: communicationKey).count > 1
        guard current != value || conflict else { return false }
        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            if conflict, current == value {
                try document.delete(obj: communication, key: communicationKey)
            }
            try putJSON(value, in: communication, key: communicationKey)
            try appendOperation(
                id: operationID,
                type: .circleCommunicationSet,
                actorUserID: actorUserID,
                payload: [
                    Key.version: .integer(Self.schemaVersion),
                    Key.wcID: .integer(Int64(key.wcID)),
                    Key.key: .string(communicationKey),
                    Key.value: value,
                ]
            )
        }
        return true
    }

    @discardableResult
    func resolveCircleParent(
        _ key: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        try resolveParent(
            parent: circlesObject,
            key: String(key.wcID),
            selectedParentOperationID: selectedParentOperationID,
            state: state,
            nestedResolutions: nestedResolutions,
            operationID: operationID,
            actorUserID: actorUserID,
            type: .circleResolveParent,
            circle: key,
            needID: nil,
            authoredAt: authoredAt
        )
        return true
    }

    @discardableResult
    func resolveNeedParent(
        _ needID: UUID,
        circle key: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        operationID: UUID,
        actorUserID: String,
        authoredAt: Date,
        allowingDurableMutation: Bool = false
    ) throws -> Bool {
        try requireMutationAccess(allowingDurableMutation)
        guard let circle = try activeCircleObject(for: key),
              let needs = try mapObject(in: circle, key: Key.needs)
        else { throw SharedPlanError.planNotFound }
        try resolveParent(
            parent: needs,
            key: needID.uuidString.lowercased(),
            selectedParentOperationID: selectedParentOperationID,
            state: state,
            nestedResolutions: nestedResolutions,
            operationID: operationID,
            actorUserID: actorUserID,
            type: .needResolveParent,
            circle: key,
            needID: needID,
            authoredAt: authoredAt
        )
        return true
    }

    func semanticOperationIDs() -> Set<UUID> {
        Set(document.keys(obj: operationsObject).compactMap(UUID.init(uuidString:)))
    }

    func historyCount() -> Int {
        document.getHistory().count
    }

    func encodedChanges(sinceHistoryIndex index: Int) throws -> [SharedPlanEncodedChange] {
        let history = document.getHistory()
        guard index >= 0, index <= history.count else {
            throw SharedPlanError.syncProtocolViolation
        }
        return try history.dropFirst(index).map { hash in
            guard let change = document.change(hash: hash) else {
                throw SharedPlanError.syncProtocolViolation
            }
            return SharedPlanEncodedChange(
                hash: hash.debugDescription,
                actorID: change.actorId.description.lowercased(),
                message: change.message,
                timestamp: change.timestamp,
                bytes: change.bytes
            )
        }
    }

    func operationRecords() throws -> [SharedPlanOperationRecord] {
        let changeHashes = try semanticOperationChangeHashes()
        return try decodedOperationRecords(changeHashes: changeHashes)
    }

    func conflictInventory() throws -> [SharedPlanDocumentConflict] {
        let currentHeads = heads()
        if conflictInventoryHeads == currentHeads {
            return cachedConflictInventory
        }
        let records = try operationRecords()
        let graph = try currentChangeGraph()
        let inventory = try buildConflictInventory(records: records, graph: graph)
        conflictInventoryHeads = currentHeads
        cachedConflictInventory = inventory
        return inventory
    }

    private func hasUnresolvedRemovalVersusEditConflict(
        at path: [String]
    ) throws -> Bool {
        try conflictInventory().contains {
            $0.kind == .removalVersusEdit && $0.path == path
        }
    }

    func circleParentResolutionInventory(
        _ key: SharedPlanCircleKey,
        selectedParentOperationID: UUID
    ) throws -> SharedPlanParentResolutionInventory {
        try validate(key)
        return try parentResolutionInventory(
            parent: circlesObject,
            key: String(key.wcID),
            basePath: [Key.circles, String(key.wcID)],
            selectedParentOperationID: selectedParentOperationID,
            kind: .circle
        )
    }

    func needParentResolutionInventory(
        _ needID: UUID,
        circle key: SharedPlanCircleKey,
        selectedParentOperationID: UUID
    ) throws -> SharedPlanParentResolutionInventory {
        guard let circle = try activeCircleObject(for: key),
              let needs = try mapObject(in: circle, key: Key.needs)
        else { throw SharedPlanError.planNotFound }
        return try parentResolutionInventory(
            parent: needs,
            key: needID.uuidString.lowercased(),
            basePath: [
                Key.circles, String(key.wcID), Key.needs,
                needID.uuidString.lowercased(),
            ],
            selectedParentOperationID: selectedParentOperationID,
            kind: .need
        )
    }

    private func decodedOperationRecords(
        changeHashes: [UUID: String]
    ) throws -> [SharedPlanOperationRecord] {
        return try document.mapEntries(obj: operationsObject).map {
            key, value -> SharedPlanOperationRecord in
            guard let id = UUID(uuidString: key),
                  key == id.uuidString.lowercased(),
                  case let .Object(operation, .Map) = value,
                  let typeString = try Self.string(
                      in: document,
                      object: operation,
                      key: Key.operationType
                  ),
                  let type = SharedPlanOperationType(rawValue: typeString),
                  let actorUserID = try Self.string(
                      in: document,
                      object: operation,
                      key: Key.actorUserID
                  ),
                  case let .Object(payloadObject, .Map) = try document.get(
                      obj: operation,
                      key: Key.payload
                  ),
                  case let .object(payload) = try jsonValue(
                      for: .Object(payloadObject, .Map)
                  )
            else { throw SharedPlanError.syncProtocolViolation }
            return SharedPlanOperationRecord(
                id: id,
                type: type,
                actorUserID: actorUserID,
                payload: payload,
                changeHash: changeHashes[id]
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func semanticOperationChangeHashes() throws -> [UUID: String] {
        let currentHeads = heads()
        if operationChangeHashHeads == currentHeads {
            return operationChangeHashes
        }

        let history = document.getHistory()
        guard !history.isEmpty else { throw SharedPlanError.syncProtocolViolation }
        let historyHashes = history.map(\.debugDescription)
        let canExtendCachedShadow = operationValidationShadow != nil
            && operationValidationGraph != nil
            && operationValidationHistoryHashes.count <= historyHashes.count
            && Array(historyHashes.prefix(operationValidationHistoryHashes.count))
                == operationValidationHistoryHashes

        let shadow: Document
        let graph: ChangeGraph
        var startIndex: Int
        var indexed: [UUID: String]
        if canExtendCachedShadow,
           let cached = operationValidationShadow,
           let cachedGraph = operationValidationGraph
        {
            shadow = cached.fork()
            graph = cachedGraph.copy()
            startIndex = operationValidationHistoryHashes.count
            indexed = operationChangeHashes
        } else {
            shadow = Document(textEncoding: .unicodeScalar)
            graph = ChangeGraph()
            startIndex = 0
            indexed = [:]
            indexed.reserveCapacity(document.keys(obj: operationsObject).count)
        }

        var shadowOperationsObject: ObjId?
        if startIndex > 0 {
            guard let metadata = try? Self.metadata(in: shadow),
                  metadata.planID == planID,
                  metadata.comiketNo == comiketNo
            else { throw SharedPlanError.syncProtocolViolation }
            shadowOperationsObject = metadata.operations
        }

        if startIndex == 0 {
            guard let bootstrapHash = history.first,
                  let bootstrap = document.change(hash: bootstrapHash)
            else { throw SharedPlanError.syncProtocolViolation }
            shadowOperationsObject = try Self.applyCanonicalBootstrap(
                bootstrap,
                to: shadow,
                expectedPlanID: planID,
                expectedComiketNo: comiketNo
            ).operations
            try graph.append(
                hash: bootstrapHash.debugDescription,
                dependencies: bootstrap.deps.map(\.debugDescription)
            )
            startIndex = 1
        }

        guard shadowOperationsObject != nil else {
            throw SharedPlanError.syncProtocolViolation
        }
        var candidates: [SemanticChangeCandidate] = []
        candidates.reserveCapacity(history.count - startIndex)
        var expectedOperationKeys = Set(
            indexed.keys.map { $0.uuidString.lowercased() }
        )
        expectedOperationKeys.reserveCapacity(
            indexed.count + history.count - startIndex
        )
        for index in startIndex..<history.count {
            let hash = history[index]
            guard let change = document.change(hash: hash),
                  let message = change.message,
                  message.hasPrefix(Self.semanticChangeMessagePrefix)
            else { throw SharedPlanError.syncProtocolViolation }
            let rawOperationID = String(
                message.dropFirst(Self.semanticChangeMessagePrefix.count)
            )
            guard let operationID = UUID(uuidString: rawOperationID),
                  rawOperationID == operationID.uuidString.lowercased(),
                  expectedOperationKeys.insert(rawOperationID).inserted
            else { throw SharedPlanError.syncProtocolViolation }
            try graph.append(
                hash: historyHashes[index],
                dependencies: change.deps.map(\.debugDescription)
            )
            candidates.append(SemanticChangeCandidate(
                operationID: operationID,
                rawOperationID: rawOperationID,
                changeHash: historyHashes[index],
                bytes: change.bytes
            ))
        }
        var validatedShadow = shadow
        if candidates.count < 512 {
            try indexed.merge(
                try Self.validateSemanticChanges(
                    candidates,
                    in: shadow,
                    expectedEndHeads: nil
                )
            ) { _, _ in throw SharedPlanError.syncProtocolViolation }
        } else {
            let processorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let chunkCount = min(16, processorCount, candidates.count)
            let chunkSize = (candidates.count + chunkCount - 1) / chunkCount
            let validationCount = (candidates.count + chunkSize - 1) / chunkSize
            let accumulator = SemanticValidationAccumulator(count: validationCount)
            let validationGroup = DispatchGroup()
            let checkpoint = shadow
            var validationIndex = 0
            for lowerBound in stride(
                from: 0,
                to: candidates.count,
                by: chunkSize
            ) {
                let upperBound = min(lowerBound + chunkSize, candidates.count)
                let chunkCandidates = Array(candidates[lowerBound..<upperBound])
                let chunkShadow = checkpoint.fork()
                var encoded = Data()
                encoded.reserveCapacity(
                    chunkCandidates.reduce(0) { $0 + $1.bytes.count }
                )
                for candidate in chunkCandidates {
                    encoded.append(candidate.bytes)
                }
                try checkpoint.applyEncodedChanges(encoded: encoded)
                let chunk = SemanticValidationChunk(
                    shadow: chunkShadow,
                    candidates: chunkCandidates,
                    expectedEndHeads: Self.headCacheKey(checkpoint)
                )
                let index = validationIndex
                validationIndex += 1
                validationGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { validationGroup.leave() }
                    do {
                        let result = try Self.validateSemanticChanges(
                            chunk.candidates,
                            in: chunk.shadow,
                            expectedEndHeads: chunk.expectedEndHeads
                        )
                        accumulator.record(result, at: index)
                    } catch {
                        accumulator.recordFailure()
                    }
                }
            }
            guard validationIndex == validationCount else {
                throw SharedPlanError.syncProtocolViolation
            }
            validationGroup.wait()
            guard let validated = accumulator.combined(),
                  validated.count == candidates.count
            else { throw SharedPlanError.syncProtocolViolation }
            try indexed.merge(validated) { _, _ in
                throw SharedPlanError.syncProtocolViolation
            }
            // The checkpoint document is the same causally ordered replay the
            // workers proved, without another save/load of the near-cap state.
            validatedShadow = checkpoint
        }

        guard graph.count == history.count,
              Self.headCacheKey(validatedShadow) == Self.headCacheKey(document),
              let shadowMetadata = try? Self.validateRetainedRootTopology(
                  in: validatedShadow,
                  expectedPlanID: planID,
                  expectedComiketNo: comiketNo
              )
        else { throw SharedPlanError.syncProtocolViolation }

        // ObjId stores Automerge's actor-table index. Applying a change from an
        // actor that sorts before an existing actor can reindex an otherwise
        // unchanged object, so only IDs read from the current document state
        // may be used after replay.
        let operationKeys = Set(
            validatedShadow.keys(obj: shadowMetadata.operations)
        )
        guard operationKeys.count == indexed.count,
              operationKeys == expectedOperationKeys
        else { throw SharedPlanError.syncProtocolViolation }

        operationChangeHashes = indexed
        operationChangeHashHeads = currentHeads
        operationValidationShadow = validatedShadow
        operationValidationHistoryHashes = historyHashes
        operationValidationGraph = graph
        return operationChangeHashes
    }

    private func currentChangeGraph() throws -> ChangeGraph {
        _ = try semanticOperationChangeHashes()
        guard operationChangeHashHeads == heads(),
              let graph = operationValidationGraph
        else { throw SharedPlanError.syncProtocolViolation }
        return graph
    }

    private nonisolated static func validateSemanticChanges(
        _ candidates: [SemanticChangeCandidate],
        in shadow: Document,
        expectedEndHeads: String?
    ) throws -> [UUID: String] {
        var operations = try Self.requiredMapObject(
            in: shadow,
            parent: .ROOT,
            key: Key.operations
        )
        var indexed: [UUID: String] = [:]
        indexed.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard try shadow.get(
                obj: operations,
                key: candidate.rawOperationID
            ) == nil else { throw SharedPlanError.syncProtocolViolation }
            let patches = try shadow.applyEncodedChangesWithPatches(
                encoded: candidate.bytes
            )
            var candidatePutObject: ObjId?
            var operationMapPatchCount = 0
            for patch in patches {
                if Self.patch(patch, mutates: operations) {
                    operationMapPatchCount += 1
                }
                if case let .Put(object, .Key(key), .Object(_, .Map))
                    = patch.action,
                   key == candidate.rawOperationID
                {
                    guard candidatePutObject == nil else {
                        throw SharedPlanError.syncProtocolViolation
                    }
                    candidatePutObject = object
                }
            }
            guard let candidatePutObject
            else { throw SharedPlanError.syncProtocolViolation }

            if candidatePutObject != operations {
                // Applying a lower-sorting actor can reindex an unchanged
                // Automerge ObjId. Refresh ROOT only on that uncommon path and
                // prove the candidate patch targets the retained operations
                // map, rather than accepting an arbitrary nested UUID key.
                let refreshedOperations = try Self.requiredMapObject(
                    in: shadow,
                    parent: .ROOT,
                    key: Key.operations
                )
                guard refreshedOperations == candidatePutObject else {
                    throw SharedPlanError.syncProtocolViolation
                }
                operations = refreshedOperations
                operationMapPatchCount = patches.reduce(into: 0) { count, patch in
                    if Self.patch(patch, mutates: operations) {
                        count += 1
                    }
                }
            }
            guard operationMapPatchCount == 1,
                  candidatePutObject == operations,
                  case .Object(_, .Map) = try shadow.get(
                      obj: operations,
                      key: candidate.rawOperationID
                  ),
                  indexed.updateValue(
                      candidate.changeHash,
                      forKey: candidate.operationID
                  ) == nil
            else { throw SharedPlanError.syncProtocolViolation }
        }
        if let expectedEndHeads {
            guard Self.headCacheKey(shadow) == expectedEndHeads else {
                throw SharedPlanError.syncProtocolViolation
            }
        }
        return indexed
    }

    private static func patch(_ patch: Patch, mutates object: ObjId) -> Bool {
        switch patch.action {
        case let .Put(candidate, _, _),
             let .Increment(candidate, _, _),
             let .DeleteMap(candidate, _),
             let .Conflict(candidate, _):
            candidate == object
        case let .Insert(candidate, _, _),
             let .SpliceText(candidate, _, _, _),
             let .Marks(candidate, _):
            candidate == object
        case let .DeleteSeq(deletion):
            deletion.obj == object
        }
    }

    private static func requiredMapObject(
        in document: Document,
        parent: ObjId,
        key: String
    ) throws -> ObjId {
        guard case let .Object(object, .Map) = try document.get(
            obj: parent,
            key: key
        )
        else { throw SharedPlanError.syncProtocolViolation }
        return object
    }

    func hasConcurrentRootObjects() throws -> Bool {
        try document.getAll(obj: .ROOT, key: Key.circles).count != 1
            || document.getAll(obj: .ROOT, key: Key.operations).count != 1
    }

    func merge(_ remoteData: Data) throws {
        guard !isPersistingDurableMutation else {
            throw SharedPlanError.syncProtocolViolation
        }
        let remote = try Document(remoteData)
        let remoteMetadata = try Self.metadata(in: remote)
        guard remoteMetadata.planID == planID, remoteMetadata.comiketNo == comiketNo else {
            throw SharedPlanError.eventMismatch(
                expected: comiketNo,
                received: remoteMetadata.comiketNo
            )
        }
        let backup = document.save()
        do {
            try document.merge(other: remote)
            document.actor = ActorId(uuid: replicaID)
            try validateBounds()
        } catch {
            try restore(from: backup)
            throw error
        }
    }

    /// Applies a length-delimited Automerge change sequence. This is used by
    /// literal cross-language vectors and by reconnect bootstrap merging; the
    /// document is rolled back if metadata or bounds validation fails.
    func applyEncodedChanges(_ encoded: Data) throws {
        guard !isPersistingDurableMutation else {
            throw SharedPlanError.syncProtocolViolation
        }
        let backup = document.save()
        do {
            try document.applyEncodedChanges(encoded: encoded)
            document.actor = ActorId(uuid: replicaID)
            let metadata = try Self.metadata(in: document)
            guard metadata.planID == planID, metadata.comiketNo == comiketNo else {
                throw SharedPlanError.persistenceFailed
            }
            circlesObject = metadata.circles
            operationsObject = metadata.operations
            try validateBounds()
            syncStates.removeAll()
        } catch {
            try restore(from: backup)
            throw error
        }
    }

    // MARK: Ordered-session sync state

    func beginSyncSession(id: UUID) {
        guard !isPersistingDurableMutation else { return }
        syncStates[id] = SyncState()
    }

    func endSyncSession(id: UUID) {
        syncStates[id] = nil
    }

    func endAllSyncSessions() {
        syncStates.removeAll()
    }

    func generateSyncMessage(sessionID: UUID) throws -> Data? {
        guard !isPersistingDurableMutation else {
            throw SharedPlanError.syncProtocolViolation
        }
        guard let state = syncStates[sessionID] else {
            throw SharedPlanError.syncProtocolViolation
        }
        guard let message = document.generateSyncMessage(state: state) else { return nil }
        guard message.count <= Self.maximumDecodedSyncMessageBytes else {
            // SyncState has already advanced and its encoded form intentionally
            // omits live ordered-session fields, so it cannot be rolled back.
            // Invalidate it and require a fresh hello instead of continuing a
            // contaminated reliable session.
            syncStates[sessionID] = nil
            throw SharedPlanError.syncPayloadTooLarge
        }
        return message
    }

    func receiveSyncMessage(sessionID: UUID, message: Data) throws {
        guard !isPersistingDurableMutation else {
            throw SharedPlanError.syncProtocolViolation
        }
        guard let state = syncStates[sessionID] else {
            throw SharedPlanError.syncProtocolViolation
        }
        guard message.count <= Self.maximumDecodedSyncMessageBytes else {
            throw SharedPlanError.syncPayloadTooLarge
        }
        let backup = document.save()
        do {
            try document.receiveSyncMessage(state: state, message: message)
            try validateBounds()
        } catch {
            syncStates[sessionID] = nil
            try restore(from: backup)
            throw error
        }
    }

    /// Applies one peer message to an isolated document clone, durably saves
    /// the merged bytes and semantic ledger, and only then publishes the new
    /// in-memory document. Session SyncState advances with the staged clone;
    /// any validation or persistence failure invalidates that ephemeral state
    /// and leaves the previously persisted/live document untouched.
    func receiveSyncMessageDurably(
        sessionID: UUID,
        message: Data,
        pendingOperationIDs: [UUID],
        syncIssue: SharedPlanSyncIssue?,
        localEditLimit: SharedPlanLocalEditLimit?,
        persist: @Sendable (
            SharedPlanDocumentSnapshot,
            [SharedPlanCircleKey]
        ) async throws -> Void
    ) async throws {
        guard !isPersistingDurableMutation,
              let state = syncStates[sessionID]
        else { throw SharedPlanError.syncProtocolViolation }
        guard message.count <= Self.maximumDecodedSyncMessageBytes else {
            throw SharedPlanError.syncPayloadTooLarge
        }
        isPersistingDurableMutation = true
        defer { isPersistingDurableMutation = false }

        let liveDocument = document
        let liveCirclesObject = circlesObject
        let liveOperationsObject = operationsObject
        let liveOperationChangeHashes = operationChangeHashes
        let liveOperationChangeHashHeads = operationChangeHashHeads
        let liveOperationValidationShadow = operationValidationShadow
        let liveOperationValidationHistoryHashes = operationValidationHistoryHashes
        let liveOperationValidationGraph = operationValidationGraph
        let liveConflictInventoryHeads = conflictInventoryHeads
        let liveCachedConflictInventory = cachedConflictInventory
        let liveRetainedPayloadBytesByHeads = retainedPayloadBytesByHeads
        let livePendingRetainedPayloadBytes = pendingRetainedPayloadBytes
        let stagedDocument = try Document(liveDocument.save())
        stagedDocument.actor = ActorId(uuid: replicaID)

        do {
            let initialMetadata = try Self.metadata(in: stagedDocument)
            document = stagedDocument
            circlesObject = initialMetadata.circles
            operationsObject = initialMetadata.operations

            try stagedDocument.receiveSyncMessage(state: state, message: message)
            stagedDocument.actor = ActorId(uuid: replicaID)
            let stagedMetadata = try Self.metadata(in: stagedDocument)
            guard stagedMetadata.planID == planID,
                  stagedMetadata.comiketNo == comiketNo
            else { throw SharedPlanError.persistenceFailed }
            circlesObject = stagedMetadata.circles
            operationsObject = stagedMetadata.operations
            try validateBounds()
            _ = try Self.validateRetainedRootTopology(
                in: stagedDocument,
                expectedPlanID: planID,
                expectedComiketNo: comiketNo
            )
            _ = try semanticOperationChangeHashes()

            let stagedSnapshot = snapshot(
                pendingOperationIDs: pendingOperationIDs,
                syncIssue: syncIssue,
                localEditLimit: localEditLimit
            )
            let stagedCircleKeys = try circleKeys()

            // Keep reads on the last durable document while SQLite commits.
            document = liveDocument
            circlesObject = liveCirclesObject
            operationsObject = liveOperationsObject
            try await persist(stagedSnapshot, stagedCircleKeys)

            document = stagedDocument
            circlesObject = stagedMetadata.circles
            operationsObject = stagedMetadata.operations
        } catch {
            document = liveDocument
            circlesObject = liveCirclesObject
            operationsObject = liveOperationsObject
            operationChangeHashes = liveOperationChangeHashes
            operationChangeHashHeads = liveOperationChangeHashHeads
            operationValidationShadow = liveOperationValidationShadow
            operationValidationHistoryHashes = liveOperationValidationHistoryHashes
            operationValidationGraph = liveOperationValidationGraph
            conflictInventoryHeads = liveConflictInventoryHeads
            cachedConflictInventory = liveCachedConflictInventory
            retainedPayloadBytesByHeads = liveRetainedPayloadBytesByHeads
            pendingRetainedPayloadBytes = livePendingRetainedPayloadBytes
            syncStates[sessionID] = nil
            throw error
        }
    }

    private enum ParentKind {
        case circle
        case need
    }

    private struct ParentCandidate {
        let object: ObjId
        let rootOperationID: UUID
        let assignment: SharedPlanConflictCandidate
        let decoded: [String: SharedPlanJSONValue]
    }

    private struct LedgerAssignment {
        let path: [String]
        let candidate: SharedPlanConflictCandidate
    }

    /// Compact change-graph index. It retains only direct adjacency and uses
    /// targeted backwards reachability, avoiding one transitive ancestor set
    /// per change (quadratic memory at the legal 10,000-change boundary).
    private final class ChangeGraph {
        private struct ReachabilityKey: Hashable {
            let descendant: String
            let ancestor: String
        }

        private var dependencies: [String: [String]]
        private var topologicalIndex: [String: Int]
        private var reachabilityCache: [ReachabilityKey: Bool] = [:]
        private var reachabilityCacheOrder: [ReachabilityKey] = []
        private let maximumCachedQueries = 4_096

        init() {
            dependencies = [:]
            topologicalIndex = [:]
        }

        init(document: Document) throws {
            dependencies = [:]
            topologicalIndex = [:]
            let history = document.getHistory()
            dependencies.reserveCapacity(history.count)
            topologicalIndex.reserveCapacity(history.count)
            for hash in history {
                guard let change = document.change(hash: hash) else {
                    throw SharedPlanError.syncProtocolViolation
                }
                try append(
                    hash: hash.debugDescription,
                    dependencies: change.deps.map(\.debugDescription)
                )
            }
        }

        var count: Int { topologicalIndex.count }

        func copy() -> ChangeGraph {
            let copy = ChangeGraph()
            copy.dependencies = dependencies
            copy.topologicalIndex = topologicalIndex
            return copy
        }

        func append(hash: String, dependencies: [String]) throws {
            guard topologicalIndex[hash] == nil,
                  dependencies.allSatisfy({ topologicalIndex[$0] != nil })
            else { throw SharedPlanError.syncProtocolViolation }
            self.dependencies[hash] = dependencies
            topologicalIndex[hash] = topologicalIndex.count
        }

        func descends(_ descendant: String, from ancestor: String) -> Bool {
            guard let descendantIndex = topologicalIndex[descendant],
                  let ancestorIndex = topologicalIndex[ancestor]
            else { return false }
            if descendant == ancestor { return true }
            if descendantIndex <= ancestorIndex { return false }
            let cacheKey = ReachabilityKey(descendant: descendant, ancestor: ancestor)
            if let cached = reachabilityCache[cacheKey] { return cached }

            var visited: Set<String> = []
            var pending = dependencies[descendant] ?? []
            var found = false
            while let hash = pending.popLast() {
                if hash == ancestor {
                    found = true
                    break
                }
                guard let index = topologicalIndex[hash],
                      index > ancestorIndex,
                      visited.insert(hash).inserted
                else { continue }
                pending.append(contentsOf: dependencies[hash] ?? [])
            }
            cache(cacheKey, value: found)
            return found
        }

        func concurrent(_ left: String, _ right: String) -> Bool {
            left != right && !descends(left, from: right) && !descends(right, from: left)
        }

        func descendsFromBoth(_ descendant: String, _ left: String, _ right: String) -> Bool {
            descendant != left && descendant != right
                && descends(descendant, from: left)
                && descends(descendant, from: right)
        }

        func maximalCandidates(
            _ candidates: [SharedPlanConflictCandidate]
        ) -> [SharedPlanConflictCandidate] {
            var frontier: [SharedPlanConflictCandidate] = []
            for candidate in candidates.sorted(by: {
                (topologicalIndex[$0.changeHash] ?? .max)
                    < (topologicalIndex[$1.changeHash] ?? .max)
            }) {
                if frontier.contains(where: {
                    descends($0.changeHash, from: candidate.changeHash)
                }) {
                    continue
                }
                frontier.removeAll {
                    descends(candidate.changeHash, from: $0.changeHash)
                }
                frontier.append(candidate)
            }
            return frontier.sorted { $0.changeHash < $1.changeHash }
        }

        func topologicalIndex(of hash: String) -> Int? {
            topologicalIndex[hash]
        }

        private func cache(_ key: ReachabilityKey, value: Bool) {
            if reachabilityCache[key] == nil {
                reachabilityCacheOrder.append(key)
            }
            reachabilityCache[key] = value
            if reachabilityCacheOrder.count > maximumCachedQueries {
                let overflow = reachabilityCacheOrder.count - maximumCachedQueries
                let evicted = Array(reachabilityCacheOrder.prefix(overflow))
                reachabilityCacheOrder.removeFirst(overflow)
                for key in evicted { reachabilityCache[key] = nil }
            }
        }
    }

    private struct TextPatch {
        let start: UInt64
        let deleteCount: Int64
        let insert: String
    }

    private func buildConflictInventory(
        records: [SharedPlanOperationRecord],
        graph: ChangeGraph
    ) throws -> [SharedPlanDocumentConflict] {
        let assignments = try ledgerAssignments(records: records)
        var conflicts: [String: SharedPlanDocumentConflict] = [:]

        func visit(
            object: ObjId,
            path: [String],
            branchRootHashes: [String]
        ) throws {
            for key in document.keys(obj: object).sorted() {
                if path.isEmpty, key == Key.operations { continue }
                let childPath = path + [key]
                let values = try document.getAll(obj: object, key: key)
                if Self.isParentPath(childPath), values.count > 1 {
                    let candidates = try parentCandidates(
                        parent: object,
                        key: key,
                        path: childPath,
                        records: records,
                        graph: graph
                    )
                    let conflict = try Self.makeConflict(
                        kind: .parent,
                        path: childPath,
                        candidates: candidates.map(\.assignment),
                        parentRootOperationIDs: candidates.map(\.rootOperationID)
                    )
                    conflicts[conflict.id] = conflict
                    if case let .Object(visibleObject, .Map) = try document.get(
                        obj: object,
                        key: key
                    ), let visible = candidates.first(where: {
                        $0.object == visibleObject
                    }) {
                        try visit(
                            object: visible.object,
                            path: childPath,
                            branchRootHashes: branchRootHashes
                                + [visible.assignment.changeHash]
                        )
                    }
                    continue
                } else if Self.isResolvableRegisterPath(childPath) {
                    let candidates = try registerCandidates(
                        path: childPath,
                        values: values,
                        assignments: assignments,
                        branchRootHashes: branchRootHashes,
                        graph: graph
                    )
                    if candidates.count > 1 {
                        let conflict = try Self.makeConflict(
                            kind: .scalar,
                            path: childPath,
                            candidates: candidates
                        )
                        conflicts[conflict.id] = conflict
                    }
                }

                guard case let .Object(child, objectType) = try document.get(
                    obj: object,
                    key: key
                ), objectType != .Text
                else { continue }
                var childRoots = branchRootHashes
                if Self.isParentPath(childPath), values.count > 1,
                   let decoded = try? jsonValue(for: .Object(child, .Map)),
                   case let .object(value) = decoded,
                   let rawRootID = value[Key.rootOperationID]?.stringValue,
                   let rootID = UUID(uuidString: rawRootID),
                   let selected = try parentCandidates(
                       parent: object,
                       key: key,
                       path: childPath,
                       records: records,
                       graph: graph
                   ).first(where: { $0.rootOperationID == rootID })
                {
                    childRoots.append(selected.assignment.changeHash)
                }
                try visit(object: child, path: childPath, branchRootHashes: childRoots)
            }
        }

        try visit(object: .ROOT, path: [], branchRootHashes: [])
        for conflict in try semanticDeletionConflicts(records: records, graph: graph) {
            conflicts[conflict.id] = conflict
        }
        return conflicts.values.sorted { $0.conflictID < $1.conflictID }
    }

    private func ledgerAssignments(
        records: [SharedPlanOperationRecord]
    ) throws -> [LedgerAssignment] {
        try records.flatMap { record -> [LedgerAssignment] in
            guard let changeHash = record.changeHash,
                  let rawWCID = record.payload[Key.wcID]?.integerValue,
                  let wcID = Int(exactly: rawWCID)
            else { throw SharedPlanError.syncProtocolViolation }
            let circlePath = [Key.circles, String(wcID)]
            func candidate(
                _ value: SharedPlanJSONValue,
                rootOperationID: UUID? = nil
            ) -> SharedPlanConflictCandidate {
                SharedPlanConflictCandidate(
                    changeHash: changeHash,
                    operationID: record.id,
                    actorUserID: record.actorUserID,
                    value: value,
                    rootOperationID: rootOperationID
                )
            }
            func presence(_ state: SharedPlanPresenceState) -> SharedPlanJSONValue {
                .object([
                    Key.state: .string(state.rawValue),
                    Key.operationID: .string(record.id.uuidString.lowercased()),
                ])
            }
            switch record.type {
            case .circlePresence:
                guard let rawState = record.payload[Key.state]?.stringValue,
                      let state = SharedPlanPresenceState(rawValue: rawState)
                else { throw SharedPlanError.syncProtocolViolation }
                return [LedgerAssignment(
                    path: circlePath + [Key.presence],
                    candidate: candidate(presence(state), rootOperationID: record.id)
                )]
            case .circleResolveParent:
                guard let rawState = record.payload[Key.state]?.stringValue,
                      let state = SharedPlanPresenceState(rawValue: rawState),
                      let selected = record.payload[Key.selectedParentOperationID]?.stringValue,
                      let rootID = UUID(uuidString: selected)
                else { throw SharedPlanError.syncProtocolViolation }
                return [LedgerAssignment(
                    path: circlePath + [Key.presence],
                    candidate: candidate(presence(state), rootOperationID: rootID)
                )] + (try nestedAssignments(record: record, changeHash: changeHash))
            case .circleMemoSplice:
                return []
            case .needCreate:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                guard let requester = record.payload[Key.requesterUserID],
                      let wanted = record.payload[Key.wantedQuantity]
                else { throw SharedPlanError.syncProtocolViolation }
                let base = circlePath + [Key.needs, needID.uuidString.lowercased()]
                var assignments = [
                    LedgerAssignment(
                        path: base + [Key.presence],
                        candidate: candidate(
                            presence(.active),
                            rootOperationID: record.id
                        )
                    ),
                    LedgerAssignment(
                        path: base + [Key.requesterUserID],
                        candidate: candidate(requester, rootOperationID: record.id)
                    ),
                    LedgerAssignment(
                        path: base + [Key.wantedQuantity],
                        candidate: candidate(wanted, rootOperationID: record.id)
                    ),
                ]
                if let itemName = record.payload[Key.itemName] {
                    assignments.append(LedgerAssignment(
                        path: base + [Key.itemName],
                        candidate: candidate(itemName, rootOperationID: record.id)
                    ))
                }
                if let unitPrice = record.payload[Key.unitPrice] {
                    assignments.append(LedgerAssignment(
                        path: base + [Key.unitPrice],
                        candidate: candidate(unitPrice, rootOperationID: record.id)
                    ))
                }
                return assignments
            case .needDelete:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                return [LedgerAssignment(
                    path: circlePath + [
                        Key.needs, needID.uuidString.lowercased(), Key.presence,
                    ],
                    candidate: candidate(presence(.removed))
                )]
            case .needResolveParent:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                guard let rawState = record.payload[Key.state]?.stringValue,
                      let state = SharedPlanPresenceState(rawValue: rawState),
                      let selected = record.payload[Key.selectedParentOperationID]?.stringValue,
                      let rootID = UUID(uuidString: selected)
                else { throw SharedPlanError.syncProtocolViolation }
                return [LedgerAssignment(
                    path: circlePath + [
                        Key.needs, needID.uuidString.lowercased(), Key.presence,
                    ],
                    candidate: candidate(presence(state), rootOperationID: rootID)
                )] + (try nestedAssignments(record: record, changeHash: changeHash))
            case .needWantedQuantity:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                guard let value = record.payload[Key.wantedQuantity] else {
                    throw SharedPlanError.syncProtocolViolation
                }
                return [LedgerAssignment(
                    path: circlePath + [
                        Key.needs, needID.uuidString.lowercased(), Key.wantedQuantity,
                    ],
                    candidate: candidate(value)
                )]
            case .needBuyerAllocation:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                guard let buyerID = record.payload[Key.buyerUserID]?.stringValue,
                      let value = record.payload[Key.quantity]
                else { throw SharedPlanError.syncProtocolViolation }
                return [LedgerAssignment(
                    path: circlePath + [
                        Key.needs, needID.uuidString.lowercased(),
                        Key.buyerAllocations, buyerID,
                    ],
                    candidate: candidate(value)
                )]
            case .needFulfilledQuantity:
                let needID = try Self.requiredUUID(record.payload, key: Key.needID)
                guard let value = record.payload[Key.fulfilledQuantity] else {
                    throw SharedPlanError.syncProtocolViolation
                }
                return [LedgerAssignment(
                    path: circlePath + [
                        Key.needs, needID.uuidString.lowercased(), Key.fulfilledQuantity,
                    ],
                    candidate: candidate(value)
                )]
            case .circleCommunicationSet:
                guard let key = record.payload[Key.key]?.stringValue,
                      let value = record.payload[Key.value]
                else { throw SharedPlanError.syncProtocolViolation }
                return [LedgerAssignment(
                    path: circlePath + [Key.communicationState, key],
                    candidate: candidate(value)
                )]
            }
        }
    }

    private func nestedAssignments(
        record: SharedPlanOperationRecord,
        changeHash: String
    ) throws -> [LedgerAssignment] {
        guard let values = record.payload[Key.nestedResolutions]?.arrayValue else {
            throw SharedPlanError.syncProtocolViolation
        }
        return try values.map { raw in
            guard let object = raw.objectValue,
                  let pathValues = object[Key.path]?.arrayValue,
                  let value = object[Key.value]
            else { throw SharedPlanError.syncProtocolViolation }
            let path = try pathValues.map { component -> String in
                guard let string = component.stringValue else {
                    throw SharedPlanError.syncProtocolViolation
                }
                return string
            }
            return LedgerAssignment(
                path: path,
                candidate: SharedPlanConflictCandidate(
                    changeHash: changeHash,
                    operationID: record.id,
                    actorUserID: record.actorUserID,
                    value: value,
                    rootOperationID: nil
                )
            )
        }
    }

    private func parentCandidates(
        parent: ObjId,
        key: String,
        path: [String],
        records: [SharedPlanOperationRecord],
        graph _: ChangeGraph
    ) throws -> [ParentCandidate] {
        guard Self.isParentPath(path) else {
            throw SharedPlanError.syncProtocolViolation
        }
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let candidates = try document.getAll(obj: parent, key: key).map {
            value -> ParentCandidate in
            guard case let .Object(object, .Map) = value,
                  case let .object(decoded) = try jsonValue(for: value),
                  let rawRootID = decoded[Key.rootOperationID]?.stringValue,
                  let rootID = UUID(uuidString: rawRootID),
                  rawRootID == rootID.uuidString.lowercased(),
                  let record = recordsByID[rootID],
                  let changeHash = record.changeHash
            else { throw SharedPlanError.syncProtocolViolation }
            return ParentCandidate(
                object: object,
                rootOperationID: rootID,
                assignment: SharedPlanConflictCandidate(
                    changeHash: changeHash,
                    operationID: rootID,
                    actorUserID: record.actorUserID,
                    value: .object(decoded),
                    rootOperationID: rootID
                ),
                decoded: decoded
            )
        }
        guard candidates.count > 1,
              Set(candidates.map(\.rootOperationID)).count == candidates.count
        else { throw SharedPlanError.syncProtocolViolation }
        return candidates.sorted { $0.assignment.changeHash < $1.assignment.changeHash }
    }

    private func registerCandidates(
        path: [String],
        values _: Set<Value>,
        assignments: [LedgerAssignment],
        branchRootHashes: [String],
        graph: ChangeGraph
    ) throws -> [SharedPlanConflictCandidate] {
        let matching = assignments.lazy.filter { assignment in
            assignment.path == path
                && branchRootHashes.allSatisfy {
                    graph.descends(assignment.candidate.changeHash, from: $0)
                }
        }.map(\.candidate)
        let frontier = graph.maximalCandidates(Array(matching))
        guard Set(frontier.map(\.changeHash)).count == frontier.count else {
            throw SharedPlanError.syncProtocolViolation
        }
        return frontier
    }

    private func parentResolutionInventory(
        parent: ObjId,
        key: String,
        basePath: [String],
        selectedParentOperationID: UUID,
        kind: ParentKind
    ) throws -> SharedPlanParentResolutionInventory {
        let records = try operationRecords()
        let graph = try currentChangeGraph()
        let assignments = try ledgerAssignments(records: records)
        let parents = try parentCandidates(
            parent: parent,
            key: key,
            path: basePath,
            records: records,
            graph: graph
        )
        guard let selected = parents.first(where: {
            $0.rootOperationID == selectedParentOperationID
        }) else { throw SharedPlanError.syncProtocolViolation }
        let parentConflict = try Self.makeConflict(
            kind: .parent,
            path: basePath,
            candidates: parents.map(\.assignment),
            parentRootOperationIDs: parents.map(\.rootOperationID)
        )
        let nested = try nestedParentConflicts(
            parents: parents,
            selected: selected,
            basePath: basePath,
            kind: kind,
            records: records,
            assignments: assignments,
            graph: graph
        )
        return SharedPlanParentResolutionInventory(
            parentConflict: parentConflict,
            selectedParentOperationID: selectedParentOperationID,
            requiredNestedConflicts: nested
        )
    }

    private func nestedParentConflicts(
        parents: [ParentCandidate],
        selected: ParentCandidate,
        basePath: [String],
        kind: ParentKind,
        records: [SharedPlanOperationRecord],
        assignments: [LedgerAssignment],
        graph: ChangeGraph
    ) throws -> [SharedPlanDocumentConflict] {
        var conflicts: [String: SharedPlanDocumentConflict] = [:]

        func selectableCandidates(
            path: [String],
            fallback: [SharedPlanConflictCandidate]
        ) -> [SharedPlanConflictCandidate] {
            guard let selectedValue = Self.value(
                in: selected.decoded,
                at: Array(path.dropFirst(basePath.count))
            ) else { return fallback }
            let selectedAssignments = graph.maximalCandidates(
                assignments.filter {
                    $0.path == path
                        && graph.descends(
                            $0.candidate.changeHash,
                            from: selected.assignment.changeHash
                        )
                }.map(\.candidate)
            )
            // JS's assignmentsAtPath binds an ordinary, non-conflicted value
            // to the selected parent root. Only a native register conflict
            // exposes its individual descendant change hashes as choices.
            if selectedAssignments.count > 1 { return selectedAssignments }
            return [SharedPlanConflictCandidate(
                changeHash: selected.assignment.changeHash,
                operationID: selected.assignment.operationID,
                actorUserID: selected.assignment.actorUserID,
                value: selectedValue,
                rootOperationID: selected.rootOperationID
            )]
        }

        func visit(
            object: ObjId,
            path: [String],
            branchRootHash: String
        ) throws {
            for childKey in document.keys(obj: object).sorted() {
                let childPath = path + [childKey]
                let values = try document.getAll(obj: object, key: childKey)
                if childPath != basePath + [Key.presence] {
                    let rawCandidates: [SharedPlanConflictCandidate]
                    if Self.isParentPath(childPath), values.count > 1 {
                        rawCandidates = try parentCandidates(
                            parent: object,
                            key: childKey,
                            path: childPath,
                            records: records,
                            graph: graph
                        ).map(\.assignment)
                    } else if Self.isResolvableRegisterPath(childPath) {
                        rawCandidates = try registerCandidates(
                            path: childPath,
                            values: values,
                            assignments: assignments,
                            branchRootHashes: [branchRootHash],
                            graph: graph
                        )
                    } else {
                        rawCandidates = []
                    }
                    if rawCandidates.count > 1 {
                        let sourceHashes = rawCandidates.map(\.changeHash).sorted()
                        let conflict = try Self.makeConflict(
                            kind: Self.isParentPath(childPath) ? .parent : .scalar,
                            path: childPath,
                            sourceChangeHashes: sourceHashes,
                            candidates: selectableCandidates(
                                path: childPath,
                                fallback: rawCandidates
                            ),
                            parentRootOperationIDs: rawCandidates.compactMap(\.rootOperationID)
                        )
                        conflicts[conflict.id] = conflict
                    }
                }

                if Self.isParentPath(childPath), values.count > 1 {
                    for nestedParent in try parentCandidates(
                        parent: object,
                        key: childKey,
                        path: childPath,
                        records: records,
                        graph: graph
                    ) {
                        try visit(
                            object: nestedParent.object,
                            path: childPath,
                            branchRootHash: branchRootHash
                        )
                    }
                } else if case let .Object(child, objectType) = try document.get(
                    obj: object,
                    key: childKey
                ), objectType != .Text {
                    try visit(object: child, path: childPath, branchRootHash: branchRootHash)
                }
            }
        }

        for parent in parents {
            try visit(
                object: parent.object,
                path: basePath,
                branchRootHash: parent.assignment.changeHash
            )
        }

        let overlapPaths = Self.overlappingPaths(
            parents: parents,
            selected: selected,
            basePath: basePath,
            kind: kind
        )
        for path in overlapPaths {
            var rawCandidates: [SharedPlanConflictCandidate] = []
            for parent in parents {
                guard let value = Self.value(
                    in: parent.decoded,
                    at: Array(path.dropFirst(basePath.count))
                ) else { continue }
                let authored = graph.maximalCandidates(
                    assignments.filter {
                        $0.path == path
                            && graph.descends(
                                $0.candidate.changeHash,
                                from: parent.assignment.changeHash
                            )
                    }.map(\.candidate)
                )
                if authored.isEmpty {
                    rawCandidates.append(SharedPlanConflictCandidate(
                        changeHash: parent.assignment.changeHash,
                        operationID: parent.assignment.operationID,
                        actorUserID: parent.assignment.actorUserID,
                        value: value,
                        rootOperationID: parent.rootOperationID
                    ))
                } else {
                    rawCandidates.append(contentsOf: authored)
                }
            }
            let distinctValues = Set(try rawCandidates.map {
                try SharedPlanCanonicalJSON.data($0.value)
            })
            guard distinctValues.count > 1 else { continue }
            let sourceHashes = Array(Set(rawCandidates.map(\.changeHash))).sorted()
            let selectable = selectableCandidates(path: path, fallback: rawCandidates)
            let conflict = try Self.makeConflict(
                kind: Self.isParentPath(path) ? .parent : .scalar,
                path: path,
                sourceChangeHashes: sourceHashes,
                candidates: selectable,
                parentRootOperationIDs: rawCandidates.compactMap(\.rootOperationID)
            )
            conflicts[conflict.id] = conflict
        }

        guard conflicts.count <= 2_000 else {
            throw SharedPlanError.documentLimit(
                String(localized: "プラン内の競合が上限を超えています。")
            )
        }
        return conflicts.values.sorted { $0.conflictID < $1.conflictID }
    }

    private func semanticDeletionConflicts(
        records: [SharedPlanOperationRecord],
        graph: ChangeGraph
    ) throws -> [SharedPlanDocumentConflict] {
        guard records.contains(where: { record in
            switch record.type {
            case .circlePresence, .circleResolveParent:
                return record.payload[Key.state]?.stringValue == SharedPlanPresenceState.removed.rawValue
            case .needDelete:
                return true
            case .needResolveParent:
                return record.payload[Key.state]?.stringValue == SharedPlanPresenceState.removed.rawValue
            default:
                return false
            }
        }) else { return [] }

        var conflicts: [String: SharedPlanDocumentConflict] = [:]
        let recordsByCircle = Dictionary(grouping: records) {
            $0.payload[Key.wcID]?.integerValue ?? -1
        }
        for (rawWCID, circleRecords) in recordsByCircle {
            guard rawWCID > 0 else { throw SharedPlanError.syncProtocolViolation }
            let circleRemovals = circleRecords.filter {
                ($0.type == .circlePresence || $0.type == .circleResolveParent)
                    && $0.payload[Key.state]?.stringValue == SharedPlanPresenceState.removed.rawValue
            }
            let circleDescendants = circleRecords.filter {
                $0.type != .circlePresence && $0.type != .circleResolveParent
            }
            let circleResolvers = circleRecords.filter {
                $0.type == .circlePresence || $0.type == .circleResolveParent
            }
            try appendSemanticConflicts(
                removals: circleRemovals,
                descendants: circleDescendants,
                resolvers: circleResolvers,
                path: [Key.circles, String(rawWCID), Key.presence],
                graph: graph,
                conflicts: &conflicts
            )

            let recordsByNeed = Dictionary(grouping: circleRecords.compactMap {
                record -> (UUID, SharedPlanOperationRecord)? in
                guard let raw = record.payload[Key.needID]?.stringValue,
                      let id = UUID(uuidString: raw)
                else { return nil }
                return (id, record)
            }, by: \.0)
            for (needID, entries) in recordsByNeed {
                let needRecords = entries.map(\.1)
                let removals = needRecords.filter {
                    $0.type == .needDelete
                        || ($0.type == .needResolveParent
                            && $0.payload[Key.state]?.stringValue
                                == SharedPlanPresenceState.removed.rawValue)
                }
                let descendants = needRecords.filter {
                    $0.type == .needWantedQuantity
                        || $0.type == .needBuyerAllocation
                        || $0.type == .needFulfilledQuantity
                }
                let resolvers = needRecords.filter {
                    $0.type == .needCreate || $0.type == .needDelete
                        || $0.type == .needResolveParent
                }
                try appendSemanticConflicts(
                    removals: removals,
                    descendants: descendants,
                    resolvers: resolvers,
                    path: [
                        Key.circles, String(rawWCID), Key.needs,
                        needID.uuidString.lowercased(), Key.presence,
                    ],
                    graph: graph,
                    conflicts: &conflicts
                )
            }
        }
        return conflicts.values.sorted { $0.conflictID < $1.conflictID }
    }

    /// Enumerates exact removal/edit pairs while keeping the causal linear
    /// case O(N). A maximal opposite frontier first proves that every prior
    /// operation is an ancestor. Only a genuinely concurrent branch expands
    /// its historical candidates, and expansion stops at the conflict cap.
    private func appendSemanticConflicts(
        removals: [SharedPlanOperationRecord],
        descendants: [SharedPlanOperationRecord],
        resolvers: [SharedPlanOperationRecord],
        path: [String],
        graph: ChangeGraph,
        conflicts: inout [String: SharedPlanDocumentConflict]
    ) throws {
        guard !removals.isEmpty, !descendants.isEmpty else { return }
        let removalIDs = Set(removals.map(\.id))
        let descendantIDs = Set(descendants.map(\.id))
        let eventsByID = Dictionary(
            uniqueKeysWithValues: (removals + descendants).map { ($0.id, $0) }
        )
        let events = try eventsByID.values.map { record in
            guard let hash = record.changeHash,
                  let index = graph.topologicalIndex(of: hash)
            else { throw SharedPlanError.syncProtocolViolation }
            return (index, record)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let resolverFrontier = try maximalSemanticFrontier(
            resolvers,
            graph: graph
        )
        var priorRemovals: [SharedPlanOperationRecord] = []
        var priorDescendants: [SharedPlanOperationRecord] = []
        var removalFrontier: [String] = []
        var descendantFrontier: [String] = []

        func appendPair(
            removal: SharedPlanOperationRecord,
            descendant: SharedPlanOperationRecord
        ) throws {
            guard let removalHash = removal.changeHash,
                  let descendantHash = descendant.changeHash,
                  graph.concurrent(removalHash, descendantHash),
                  !resolverFrontier.contains(where: {
                      graph.descendsFromBoth($0, removalHash, descendantHash)
                  })
            else { return }
            let conflict = try semanticConflict(
                removal: removal,
                descendant: descendant,
                path: path
            )
            conflicts[conflict.id] = conflict
            guard conflicts.count <= 2_000 else {
                throw SharedPlanError.documentLimit(
                    String(localized: "プラン内の競合が上限を超えています。")
                )
            }
        }

        for event in events {
            guard let hash = event.changeHash else {
                throw SharedPlanError.syncProtocolViolation
            }
            if removalIDs.contains(event.id) {
                if !descendantFrontier.allSatisfy({
                    graph.descends(hash, from: $0)
                }) {
                    for descendant in priorDescendants {
                        try appendPair(removal: event, descendant: descendant)
                    }
                }
                priorRemovals.append(event)
                insertSemanticFrontier(hash, into: &removalFrontier, graph: graph)
            }
            if descendantIDs.contains(event.id) {
                if !removalFrontier.allSatisfy({
                    graph.descends(hash, from: $0)
                }) {
                    for removal in priorRemovals {
                        try appendPair(removal: removal, descendant: event)
                    }
                }
                priorDescendants.append(event)
                insertSemanticFrontier(hash, into: &descendantFrontier, graph: graph)
            }
        }
    }

    private func maximalSemanticFrontier(
        _ records: [SharedPlanOperationRecord],
        graph: ChangeGraph
    ) throws -> [String] {
        let ordered = try records.map { record in
            guard let hash = record.changeHash,
                  let index = graph.topologicalIndex(of: hash)
            else { throw SharedPlanError.syncProtocolViolation }
            return (index, record)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        var frontier: [String] = []
        for record in ordered {
            guard let hash = record.changeHash else {
                throw SharedPlanError.syncProtocolViolation
            }
            insertSemanticFrontier(hash, into: &frontier, graph: graph)
        }
        return frontier
    }

    private func insertSemanticFrontier(
        _ hash: String,
        into frontier: inout [String],
        graph: ChangeGraph
    ) {
        frontier.removeAll { graph.descends(hash, from: $0) }
        frontier.append(hash)
    }

    private func semanticConflict(
        removal: SharedPlanOperationRecord,
        descendant: SharedPlanOperationRecord,
        path: [String]
    ) throws -> SharedPlanDocumentConflict {
        guard let removalHash = removal.changeHash,
              let descendantHash = descendant.changeHash
        else { throw SharedPlanError.syncProtocolViolation }
        let removalCandidate = SharedPlanConflictCandidate(
            changeHash: removalHash,
            operationID: removal.id,
            actorUserID: removal.actorUserID,
            value: .object([
                Key.state: .string(SharedPlanPresenceState.removed.rawValue),
                Key.operationID: .string(removal.id.uuidString.lowercased()),
            ]),
            rootOperationID: nil
        )
        let descendantCandidate = SharedPlanConflictCandidate(
            changeHash: descendantHash,
            operationID: descendant.id,
            actorUserID: descendant.actorUserID,
            value: .object([
                Key.state: .string(SharedPlanPresenceState.active.rawValue),
                Key.operationID: .string(descendant.id.uuidString.lowercased()),
            ]),
            rootOperationID: nil
        )
        let conflict = try Self.makeConflict(
            kind: .removalVersusEdit,
            path: path,
            candidates: [removalCandidate, descendantCandidate]
        )
        return conflict
    }

    private static func makeConflict(
        kind: SharedPlanDocumentConflictKind,
        path: [String],
        sourceChangeHashes: [String]? = nil,
        candidates: [SharedPlanConflictCandidate],
        parentRootOperationIDs: [UUID] = []
    ) throws -> SharedPlanDocumentConflict {
        let hashes = (sourceChangeHashes ?? candidates.map(\.changeHash)).sorted()
        guard hashes.count > 1,
              Set(hashes).count == hashes.count,
              hashes.allSatisfy(Self.isCanonicalChangeHash)
        else { throw SharedPlanError.syncProtocolViolation }
        let identity: SharedPlanJSONValue = .object([
            Key.schemaVersion: .integer(schemaVersion),
            Key.path: .array(path.map(SharedPlanJSONValue.string)),
            "changeHashes": .array(hashes.map(SharedPlanJSONValue.string)),
        ])
        let digest = SHA256.hash(data: try SharedPlanCanonicalJSON.data(identity))
        let conflictID = digest.map { String(format: "%02x", $0) }.joined()
        return SharedPlanDocumentConflict(
            conflictID: conflictID,
            kind: kind,
            path: path,
            sourceChangeHashes: hashes,
            candidates: candidates.sorted { $0.changeHash < $1.changeHash },
            parentRootOperationIDs: parentRootOperationIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        )
    }

    private static func overlappingPaths(
        parents: [ParentCandidate],
        selected: ParentCandidate,
        basePath: [String],
        kind: ParentKind
    ) -> [[String]] {
        var paths: Set<[String]> = []
        switch kind {
        case .circle:
            let selectedCommunication = selected.decoded[Key.communicationState]?.objectValue ?? [:]
            let selectedNeeds = selected.decoded[Key.needs]?.objectValue ?? [:]
            for parent in parents {
                for key in parent.decoded[Key.communicationState]?.objectValue?.keys ?? Dictionary<String, SharedPlanJSONValue>().keys
                where selectedCommunication[key] == nil {
                    paths.insert(basePath + [Key.communicationState, key])
                }
                for needID in parent.decoded[Key.needs]?.objectValue?.keys ?? Dictionary<String, SharedPlanJSONValue>().keys
                where selectedNeeds[needID] == nil {
                    paths.insert(basePath + [Key.needs, needID])
                }
            }
        case .need:
            let selectedAllocations = selected.decoded[Key.buyerAllocations]?.objectValue ?? [:]
            for parent in parents {
                for buyerID in parent.decoded[Key.buyerAllocations]?.objectValue?.keys ?? Dictionary<String, SharedPlanJSONValue>().keys
                where selectedAllocations[buyerID] == nil {
                    paths.insert(basePath + [Key.buyerAllocations, buyerID])
                }
            }
        }
        return paths.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static func value(
        in object: [String: SharedPlanJSONValue],
        at path: [String]
    ) -> SharedPlanJSONValue? {
        var current: SharedPlanJSONValue = .object(object)
        for component in path {
            guard case let .object(values) = current,
                  let next = values[component]
            else { return nil }
            current = next
        }
        return current
    }

    private static func isParentPath(_ path: [String]) -> Bool {
        guard path.first == Key.circles else { return false }
        return path.count == 2
            || (path.count == 4 && path[path.count - 2] == Key.needs)
    }

    private static func isResolvableRegisterPath(_ path: [String]) -> Bool {
        guard path.first == Key.circles, let last = path.last else { return false }
        if last == Key.presence || last == Key.requesterUserID
            || last == Key.itemName || last == Key.unitPrice
            || last == Key.wantedQuantity || last == Key.fulfilledQuantity
        {
            return true
        }
        return path.count >= 4
            && (path[path.count - 2] == Key.communicationState
                || path[path.count - 2] == Key.buyerAllocations)
    }

    private static func requiredUUID(
        _ payload: [String: SharedPlanJSONValue],
        key: String
    ) throws -> UUID {
        guard let raw = payload[key]?.stringValue,
              let value = UUID(uuidString: raw),
              raw == value.uuidString.lowercased()
        else { throw SharedPlanError.syncProtocolViolation }
        return value
    }

    private static func isCanonicalChangeHash(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    private static func payloadKeyOrder(for type: SharedPlanOperationType) -> [String] {
        switch type {
        case .circlePresence:
            [Key.version, Key.wcID, Key.state]
        case .circleResolveParent:
            [
                Key.version, Key.wcID, Key.selectedParentOperationID,
                Key.state, Key.nestedResolutions,
            ]
        case .circleMemoSplice:
            [Key.version, Key.wcID, Key.index, Key.deleteCount, Key.text]
        case .needCreate:
            [
                Key.version, Key.wcID, Key.needID, Key.requesterUserID,
                Key.itemName, Key.unitPrice, Key.wantedQuantity,
            ]
        case .needDelete:
            [Key.version, Key.wcID, Key.needID]
        case .needResolveParent:
            [
                Key.version, Key.wcID, Key.needID, Key.selectedParentOperationID,
                Key.state, Key.nestedResolutions,
            ]
        case .needWantedQuantity:
            [Key.version, Key.wcID, Key.needID, Key.wantedQuantity]
        case .needBuyerAllocation:
            [
                Key.version, Key.wcID, Key.needID, Key.buyerUserID, Key.quantity,
            ]
        case .needFulfilledQuantity:
            [Key.version, Key.wcID, Key.needID, Key.fulfilledQuantity]
        case .circleCommunicationSet:
            [Key.version, Key.wcID, Key.key, Key.value]
        }
    }

    private static func jsonValue(
        _ resolution: SharedPlanNestedConflictResolution
    ) -> SharedPlanJSONValue {
        .object([
            Key.conflictID: .string(resolution.conflictID),
            Key.path: .array(resolution.path.map(SharedPlanJSONValue.string)),
            Key.selectedChangeHash: .string(resolution.selectedChangeHash),
            Key.value: resolution.value,
        ])
    }

    private static func isValidCommunicationKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard (1...64).contains(scalars.count),
              let first = scalars.first,
              (97...122).contains(first.value)
        else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            let value = scalar.value
            return (97...122).contains(value)
                || (65...90).contains(value)
                || (48...57).contains(value)
                || value == 95 || value == 46 || value == 45
        }
    }

    private static func isCommunicationScalar(_ value: SharedPlanJSONValue) -> Bool {
        switch value {
        case .null, .boolean, .integer:
            true
        case .string(let value):
            value.utf8.count <= 4_096
        case .array, .object:
            false
        }
    }

    private static func mergeCircleDescendants(
        selected: [String: SharedPlanJSONValue],
        candidates: [[String: SharedPlanJSONValue]]
    ) -> [String: SharedPlanJSONValue] {
        var result = selected
        var resultNeeds = result[Key.needs]?.objectValue ?? [:]
        var resultCommunication = result[Key.communicationState]?.objectValue ?? [:]
        for candidate in canonicalOrder(candidates) {
            for (needID, need) in candidate[Key.needs]?.objectValue ?? [:] {
                if let existing = resultNeeds[needID]?.objectValue,
                   let candidateNeed = need.objectValue
                {
                    resultNeeds[needID] = .object(
                        mergeNeedDescendants(
                            selected: existing,
                            candidates: [candidateNeed]
                        )
                    )
                } else if resultNeeds[needID] == nil {
                    resultNeeds[needID] = need
                }
            }
            for (key, value) in candidate[Key.communicationState]?.objectValue ?? [:]
            where resultCommunication[key] == nil {
                resultCommunication[key] = value
            }
        }
        result[Key.needs] = .object(resultNeeds)
        result[Key.communicationState] = .object(resultCommunication)
        return result
    }

    private static func mergeNeedDescendants(
        selected: [String: SharedPlanJSONValue],
        candidates: [[String: SharedPlanJSONValue]]
    ) -> [String: SharedPlanJSONValue] {
        var result = selected
        var allocations = result[Key.buyerAllocations]?.objectValue ?? [:]
        for candidate in canonicalOrder(candidates) {
            for (buyer, quantity) in candidate[Key.buyerAllocations]?.objectValue ?? [:]
            where allocations[buyer] == nil {
                allocations[buyer] = quantity
            }
        }
        result[Key.buyerAllocations] = .object(allocations)
        return result
    }

    private static func canonicalOrder(
        _ values: [[String: SharedPlanJSONValue]]
    ) -> [[String: SharedPlanJSONValue]] {
        values.sorted { left, right in
            let leftData = try? SharedPlanCanonicalJSON.data(.object(left))
            let rightData = try? SharedPlanCanonicalJSON.data(.object(right))
            return (leftData ?? Data()).lexicographicallyPrecedes(rightData ?? Data())
        }
    }

    private static func apply(
        resolution: SharedPlanNestedConflictResolution,
        to value: inout [String: SharedPlanJSONValue],
        basePath: [String]
    ) throws {
        guard resolution.path.count > basePath.count,
              Array(resolution.path.prefix(basePath.count)) == basePath,
              !resolution.conflictID.isEmpty,
              !resolution.selectedChangeHash.isEmpty
        else { throw SharedPlanError.syncProtocolViolation }
        var root = SharedPlanJSONValue.object(value)
        try assign(
            resolution.value,
            at: Array(resolution.path.dropFirst(basePath.count))[...],
            in: &root
        )
        guard case let .object(updated) = root else {
            throw SharedPlanError.syncProtocolViolation
        }
        value = updated
    }

    private static func assign(
        _ replacement: SharedPlanJSONValue,
        at path: ArraySlice<String>,
        in value: inout SharedPlanJSONValue
    ) throws {
        guard let component = path.first else {
            value = replacement
            return
        }
        guard case var .object(object) = value else {
            throw SharedPlanError.syncProtocolViolation
        }
        if path.count == 1 {
            object[component] = replacement
        } else {
            guard var child = object[component] else {
                throw SharedPlanError.syncProtocolViolation
            }
            try assign(replacement, at: path.dropFirst(), in: &child)
            object[component] = child
        }
        value = .object(object)
    }

    private func allCircleEntries() throws -> [(String, ObjId)] {
        try document.mapEntries(obj: circlesObject).compactMap { key, value in
            guard case let .Object(object, .Map) = value else { return nil }
            return (key, object)
        }
    }

    private func circleKey(
        for object: ObjId,
        fallbackWCID: String
    ) throws -> SharedPlanCircleKey? {
        guard let circleComiketNo = Self.int(
            in: document,
            object: object,
            key: Key.comiketNo
        ),
              let wcID = Self.int(in: document, object: object, key: Key.circleWCID)
                ?? Int(fallbackWCID),
              circleComiketNo == comiketNo
        else { return nil }
        return SharedPlanCircleKey(comiketNo: circleComiketNo, wcID: wcID)
    }

    private func circleObject(for key: SharedPlanCircleKey) throws -> ObjId? {
        try mapObject(in: circlesObject, key: String(key.wcID))
    }

    private func mapObject(in parent: ObjId, key: String) throws -> ObjId? {
        guard case let .Object(object, .Map) = try document.get(obj: parent, key: key)
        else { return nil }
        return object
    }

    private func activeCircleObject(for key: SharedPlanCircleKey) throws -> ObjId? {
        try validate(key)
        guard try document.getAll(obj: circlesObject, key: String(key.wcID)).count == 1,
              let circle = try circleObject(for: key),
              try presence(for: circle) == .present
        else { return nil }
        return circle
    }

    private func activeNeedObject(id: UUID, circle key: SharedPlanCircleKey) throws -> ObjId? {
        guard let circle = try activeCircleObject(for: key),
              let needs = try mapObject(in: circle, key: Key.needs),
              try document.getAll(
                  obj: needs,
                  key: id.uuidString.lowercased()
              ).count == 1,
              let need = try mapObject(in: needs, key: id.uuidString.lowercased()),
              try needPresence(in: need) == .active
        else { return nil }
        return need
    }

    private func needPresence(in need: ObjId) throws -> SharedPlanPresenceState? {
        guard let presence = try mapObject(in: need, key: Key.presence),
              let state = try Self.string(
                  in: document,
                  object: presence,
                  key: Key.state
              )
        else { return nil }
        return SharedPlanPresenceState(rawValue: state)
    }

    private func jsonValue(in object: ObjId, key: String) throws -> SharedPlanJSONValue? {
        guard let value = try document.get(obj: object, key: key) else { return nil }
        return try jsonValue(for: value)
    }

    private func jsonValue(for value: Value) throws -> SharedPlanJSONValue {
        try Self.jsonValue(in: document, for: value)
    }

    private static func jsonValue(
        in source: Document,
        for value: Value
    ) throws -> SharedPlanJSONValue {
        switch value {
        case .Scalar(.Null):
            return .null
        case .Scalar(.Boolean(let value)):
            return .boolean(value)
        case .Scalar(.Int(let value)):
            return .integer(value)
        case .Scalar(.Uint(let value)):
            guard let exact = Int64(exactly: value) else {
                throw SharedPlanError.syncProtocolViolation
            }
            return .integer(exact)
        case .Scalar(.F64(let value)):
            // Automerge Swift 0.7.2's value bridge materializes some
            // JS-authored `datatype:int` zero values as F64. Accept only an
            // exactly integral representation; Swift-authored protocol values
            // are always written with `.Int`.
            guard value.isFinite, value.rounded() == value,
                  value >= Double(Int64.min), value <= Double(Int64.max)
            else { throw SharedPlanError.syncProtocolViolation }
            return .integer(Int64(value))
        case .Scalar(.String(let value)):
            return .string(value)
        case .Object(let object, .Text):
            return .string(try source.text(obj: object))
        case .Object(let object, .Map):
            var result: [String: SharedPlanJSONValue] = [:]
            for (key, child) in try source.mapEntries(obj: object) {
                result[key] = try jsonValue(in: source, for: child)
            }
            return .object(result)
        case .Object(let object, .List):
            return .array(
                try source.values(obj: object).map { try jsonValue(in: source, for: $0) }
            )
        default:
            throw SharedPlanError.syncProtocolViolation
        }
    }

    private func presence(for circleObject: ObjId) throws -> SharedPlanCirclePresence {
        let states: [String] = try document.getAll(
            obj: circleObject,
            key: Key.presence
        ).compactMap { value in
            guard case let .Object(presenceObject, .Map) = value else { return nil }
            return try Self.string(
                in: document,
                object: presenceObject,
                key: Key.state
            )
        }
        if states.contains("active") && states.contains("removed") { return .conflicted }
        return states.contains("removed") ? .removed : .present
    }

    private func requireMutationAccess(_ allowingDurableMutation: Bool) throws {
        guard !isPersistingDurableMutation || allowingDurableMutation else {
            throw SharedPlanError.persistenceFailed
        }
    }

    private func validate(_ key: SharedPlanCircleKey) throws {
        guard key.comiketNo == comiketNo else {
            throw SharedPlanError.eventMismatch(expected: comiketNo, received: key.comiketNo)
        }
    }

    private func validate(_ need: SharedPlanPurchaseNeed) throws {
        let quantities = [need.wantedQuantity, need.fulfilledQuantity]
            + Array(need.buyerAllocations.values)
        let normalizedItemName = need.itemName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !need.requesterUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalizedItemName.isEmpty || (
                  normalizedItemName.count <= 80 && normalizedItemName.utf8.count <= 512
              ),
              need.unitPrice.map({ (0...9_999_999).contains($0) }) ?? true,
              need.buyerAllocations.keys.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              quantities.allSatisfy({ (0...Self.maximumQuantity).contains($0) })
        else {
            throw SharedPlanError.documentLimit(
                String(localized: "数量は0から999の範囲で入力してください。")
            )
        }
    }

    private func putOptionalPrice(_ price: Int?, in object: ObjId) throws {
        if let price {
            try document.put(obj: object, key: Key.unitPrice, value: .Int(Int64(price)))
        } else {
            try document.put(obj: object, key: Key.unitPrice, value: .Null)
        }
    }

    private func validateQuantity(_ quantity: Int) throws {
        guard (0...Self.maximumQuantity).contains(quantity) else {
            throw SharedPlanError.documentLimit(
                String(localized: "数量は0から999の範囲で入力してください。")
            )
        }
    }

    private func performDomainChange(
        operationID: UUID,
        timestamp: Date,
        _ body: () throws -> Void
    ) throws {
        let backup = document.save()
        let initialOperationCount = document.keys(obj: operationsObject).count
        if pendingRetainedPayloadBytes == nil {
            // Seed the transaction before any Automerge write. Calling heads
            // after a write but before commit can itself finalize that write
            // as an unnamed change in Automerge Swift.
            pendingRetainedPayloadBytes = try retainedOperationPayloadBytes()
        }
        let initialRetainedPayloadBytes = pendingRetainedPayloadBytes
        do {
            try body()
            guard let retainedPayloadBytes = pendingRetainedPayloadBytes,
                  retainedPayloadBytes != initialRetainedPayloadBytes,
                  document.keys(obj: operationsObject).count
                    == initialOperationCount + 1,
                  try document.get(
                      obj: operationsObject,
                      key: operationID.uuidString.lowercased()
                  ) != nil
            else {
                throw SharedPlanError.syncProtocolViolation
            }
            document.commitWith(
                message: Self.semanticChangeMessage(for: operationID),
                timestamp: timestamp
            )
            try validateBounds(validatingLedger: false)
            retainedPayloadBytesByHeads[Self.headCacheKey(document)] = retainedPayloadBytes
            pendingRetainedPayloadBytes = nil
        } catch {
            pendingRetainedPayloadBytes = nil
            try restore(from: backup)
            throw error
        }
    }

    private func appendNeedOperation(
        id: UUID,
        type: SharedPlanOperationType,
        actorUserID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        fields: [String: SharedPlanJSONValue]
    ) throws {
        var payload: [String: SharedPlanJSONValue] = [
            Key.version: .integer(Self.schemaVersion),
            Key.wcID: .integer(Int64(circle.wcID)),
            Key.needID: .string(needID.uuidString.lowercased()),
        ]
        payload.merge(fields) { _, replacement in replacement }
        try appendOperation(id: id, type: type, actorUserID: actorUserID, payload: payload)
    }

    private func appendOperation(
        id: UUID,
        type: SharedPlanOperationType,
        actorUserID: String,
        payload: [String: SharedPlanJSONValue]
    ) throws {
        let operationKey = id.uuidString.lowercased()
        guard !actorUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              try document.get(obj: operationsObject, key: operationKey) == nil,
              payload[Key.version] == .integer(Self.schemaVersion)
        else { throw SharedPlanError.persistenceFailed }
        guard document.keys(obj: operationsObject).count < Self.maximumOperations else {
            throw SharedPlanError.planCompactionRequired
        }
        let existingPayloadBytes = try retainedOperationPayloadBytes()
        let addedPayloadBytes = try SharedPlanCanonicalJSON.payloadBytes(payload)
        guard existingPayloadBytes + addedPayloadBytes
                <= Self.maximumRetainedOperationPayloadUTF8Bytes
        else { throw SharedPlanError.planCompactionRequired }
        pendingRetainedPayloadBytes = existingPayloadBytes + addedPayloadBytes

        let operation = try document.putObject(
            obj: operationsObject,
            key: operationKey,
            ty: .Map
        )
        try putText(type.rawValue, in: operation, key: Key.operationType)
        try putText(actorUserID, in: operation, key: Key.actorUserID)
        let payloadObject = try document.putObject(obj: operation, key: Key.payload, ty: .Map)
        let preferred = Self.payloadKeyOrder(for: type)
        for key in preferred + payload.keys.filter({ !preferred.contains($0) }).sorted() {
            guard let value = payload[key] else { continue }
            try putJSON(value, in: payloadObject, key: key)
        }
    }

    private func replacePresence(
        in object: ObjId,
        state: SharedPlanPresenceState,
        operationID: UUID
    ) throws {
        let presence = try document.putObject(obj: object, key: Key.presence, ty: .Map)
        try putText(state.rawValue, in: presence, key: Key.state)
        try putText(operationID.uuidString.lowercased(), in: presence, key: Key.operationID)
    }

    private func putText(_ value: String, in object: ObjId, key: String) throws {
        let text = try document.putObject(obj: object, key: key, ty: .Text)
        guard !value.isEmpty else { return }
        try document.spliceText(obj: text, start: 0, delete: 0, value: value)
    }

    private func putJSON(_ value: SharedPlanJSONValue, in object: ObjId, key: String) throws {
        switch value {
        case .null:
            try document.put(obj: object, key: key, value: .Null)
        case .boolean(let value):
            try document.put(obj: object, key: key, value: .Boolean(value))
        case .integer(let value):
            try document.put(obj: object, key: key, value: .Int(value))
        case .string(let value):
            try putText(value, in: object, key: key)
        case .array(let values):
            let list = try document.putObject(obj: object, key: key, ty: .List)
            for (index, child) in values.enumerated() {
                try insertJSON(child, in: list, index: UInt64(index))
            }
        case .object(let values):
            let map = try document.putObject(obj: object, key: key, ty: .Map)
            for childKey in values.keys.sorted() {
                guard let child = values[childKey] else { continue }
                try putJSON(child, in: map, key: childKey)
            }
        }
    }

    private func insertJSON(_ value: SharedPlanJSONValue, in list: ObjId, index: UInt64) throws {
        switch value {
        case .null:
            try document.insert(obj: list, index: index, value: .Null)
        case .boolean(let value):
            try document.insert(obj: list, index: index, value: .Boolean(value))
        case .integer(let value):
            try document.insert(obj: list, index: index, value: .Int(value))
        case .string(let value):
            let text = try document.insertObject(obj: list, index: index, ty: .Text)
            if !value.isEmpty {
                try document.spliceText(obj: text, start: 0, delete: 0, value: value)
            }
        case .array(let values):
            let nested = try document.insertObject(obj: list, index: index, ty: .List)
            for (childIndex, child) in values.enumerated() {
                try insertJSON(child, in: nested, index: UInt64(childIndex))
            }
        case .object(let values):
            let map = try document.insertObject(obj: list, index: index, ty: .Map)
            for childKey in values.keys.sorted() {
                guard let child = values[childKey] else { continue }
                try putJSON(child, in: map, key: childKey)
            }
        }
    }

    private func retainedOperationPayloadBytes() throws -> Int {
        if let pendingRetainedPayloadBytes { return pendingRetainedPayloadBytes }
        let key = Self.headCacheKey(document)
        if let cached = retainedPayloadBytesByHeads[key] { return cached }
        let bytes = try Self.validatedRetainedOperationPayloadBytes(
            document: document,
            operationsObject: operationsObject,
            comiketNo: comiketNo
        )
        retainedPayloadBytesByHeads[key] = bytes
        return bytes
    }

    private func resolveParent(
        parent: ObjId,
        key: String,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        operationID: UUID,
        actorUserID: String,
        type: SharedPlanOperationType,
        circle: SharedPlanCircleKey,
        needID: UUID?,
        authoredAt: Date
    ) throws {
        let basePath: [String]
        let kind: ParentKind
        if type == .circleResolveParent {
            basePath = [Key.circles, String(circle.wcID)]
            kind = .circle
        } else {
            guard let needID else { throw SharedPlanError.syncProtocolViolation }
            basePath = [
                Key.circles, String(circle.wcID), Key.needs,
                needID.uuidString.lowercased(),
            ]
            kind = .need
        }
        let resolutionInventory = try parentResolutionInventory(
            parent: parent,
            key: key,
            basePath: basePath,
            selectedParentOperationID: selectedParentOperationID,
            kind: kind
        )
        try Self.validate(
            nestedResolutions: nestedResolutions,
            against: resolutionInventory
        )

        let candidates = try document.getAll(obj: parent, key: key).compactMap { value -> [String: SharedPlanJSONValue]? in
            guard case let .Object(object, .Map) = value,
                  case let .object(decoded) = try jsonValue(for: .Object(object, .Map))
            else { return nil }
            return decoded
        }
        guard candidates.count > 1 else { throw SharedPlanError.syncProtocolViolation }
        let selectedID = selectedParentOperationID.uuidString.lowercased()
        let matching = candidates.filter { candidate in
            candidate[Key.rootOperationID] == .string(selectedID)
        }
        guard matching.count == 1 else { throw SharedPlanError.syncProtocolViolation }
        var resolved = matching[0]
        if type == .circleResolveParent {
            resolved = Self.mergeCircleDescendants(selected: resolved, candidates: candidates)
        } else {
            resolved = Self.mergeNeedDescendants(selected: resolved, candidates: candidates)
        }
        for resolution in nestedResolutions.sorted(by: { $0.path.count < $1.path.count }) {
            try Self.apply(resolution: resolution, to: &resolved, basePath: basePath)
        }
        resolved[Key.presence] = .object([
            Key.state: .string(state.rawValue),
            Key.operationID: .string(operationID.uuidString.lowercased()),
        ])

        try performDomainChange(operationID: operationID, timestamp: authoredAt) {
            try document.delete(obj: parent, key: key)
            if type == .circleResolveParent {
                try writeCircle(resolved, in: parent, key: key)
            } else {
                try writeNeed(resolved, in: parent, key: key)
            }
            var payload: [String: SharedPlanJSONValue] = [
                Key.version: .integer(Self.schemaVersion),
                Key.wcID: .integer(Int64(circle.wcID)),
                Key.selectedParentOperationID: .string(selectedID),
                Key.state: .string(state.rawValue),
                Key.nestedResolutions: .array(nestedResolutions.map(Self.jsonValue)),
            ]
            if let needID {
                payload[Key.needID] = .string(needID.uuidString.lowercased())
            }
            try appendOperation(
                id: operationID,
                type: type,
                actorUserID: actorUserID,
                payload: payload
            )
        }
    }

    private static func validate(
        nestedResolutions: [SharedPlanNestedConflictResolution],
        against inventory: SharedPlanParentResolutionInventory
    ) throws {
        guard nestedResolutions.count == inventory.requiredNestedConflicts.count
        else { throw SharedPlanError.syncProtocolViolation }

        var resolutionsByID: [String: SharedPlanNestedConflictResolution] = [:]
        for resolution in nestedResolutions {
            guard resolutionsByID[resolution.conflictID] == nil else {
                throw SharedPlanError.syncProtocolViolation
            }
            resolutionsByID[resolution.conflictID] = resolution
        }

        var selectedByPath: [String: (hash: String, value: SharedPlanJSONValue)] = [:]
        for conflict in inventory.requiredNestedConflicts {
            guard let resolution = resolutionsByID[conflict.conflictID],
                  resolution.path == conflict.path,
                  isCanonicalChangeHash(resolution.selectedChangeHash),
                  conflict.candidates.contains(where: {
                      $0.changeHash == resolution.selectedChangeHash
                          && $0.value == resolution.value
                  })
            else { throw SharedPlanError.syncProtocolViolation }

            let pathKey = String(
                data: try SharedPlanCanonicalJSON.data(
                    .array(resolution.path.map(SharedPlanJSONValue.string))
                ),
                encoding: .utf8
            ) ?? ""
            if let selected = selectedByPath[pathKey] {
                guard selected.hash == resolution.selectedChangeHash,
                      selected.value == resolution.value
                else { throw SharedPlanError.syncProtocolViolation }
            } else {
                selectedByPath[pathKey] = (
                    resolution.selectedChangeHash,
                    resolution.value
                )
            }
        }
        guard resolutionsByID.count == inventory.requiredNestedConflicts.count else {
            throw SharedPlanError.syncProtocolViolation
        }
    }

    private func writeCircle(
        _ value: [String: SharedPlanJSONValue],
        in parent: ObjId,
        key: String
    ) throws {
        let circle = try document.putObject(obj: parent, key: key, ty: .Map)
        for field in [
            Key.comiketNo, Key.circleWCID, Key.rootOperationID, Key.presence,
            Key.memo, Key.needs, Key.communicationState,
        ] {
            guard let child = value[field] else { throw SharedPlanError.syncProtocolViolation }
            try putJSON(child, in: circle, key: field)
        }
    }

    private func writeNeed(
        _ value: [String: SharedPlanJSONValue],
        in parent: ObjId,
        key: String
    ) throws {
        let need = try document.putObject(obj: parent, key: key, ty: .Map)
        for field in [
            Key.rootOperationID, Key.presence, Key.requesterUserID,
            Key.itemName, Key.unitPrice, Key.wantedQuantity,
            Key.buyerAllocations, Key.fulfilledQuantity,
        ] {
            guard let child = value[field] else {
                if field == Key.itemName || field == Key.unitPrice { continue }
                throw SharedPlanError.syncProtocolViolation
            }
            try putJSON(child, in: need, key: field)
        }
    }

    private func validateBounds(validatingLedger: Bool = true) throws {
        let retainedPayloadBytes: Int
        if validatingLedger {
            retainedPayloadBytes = try Self.validatedRetainedOperationPayloadBytes(
                document: document,
                operationsObject: operationsObject,
                comiketNo: comiketNo
            )
            retainedPayloadBytesByHeads[Self.headCacheKey(document)] = retainedPayloadBytes
        } else {
            retainedPayloadBytes = try retainedOperationPayloadBytes()
        }
        guard document.keys(obj: circlesObject).count <= Self.maximumCircles,
              document.keys(obj: operationsObject).count <= Self.maximumOperations,
              retainedPayloadBytes <= Self.maximumRetainedOperationPayloadUTF8Bytes,
              document.save().count <= Self.maximumSavedDocumentBytes
        else {
            throw SharedPlanError.documentLimit(
                String(localized: "プランのデータが大きすぎます。")
            )
        }
    }

    private static func validateBounds(
        document: Document,
        circlesObject: ObjId,
        operationsObject: ObjId,
        allowingPolicyLimitOverflow: Bool = false
    ) throws -> Int {
        let retainedPayloadBytes = try validatedRetainedOperationPayloadBytes(
            document: document,
            operationsObject: operationsObject,
            comiketNo: Self.int(
                in: document,
                object: .ROOT,
                key: Key.comiketNo
            ) ?? -1
        )
        guard document.keys(obj: circlesObject).count <= maximumCircles,
              document.keys(obj: operationsObject).count <= maximumOperations,
              (allowingPolicyLimitOverflow
                || retainedPayloadBytes <= maximumRetainedOperationPayloadUTF8Bytes),
              document.save().count <= maximumSavedDocumentBytes
        else {
            throw SharedPlanError.documentLimit(
                String(localized: "プランのデータが大きすぎます。")
            )
        }
        return retainedPayloadBytes
    }

    private static func validatedRetainedOperationPayloadBytes(
        document: Document,
        operationsObject: ObjId,
        comiketNo: Int
    ) throws -> Int {
        try document.mapEntries(obj: operationsObject).reduce(0) { partial, entry in
            guard let operationID = UUID(uuidString: entry.0),
                  entry.0 == operationID.uuidString.lowercased(),
                  case let .Object(operation, .Map) = entry.1,
                  let rawType = try string(
                      in: document,
                      object: operation,
                      key: Key.operationType
                  ),
                  let type = SharedPlanOperationType(rawValue: rawType),
                  let actorUserID = try string(
                      in: document,
                      object: operation,
                      key: Key.actorUserID
                  ),
                  !actorUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case let .Object(payloadObject, .Map) = try document.get(
                      obj: operation,
                      key: Key.payload
                  ),
                  case let .object(payload) = try jsonValue(
                      in: document,
                      for: .Object(payloadObject, .Map)
                  )
            else { throw SharedPlanError.syncProtocolViolation }
            let record = SharedPlanOperationRecord(
                id: operationID,
                type: type,
                actorUserID: actorUserID,
                payload: payload,
                changeHash: nil
            )
            _ = try record.durableMutation(comiketNo: comiketNo)
            return partial + (try SharedPlanCanonicalJSON.payloadBytes(payload))
        }
    }

    private static func headCacheKey(_ document: Document) -> String {
        document.heads().map(\.debugDescription).sorted().joined(separator: ",")
    }

    private static func semanticChangeMessage(for operationID: UUID) -> String {
        semanticChangeMessagePrefix + operationID.uuidString.lowercased()
    }

    private static func validateCanonicalBootstrap(
        in source: Document,
        expectedPlanID: String,
        expectedComiketNo: Int
    ) throws -> (shadow: Document, changeHash: String) {
        _ = try validateRetainedRootTopology(
            in: source,
            expectedPlanID: expectedPlanID,
            expectedComiketNo: expectedComiketNo
        )
        let history = source.getHistory()
        guard let bootstrapHash = history.first,
              let bootstrap = source.change(hash: bootstrapHash)
        else { throw SharedPlanError.syncProtocolViolation }

        // History zero is the only change allowed to omit a semantic operation
        // message. Reject every later exception eagerly before these bytes can
        // be persisted as an apparently valid server bootstrap.
        var laterOperationIDs: Set<UUID> = []
        for hash in history.dropFirst() {
            guard let change = source.change(hash: hash),
                  let message = change.message,
                  message.hasPrefix(semanticChangeMessagePrefix)
            else { throw SharedPlanError.syncProtocolViolation }
            let rawOperationID = String(
                message.dropFirst(semanticChangeMessagePrefix.count)
            )
            guard let operationID = UUID(uuidString: rawOperationID),
                  rawOperationID == operationID.uuidString.lowercased(),
                  message == semanticChangeMessage(for: operationID),
                  laterOperationIDs.insert(operationID).inserted
            else { throw SharedPlanError.syncProtocolViolation }
        }

        let shadow = Document(textEncoding: .unicodeScalar)
        _ = try applyCanonicalBootstrap(
            bootstrap,
            to: shadow,
            expectedPlanID: expectedPlanID,
            expectedComiketNo: expectedComiketNo
        )
        return (shadow, bootstrapHash.debugDescription)
    }

    private static func applyCanonicalBootstrap(
        _ change: Change,
        to shadow: Document,
        expectedPlanID: String,
        expectedComiketNo: Int
    ) throws -> (
        planID: String,
        comiketNo: Int,
        circles: ObjId,
        operations: ObjId
    ) {
        guard change.message == nil, change.deps.isEmpty else {
            throw SharedPlanError.syncProtocolViolation
        }
        let patches = try shadow.applyEncodedChangesWithPatches(
            encoded: change.bytes
        )
        guard patches.count == canonicalBootstrapRootKeys.count else {
            throw SharedPlanError.syncProtocolViolation
        }
        var patchedKeys: Set<String> = []
        for patch in patches {
            guard patch.path.isEmpty,
                  case let .Put(object, .Key(key), value) = patch.action,
                  object == .ROOT,
                  canonicalBootstrapRootKeys.contains(key),
                  patchedKeys.insert(key).inserted
            else { throw SharedPlanError.syncProtocolViolation }
            switch (key, value) {
            case (Key.schemaVersion, .Scalar(.Int(schemaVersion))):
                guard schemaVersion == Self.schemaVersion else {
                    throw SharedPlanError.syncProtocolViolation
                }
            case let (Key.planID, .Scalar(.String(planValue))):
                guard planValue == expectedPlanID else {
                    throw SharedPlanError.syncProtocolViolation
                }
            case let (Key.comiketNo, .Scalar(.Int(comiketValue))):
                guard comiketValue == Int64(expectedComiketNo) else {
                    throw SharedPlanError.syncProtocolViolation
                }
            case (Key.circles, .Object(_, .Map)),
                 (Key.operations, .Object(_, .Map)):
                break
            default:
                throw SharedPlanError.syncProtocolViolation
            }
        }
        guard patchedKeys == canonicalBootstrapRootKeys else {
            throw SharedPlanError.syncProtocolViolation
        }
        let metadata = try validateRetainedRootTopology(
            in: shadow,
            expectedPlanID: expectedPlanID,
            expectedComiketNo: expectedComiketNo
        )
        guard shadow.keys(obj: metadata.circles).isEmpty,
              shadow.keys(obj: metadata.operations).isEmpty
        else { throw SharedPlanError.syncProtocolViolation }
        return metadata
    }

    private static func validateRetainedRootTopology(
        in document: Document,
        expectedPlanID: String,
        expectedComiketNo: Int
    ) throws -> (
        planID: String,
        comiketNo: Int,
        circles: ObjId,
        operations: ObjId
    ) {
        guard Set(document.keys(obj: .ROOT)) == canonicalBootstrapRootKeys else {
            throw SharedPlanError.syncProtocolViolation
        }
        for key in canonicalBootstrapRootKeys {
            guard try document.getAll(obj: .ROOT, key: key).count == 1 else {
                throw SharedPlanError.syncProtocolViolation
            }
        }
        let metadata = try metadata(in: document)
        guard metadata.planID == expectedPlanID,
              metadata.comiketNo == expectedComiketNo
        else { throw SharedPlanError.syncProtocolViolation }
        return metadata
    }

    private func restore(from data: Data) throws {
        let restored = try Document(data)
        restored.actor = ActorId(uuid: replicaID)
        let metadata = try Self.metadata(in: restored)
        guard metadata.planID == planID, metadata.comiketNo == comiketNo else {
            throw SharedPlanError.persistenceFailed
        }
        document = restored
        circlesObject = metadata.circles
        operationsObject = metadata.operations
        let bootstrap = try Self.validateCanonicalBootstrap(
            in: restored,
            expectedPlanID: planID,
            expectedComiketNo: comiketNo
        )
        operationChangeHashes.removeAll()
        operationChangeHashHeads = nil
        operationValidationShadow = bootstrap.shadow
        operationValidationHistoryHashes = [bootstrap.changeHash]
        operationValidationGraph = try ChangeGraph(document: bootstrap.shadow)
        conflictInventoryHeads = nil
        cachedConflictInventory.removeAll()
        pendingRetainedPayloadBytes = nil
        // A rollback invalidates raw peer state; the caller reconnects with a
        // fresh session and generates new payload/frame identifiers.
        syncStates.removeAll()
    }

    private static func metadata(
        in document: Document
    ) throws -> (planID: String, comiketNo: Int, circles: ObjId, operations: ObjId) {
        guard Self.int(in: document, object: .ROOT, key: Key.schemaVersion)
                == Int(schemaVersion),
              let planID = try Self.string(in: document, object: .ROOT, key: Key.planID),
              let comiketNo = Self.int(in: document, object: .ROOT, key: Key.comiketNo),
              case let .Object(circles, .Map) = try document.get(obj: .ROOT, key: Key.circles),
              case let .Object(operations, .Map) = try document.get(
                  obj: .ROOT,
                  key: Key.operations
              )
        else { throw SharedPlanError.persistenceFailed }
        return (planID, comiketNo, circles, operations)
    }

    private static func changeHashes(_ strings: [String]) -> Set<ChangeHash>? {
        var raw = Data()
        for string in strings {
            guard string.utf8.count == 64, string == string.lowercased() else {
                return nil
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(32)
            for offset in stride(from: 0, to: 64, by: 2) {
                let pair = String(string.dropFirst(offset).prefix(2))
                guard let byte = UInt8(pair, radix: 16) else { return nil }
                bytes.append(byte)
            }
            raw.append(contentsOf: bytes)
        }
        return raw.heads()
    }

    private static func textPatch(from old: String, to new: String) -> TextPatch {
        let oldScalars = Array(old.unicodeScalars)
        let newScalars = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < oldScalars.count,
              prefix < newScalars.count,
              oldScalars[prefix] == newScalars[prefix]
        {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldScalars.count - prefix,
              suffix < newScalars.count - prefix,
              oldScalars[oldScalars.count - suffix - 1]
                == newScalars[newScalars.count - suffix - 1]
        {
            suffix += 1
        }
        var insert = ""
        for scalar in newScalars[prefix..<(newScalars.count - suffix)] {
            insert.unicodeScalars.append(scalar)
        }
        return TextPatch(
            start: UInt64(prefix),
            deleteCount: Int64(oldScalars.count - prefix - suffix),
            insert: insert
        )
    }

    private static func string(
        in document: Document,
        object: ObjId,
        key: String
    ) throws -> String? {
        switch try document.get(obj: object, key: key) {
        case .Scalar(.String(let value)):
            return value
        case .Object(let textObject, .Text):
            return try document.text(obj: textObject)
        default:
            return nil
        }
    }

    private static func int(in document: Document, object: ObjId, key: String) -> Int? {
        guard let value = try? document.get(obj: object, key: key) else { return nil }
        switch value {
        case let .Scalar(.Int(value)):
            return Int(exactly: value)
        case let .Scalar(.Uint(value)):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func uint(in document: Document, object: ObjId, key: String) -> UInt64? {
        guard let value = try? document.get(obj: object, key: key) else { return nil }
        switch value {
        case let .Scalar(.Uint(value)):
            return value
        case let .Scalar(.Int(value)) where value >= 0:
            return UInt64(value)
        default:
            return nil
        }
    }
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        guard base64URLString.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }) else { return nil }
        let padding = String(repeating: "=", count: (4 - base64URLString.count % 4) % 4)
        self.init(
            base64Encoded: base64URLString
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + padding
        )
    }
}
