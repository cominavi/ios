import Foundation

enum SharedPlanPresenceState: String, Codable, Equatable, Sendable {
    case active
    case removed
}

enum SharedPlanOperationType: String, Codable, CaseIterable, Equatable, Sendable {
    case circlePresence = "shared_plan.circle.presence.v1"
    case circleResolveParent = "shared_plan.circle.resolve_parent.v1"
    case circleMemoSplice = "shared_plan.circle.memo.splice.v1"
    case needCreate = "shared_plan.need.create.v1"
    case needDelete = "shared_plan.need.delete.v1"
    case needResolveParent = "shared_plan.need.resolve_parent.v1"
    case needWantedQuantity = "shared_plan.need.wanted_quantity.v1"
    case needBuyerAllocation = "shared_plan.need.buyer_allocation.v1"
    case needFulfilledQuantity = "shared_plan.need.fulfilled_quantity.v1"
    case circleCommunicationSet = "shared_plan.circle.communication.set.v1"
}

/// A JSON-shaped, integer-only value used by communication fields and explicit
/// nested conflict resolutions. Keeping this typed prevents Foundation from
/// silently converting a protocol integer to a floating-point scalar.
indirect enum SharedPlanJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case string(String)
    case array([SharedPlanJSONValue])
    case object([String: SharedPlanJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SharedPlanJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SharedPlanJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Shared Plan values must be JSON values with signed integers"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case .boolean(let value):
            value
        case .integer(let value):
            value
        case .string(let value):
            value
        case .array(let value):
            value.map(\.foundationValue)
        case .object(let value):
            value.mapValues(\.foundationValue)
        }
    }

    var objectValue: [String: SharedPlanJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    var arrayValue: [SharedPlanJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}

struct SharedPlanNestedConflictResolution: Codable, Equatable, Identifiable, Sendable {
    let conflictID: String
    let path: [String]
    let selectedChangeHash: String
    let value: SharedPlanJSONValue

    var id: String { conflictID }
}

struct SharedPlanConflict: Codable, Equatable, Identifiable, Sendable {
    let conflictID: String
    let path: [String]
    let changeHashes: [String]

    var id: String { conflictID }
}

enum SharedPlanDocumentConflictKind: String, Codable, Equatable, Sendable {
    case parent
    case scalar
    case removalVersusEdit
}

struct SharedPlanConflictCandidate: Codable, Equatable, Identifiable, Sendable {
    let changeHash: String
    let operationID: UUID
    let actorUserID: String
    let value: SharedPlanJSONValue
    let rootOperationID: UUID?

    var id: String { changeHash }
}

extension SharedPlanConflictCandidate {
    private enum CodingKeys: String, CodingKey {
        case changeHash
        case operationID
        case actorUserID
        case value
        case rootOperationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changeHash = try container.decode(String.self, forKey: .changeHash)
        actorUserID = try container.decode(String.self, forKey: .actorUserID)
        value = try container.decode(SharedPlanJSONValue.self, forKey: .value)
        operationID = try Self.canonicalUUID(
            try container.decode(String.self, forKey: .operationID),
            key: .operationID,
            container: container
        )
        if let rawRoot = try container.decodeIfPresent(String.self, forKey: .rootOperationID) {
            rootOperationID = try Self.canonicalUUID(
                rawRoot,
                key: .rootOperationID,
                container: container
            )
        } else {
            rootOperationID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changeHash, forKey: .changeHash)
        try container.encode(operationID.uuidString.lowercased(), forKey: .operationID)
        try container.encode(actorUserID, forKey: .actorUserID)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(
            rootOperationID?.uuidString.lowercased(),
            forKey: .rootOperationID
        )
    }

    private static func canonicalUUID(
        _ raw: String,
        key: CodingKeys,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> UUID {
        guard raw == raw.lowercased(), let value = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Shared Plan UUIDs must be canonical lowercase strings"
            )
        }
        return value
    }
}

/// A deterministic, restart-stable view of one unresolved Automerge conflict.
/// Candidate values come from the retained semantic ledger and conflict graph,
/// never from the visible Automerge winner alone.
struct SharedPlanDocumentConflict: Codable, Equatable, Identifiable, Sendable {
    let conflictID: String
    let kind: SharedPlanDocumentConflictKind
    let path: [String]
    /// The hashes that define the stable conflict identity. For a parent
    /// resolver these can differ from the selectable assignments when the
    /// selected parent already supplies a value at the same nested path.
    let sourceChangeHashes: [String]
    let candidates: [SharedPlanConflictCandidate]
    let parentRootOperationIDs: [UUID]

    var id: String { conflictID }
    var changeHashes: [String] { sourceChangeHashes }

    init(
        conflictID: String,
        kind: SharedPlanDocumentConflictKind,
        path: [String],
        sourceChangeHashes: [String]? = nil,
        candidates: [SharedPlanConflictCandidate],
        parentRootOperationIDs: [UUID] = []
    ) {
        self.conflictID = conflictID
        self.kind = kind
        self.path = path
        self.sourceChangeHashes = sourceChangeHashes
            ?? candidates.map(\.changeHash).sorted()
        self.candidates = candidates
        self.parentRootOperationIDs = parentRootOperationIDs
    }
}

struct SharedPlanParentResolutionInventory: Equatable, Sendable {
    let parentConflict: SharedPlanDocumentConflict
    let selectedParentOperationID: UUID
    let requiredNestedConflicts: [SharedPlanDocumentConflict]
}

struct SharedPlanOperationRecord: Equatable, Identifiable, Sendable {
    let id: UUID
    let type: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
    let changeHash: String?

