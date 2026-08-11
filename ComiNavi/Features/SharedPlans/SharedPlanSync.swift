import CryptoKit
import Foundation

@propertyWrapper
struct CanonicalLowercaseUUID: Codable, Equatable, Sendable {
    var wrappedValue: UUID

    init(wrappedValue: UUID) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: value),
              value == uuid.uuidString.lowercased()
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "UUID is not canonical lowercase")
            )
        }
        wrappedValue = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.uuidString.lowercased())
    }
}

@propertyWrapper
struct CanonicalLowercaseUUIDString: Codable, Equatable, Sendable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard Self.isCanonical(value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "UUID string is not canonical lowercase"
                )
            )
        }
        wrappedValue = value
    }

    func encode(to encoder: Encoder) throws {
        guard Self.isCanonical(wrappedValue) else {
            throw EncodingError.invalidValue(
                wrappedValue,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "UUID string is not canonical lowercase"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    private static func isCanonical(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }
}

struct SharedPlanSyncBootstrap: Codable, Equatable, Sendable {
    let v: Int
    let document: String
    let heads: [String]
}

struct SharedPlanSyncHello: Codable, Equatable, Sendable {
    let v: Int
    let type: String
    @CanonicalLowercaseUUIDString var planID: String
    @CanonicalLowercaseUUID var sessionID: UUID
    let nextClientSeq: UInt64
    let nextServerSeq: UInt64
    let mutationsEnabled: Bool

    init(
        v: Int,
        type: String,
        planID: String,
        sessionID: UUID,
        nextClientSeq: UInt64,
        nextServerSeq: UInt64,
        mutationsEnabled: Bool = false
    ) {
        self.v = v
        self.type = type
        self.planID = planID
        self.sessionID = sessionID
        self.nextClientSeq = nextClientSeq
        self.nextServerSeq = nextServerSeq
        self.mutationsEnabled = mutationsEnabled
    }
}

struct SharedPlanClientSyncFrame: Codable, Equatable, Sendable {
    let v: Int
    let type: String
    @CanonicalLowercaseUUIDString var planID: String
    @CanonicalLowercaseUUID var sessionID: UUID
    @CanonicalLowercaseUUID var replicaID: UUID
    let actorID: String
    let seq: UInt64
    @CanonicalLowercaseUUID var frameID: UUID
    let payload: String
}

struct SharedPlanServerSyncFrame: Codable, Equatable, Sendable {
    let v: Int
    let type: String
    @CanonicalLowercaseUUIDString var planID: String
    @CanonicalLowercaseUUID var sessionID: UUID
    let seq: UInt64
    @CanonicalLowercaseUUID var frameID: UUID
    let payload: String
}

struct SharedPlanSyncAcknowledgement: Codable, Equatable, Sendable {
    let v: Int
    let type: String
    @CanonicalLowercaseUUID var sessionID: UUID
    let ackSeq: UInt64
    @CanonicalLowercaseUUID var frameID: UUID
    let documentHeads: [String]
}

struct SharedPlanSyncDocumentIdentity: Equatable, Sendable {
    let replicaID: UUID
    let actorID: String
    let heads: [String]
}

struct SharedPlanSyncErrorFrame: Codable, Equatable, Sendable {
    struct Details: Codable, Equatable, Sendable {
        let maximumNewOperationsPerSyncFrame: Int?
        let receivedChanges: Int?
        let reason: String?
        let recovery: String?
        let localChangesPreserved: Bool?
        let supportCode: String?

        init(
            maximumNewOperationsPerSyncFrame: Int? = nil,
            receivedChanges: Int? = nil,
            reason: String? = nil,
            recovery: String? = nil,
            localChangesPreserved: Bool? = nil,
            supportCode: String? = nil
        ) {
            self.maximumNewOperationsPerSyncFrame = maximumNewOperationsPerSyncFrame
            self.receivedChanges = receivedChanges
            self.reason = reason
            self.recovery = recovery
            self.localChangesPreserved = localChangesPreserved
            self.supportCode = supportCode
        }
    }

    let v: Int
    let type: String
    let code: String
    let message: String
    let retryable: Bool
    let details: Details?
}

enum SharedPlanSyncSessionState: Equatable, Sendable {
    case disconnected
    case connected(sessionID: UUID)
    case failed(code: String, retryable: Bool)
}

/// Ordered WebSocket session state. Raw frames intentionally live only here:
/// a disconnect discards them and resets Automerge peer state, while the
/// document and semantic operation IDs remain durable in SQLite.
actor SharedPlanSyncSession {
    private struct InboundReceipt {
        let frameID: UUID
        let payloadHash: String
    }

    private struct OutboundReceipt {
        let frame: SharedPlanClientSyncFrame
        let payloadHash: String
        let pendingOperationIDs: Set<UUID>
        let requiredDocumentHeads: [String]
    }

    private struct AcknowledgedReceipt {
        let sequence: UInt64
        let documentHeads: [String]
    }

    let planID: String
    private let document: SharedPlanAutomergeDocument
    private(set) var state: SharedPlanSyncSessionState = .disconnected
    private(set) var mutationsEnabled = false

    private var sessionID: UUID?
    private var nextClientSequence: UInt64 = 1
    private var nextServerSequence: UInt64 = 1
    /// The most recently sent frame is retained byte-for-byte until any
    /// ordered response proves that the live socket advanced. Older sent
    /// frames remain addressable for their later semantic acknowledgement.
    private var awaitingResponse: OutboundReceipt?
    private var outboundReceipts: [UUID: OutboundReceipt] = [:]
    private var acknowledgedReceipts: [UUID: AcknowledgedReceipt] = [:]
    private var deferredAcknowledgementProofs: [UUID: OutboundReceipt] = [:]
    private var inboundReceipts: [UInt64: InboundReceipt] = [:]
    /// A fresh Automerge peer state first exchanges heads. That negotiation
    /// proves no semantic edit was durably accepted, so its receipt must never
    /// clear operation IDs even when local edits are already queued.
    private var hasGeneratedNegotiation = false

    init(planID: String, document: SharedPlanAutomergeDocument) {
        self.planID = planID
        self.document = document
    }

    func documentIdentity() async -> SharedPlanSyncDocumentIdentity {
        SharedPlanSyncDocumentIdentity(
            replicaID: document.replicaID,
            actorID: await document.actorID(),
            heads: await document.heads()
        )
    }

    func receiveHello(_ hello: SharedPlanSyncHello) async throws {
        guard hello.v == 1,
              hello.type == "hello",
              hello.planID == planID,
              hello.nextClientSeq == 1,
              hello.nextServerSeq == 1
        else {
            await disconnect()
            throw SharedPlanError.syncProtocolViolation
        }
        await disconnect()
        sessionID = hello.sessionID
        nextClientSequence = hello.nextClientSeq
        nextServerSequence = hello.nextServerSeq
        mutationsEnabled = hello.mutationsEnabled
        state = .connected(sessionID: hello.sessionID)
        await document.beginSyncSession(id: hello.sessionID)
    }

    /// Returns the exact same frame while it is unacknowledged. A recomputed
    /// payload is assigned a new frame ID only after the prior one is acked or
    /// the entire ordered session is discarded.
    func nextOutboundFrame(
        pendingOperationIDs: [UUID] = []
    ) async throws -> SharedPlanClientSyncFrame? {
        if let awaitingResponse { return awaitingResponse.frame }
        guard let sessionID,
              state == .connected(sessionID: sessionID)
        else { throw SharedPlanError.syncProtocolViolation }
        let message: Data
        do {
            guard let generated = try await document.generateSyncMessage(sessionID: sessionID)
            else { return nil }
            message = generated
        } catch {
            await failProtocol()
            throw error
        }
        let frame = SharedPlanClientSyncFrame(
            v: 1,
            type: "sync",
            planID: planID,
            sessionID: sessionID,
            replicaID: document.replicaID,
            actorID: await document.actorID(),
            seq: nextClientSequence,
            frameID: UUID(),
            payload: message.base64URLEncodedString
        )
        let receipt = OutboundReceipt(
            frame: frame,
            payloadHash: Self.digest(message),
            pendingOperationIDs: hasGeneratedNegotiation ? Set(pendingOperationIDs) : [],
            requiredDocumentHeads: await document.heads()
        )
        hasGeneratedNegotiation = true
        awaitingResponse = receipt
        outboundReceipts[frame.frameID] = receipt
        nextClientSequence += 1
        return frame
    }

    /// Only this exact immutable frame may be retried while the ordered
    /// WebSocket session is still live. Disconnect clears it permanently.
    func outboundFrameAwaitingResponse() -> SharedPlanClientSyncFrame? {
        awaitingResponse?.frame
    }

    /// Persists removal of the semantic IDs before accepting the receipt. If
    /// persistence fails, the IDs remain durable and reconnect regenerates a
    /// fresh raw payload/frame rather than losing local work.
    @discardableResult
    func receiveAcknowledgement(
        _ acknowledgement: SharedPlanSyncAcknowledgement,
        persistAcknowledgedOperations: @Sendable (Set<UUID>) async throws -> Void = { _ in }
    ) async throws -> Set<UUID> {
        guard acknowledgement.v == 1,
              acknowledgement.type == "ack",
              acknowledgement.sessionID == sessionID
        else {
            await failProtocol()
            throw SharedPlanError.syncProtocolViolation
        }
        if let acknowledged = acknowledgedReceipts[acknowledgement.frameID] {
            guard acknowledged.sequence == acknowledgement.ackSeq,
                  acknowledged.documentHeads == acknowledgement.documentHeads
            else {
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
            return []
        }
        guard let receipt = outboundReceipts[acknowledgement.frameID],
              acknowledgement.ackSeq == receipt.frame.seq
        else {
            await failProtocol()
            throw SharedPlanError.syncProtocolViolation
        }

        var acknowledgedOperationIDs: Set<UUID> = []
        if !receipt.pendingOperationIDs.isEmpty {
            let semanticOperationIDs = await document.semanticOperationIDs()
            guard receipt.pendingOperationIDs.isSubset(of: semanticOperationIDs) else {
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
            switch await document.acknowledgedHeadProof(
                acknowledgement.documentHeads,
                causallyContain: receipt.requiredDocumentHeads
            ) {
            case .contained:
                acknowledgedOperationIDs = receipt.pendingOperationIDs
            case .unknown:
                deferredAcknowledgementProofs[acknowledgement.frameID] = receipt
            case .missing:
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
        }

        try await persistAcknowledgedOperations(acknowledgedOperationIDs)
        outboundReceipts[acknowledgement.frameID] = nil
        acknowledgedReceipts[acknowledgement.frameID] = AcknowledgedReceipt(
            sequence: acknowledgement.ackSeq,
            documentHeads: acknowledgement.documentHeads
        )
        if awaitingResponse?.frame.frameID == acknowledgement.frameID {
            awaitingResponse = nil
        }
        return acknowledgedOperationIDs
    }

    /// Rechecks acknowledgements whose server heads were unknown locally when
    /// the ack arrived. Backend ordering is ack-then-sync; semantic IDs remain
    /// durable until a later received document proves causal containment.
    func resolveDeferredAcknowledgements(
        persistAcknowledgedOperations: @Sendable (Set<UUID>) async throws -> Void = { _ in }
    ) async throws -> Set<UUID> {
        var resolvedFrameIDs: [UUID] = []
        var operationIDs: Set<UUID> = []
        for (frameID, receipt) in deferredAcknowledgementProofs {
            guard let acknowledged = acknowledgedReceipts[frameID] else {
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
            switch await document.acknowledgedHeadProof(
                acknowledged.documentHeads,
                causallyContain: receipt.requiredDocumentHeads
            ) {
            case .contained:
                operationIDs.formUnion(receipt.pendingOperationIDs)
                resolvedFrameIDs.append(frameID)
            case .unknown:
                continue
            case .missing:
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
        }
        guard !resolvedFrameIDs.isEmpty else { return [] }
        try await persistAcknowledgedOperations(operationIDs)
        for frameID in resolvedFrameIDs {
            deferredAcknowledgementProofs[frameID] = nil
        }
        return operationIDs
    }

    /// Returns `false` for an exact already-applied duplicate. A reordered or
    /// gapped nonduplicate fails closed and requires a fresh hello.
    @discardableResult
    func receiveServerFrame(
        _ frame: SharedPlanServerSyncFrame,
        pendingOperationIDs: [UUID] = [],
        syncIssue: SharedPlanSyncIssue? = nil,
        localEditLimit: SharedPlanLocalEditLimit? = nil,
        persist: @Sendable (
            SharedPlanDocumentSnapshot,
            [SharedPlanCircleKey]
        ) async throws -> Void = { _, _ in }
    ) async throws -> Bool {
        guard frame.v == 1,
              frame.type == "sync",
              frame.planID == planID,
              frame.sessionID == sessionID,
              let payload = Data(base64URLString: frame.payload),
              payload.count <= SharedPlanAutomergeDocument.maximumDecodedSyncMessageBytes
        else {
            await failProtocol()
            throw SharedPlanError.syncProtocolViolation
        }
        let hash = Self.digest(payload)
        if frame.seq < nextServerSequence {
            guard let receipt = inboundReceipts[frame.seq],
                  receipt.frameID == frame.frameID,
                  receipt.payloadHash == hash
            else {
                await failProtocol()
                throw SharedPlanError.syncProtocolViolation
            }
            return false
        }
        guard frame.seq == nextServerSequence,
              !inboundReceipts.values.contains(where: {
                  $0.frameID == frame.frameID
              })
        else {
            await failProtocol()
            throw SharedPlanError.syncProtocolViolation
        }

        do {
            try await document.receiveSyncMessageDurably(
                sessionID: frame.sessionID,
                message: payload,
                pendingOperationIDs: pendingOperationIDs,
                syncIssue: syncIssue,
                localEditLimit: localEditLimit,
                persist: persist
            )
        } catch {
            await failProtocol()
            throw error
        }
        inboundReceipts[frame.seq] = InboundReceipt(
            frameID: frame.frameID,
            payloadHash: hash
        )
        nextServerSequence += 1
        // WebSocket ordering guarantees every previously sent client frame
        // stays ahead of a newly generated frame. A server sync response lets
        // Automerge advance even though the explicit semantic ack may follow.
        awaitingResponse = nil
        return true
    }

    func receiveError(_ error: SharedPlanSyncErrorFrame) async {
        state = .failed(code: error.code, retryable: error.retryable)
        if let sessionID { await document.endSyncSession(id: sessionID) }
        sessionID = nil
        awaitingResponse = nil
        outboundReceipts.removeAll()
        acknowledgedReceipts.removeAll()
        deferredAcknowledgementProofs.removeAll()
        inboundReceipts.removeAll()
        nextClientSequence = 1
        nextServerSequence = 1
        hasGeneratedNegotiation = false
        mutationsEnabled = false
    }

    func disconnect() async {
        if let sessionID { await document.endSyncSession(id: sessionID) }
        sessionID = nil
        awaitingResponse = nil
        outboundReceipts.removeAll()
        acknowledgedReceipts.removeAll()
        deferredAcknowledgementProofs.removeAll()
        inboundReceipts.removeAll()
        nextClientSequence = 1
        nextServerSequence = 1
        hasGeneratedNegotiation = false
        mutationsEnabled = false
        state = .disconnected
    }

    private func failProtocol() async {
        if let sessionID { await document.endSyncSession(id: sessionID) }
        sessionID = nil
        awaitingResponse = nil
        outboundReceipts.removeAll()
        acknowledgedReceipts.removeAll()
        deferredAcknowledgementProofs.removeAll()
        inboundReceipts.removeAll()
        nextClientSequence = 1
        nextServerSequence = 1
        hasGeneratedNegotiation = false
        mutationsEnabled = false
        state = .failed(code: "sync_protocol_violation", retryable: true)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