    func durableMutation(comiketNo: Int) throws -> SharedPlanDurableMutation {
        guard payload["v"] == .integer(1),
              let rawWCID = payload["wcID"]?.integerValue,
              let wcID = Int(exactly: rawWCID),
              let circle = SharedPlanCircleKey(comiketNo: comiketNo, wcID: wcID)
        else { throw SharedPlanError.syncProtocolViolation }

        switch type {
        case .circlePresence:
            guard let value = payload["state"]?.stringValue,
                  let state = SharedPlanPresenceState(rawValue: value)
            else { throw SharedPlanError.syncProtocolViolation }
            return .setCirclePresence(circle, state)

        case .circleMemoSplice:
            guard let rawIndex = payload["index"]?.integerValue,
                  let rawDeleteCount = payload["deleteCount"]?.integerValue,
                  let index = Int(exactly: rawIndex),
                  let deleteCount = Int(exactly: rawDeleteCount),
                  let text = payload["text"]?.stringValue
            else { throw SharedPlanError.syncProtocolViolation }
            return .spliceMemo(
                circle: circle,
                index: index,
                deleteCount: deleteCount,
                text: text
            )

        case .needCreate:
            let needID = try requiredUUID("needID")
            guard let requester = payload["requesterUserID"]?.stringValue,
                  let rawWanted = payload["wantedQuantity"]?.integerValue,
                  let wanted = Int(exactly: rawWanted)
            else { throw SharedPlanError.syncProtocolViolation }
            return .createNeed(
                SharedPlanPurchaseNeed(
                    id: needID,
                    requesterUserID: requester,
                    wantedQuantity: wanted
                ),
                circle: circle
            )

        case .needDelete:
            return .deleteNeed(try requiredUUID("needID"), circle: circle)

        case .needWantedQuantity:
            guard let rawQuantity = payload["wantedQuantity"]?.integerValue,
                  let quantity = Int(exactly: rawQuantity)
            else { throw SharedPlanError.syncProtocolViolation }
            return .setWantedQuantity(
                quantity,
                needID: try requiredUUID("needID"),
                circle: circle
            )

        case .needBuyerAllocation:
            guard let rawQuantity = payload["quantity"]?.integerValue,
                  let quantity = Int(exactly: rawQuantity),
                  let buyer = payload["buyerUserID"]?.stringValue
            else { throw SharedPlanError.syncProtocolViolation }
            return .setBuyerAllocation(
                quantity,
                buyerUserID: buyer,
                needID: try requiredUUID("needID"),
                circle: circle
            )

        case .needFulfilledQuantity:
            guard let rawQuantity = payload["fulfilledQuantity"]?.integerValue,
                  let quantity = Int(exactly: rawQuantity)
            else { throw SharedPlanError.syncProtocolViolation }
            return .setFulfilledQuantity(
                quantity,
                needID: try requiredUUID("needID"),
                circle: circle
            )

        case .circleCommunicationSet:
            guard let key = payload["key"]?.stringValue,
                  let value = payload["value"]
            else { throw SharedPlanError.syncProtocolViolation }
            return .setCommunication(value, key: key, circle: circle)

        case .circleResolveParent:
            return .resolveCircleParent(
                circle: circle,
                selectedParentOperationID: try requiredUUID(
                    "selectedParentOperationID"
                ),
                state: try requiredPresenceState(),
                nestedResolutions: try requiredNestedResolutions()
            )

        case .needResolveParent:
            return .resolveNeedParent(
                needID: try requiredUUID("needID"),
                circle: circle,
                selectedParentOperationID: try requiredUUID(
                    "selectedParentOperationID"
                ),
                state: try requiredPresenceState(),
                nestedResolutions: try requiredNestedResolutions()
            )
        }
    }

    private func requiredUUID(_ key: String) throws -> UUID {
        guard let value = payload[key]?.stringValue,
              let uuid = UUID(uuidString: value),
              value == uuid.uuidString.lowercased()
        else { throw SharedPlanError.syncProtocolViolation }
        return uuid
    }

    private func requiredPresenceState() throws -> SharedPlanPresenceState {
        guard let value = payload["state"]?.stringValue,
              let state = SharedPlanPresenceState(rawValue: value)
        else { throw SharedPlanError.syncProtocolViolation }
        return state
    }

    private func requiredNestedResolutions() throws
        -> [SharedPlanNestedConflictResolution]
    {
        guard let values = payload["nestedResolutions"]?.arrayValue else {
            throw SharedPlanError.syncProtocolViolation
        }
        return try values.map { value in
            guard let object = value.objectValue,
                  let conflictID = object["conflictID"]?.stringValue,
                  let selectedChangeHash = object["selectedChangeHash"]?.stringValue,
                  let pathValues = object["path"]?.arrayValue,
                  let resolutionValue = object["value"]
            else { throw SharedPlanError.syncProtocolViolation }
            let path = try pathValues.map { component in
                guard let value = component.stringValue else {
                    throw SharedPlanError.syncProtocolViolation
                }
                return value
            }
            return SharedPlanNestedConflictResolution(
                conflictID: conflictID,
                path: path,
                selectedChangeHash: selectedChangeHash,
                value: resolutionValue
            )
        }
    }
}

enum SharedPlanCanonicalJSON {
    static func data(_ value: SharedPlanJSONValue) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value.foundationValue) else {
            throw SharedPlanError.persistenceFailed
        }
        return try JSONSerialization.data(
            withJSONObject: value.foundationValue,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func payloadBytes(_ payload: [String: SharedPlanJSONValue]) throws -> Int {
        try data(.object(payload)).count
    }
}
