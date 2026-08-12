import Foundation

struct SharedPlanCircleKey: Codable, Hashable, Identifiable, Sendable {
    let comiketNo: Int
    let wcID: Int

    init?(comiketNo: Int, wcID: Int) {
        guard comiketNo > 0, wcID > 0 else { return nil }
        self.comiketNo = comiketNo
        self.wcID = wcID
    }

    var id: String { "\(comiketNo):\(wcID)" }
}

enum SharedPlanOwnership: String, Codable, Equatable, Sendable {
    case owned
    case joined
}

enum SharedPlanRole: String, Codable, Equatable, Sendable {
    case owner
    case editor
    case viewer
}

enum SharedPlanLifecycle: String, Codable, Equatable, Sendable {
    case active
    case archived
}

struct SharedPlan: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let comiketNo: Int
    var ownership: SharedPlanOwnership
    var role: SharedPlanRole
    var lifecycle: SharedPlanLifecycle
    var revision: Int
    var circleKeys: [SharedPlanCircleKey]
    let createdAt: Date
    var updatedAt: Date

    var isOwnedActive: Bool {
        ownership == .owned && lifecycle == .active
    }
}

enum SharedPlanSemanticOperationKind: String, Codable, Equatable, Sendable {
    case createPlan
    case renamePlan
    case archivePlan
    case reopenPlan
    case addCircle
    case removeCircle
    case updateMemo
    case updatePurchaseNeed
}

struct SharedPlanPurchaseNeed: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var requesterUserID: String
    var itemName: String
    var unitPrice: Int?
    var wantedQuantity: Int
    var buyerAllocations: [String: Int]
    var fulfilledQuantity: Int

    init(
        id: UUID,
        requesterUserID: String,
        itemName: String = "",
        unitPrice: Int? = nil,
        wantedQuantity: Int,
        buyerAllocations: [String: Int] = [:],
        fulfilledQuantity: Int = 0
    ) {
        self.id = id
        self.requesterUserID = requesterUserID
        self.itemName = itemName
        self.unitPrice = unitPrice
        self.wantedQuantity = wantedQuantity
        self.buyerAllocations = buyerAllocations
        self.fulfilledQuantity = fulfilledQuantity
    }
}

struct SharedPlanCircleContent: Equatable, Identifiable, Sendable {
    var id: String { key.id }
    let key: SharedPlanCircleKey
    let presence: SharedPlanCirclePresence
    let memo: String
    let needs: [SharedPlanPurchaseNeed]
    let communicationState: [String: SharedPlanJSONValue]
}

struct SharedPlanSemanticOperation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let planID: String
    let replicaID: UUID
    let kind: SharedPlanSemanticOperationKind
    let circleKey: SharedPlanCircleKey?
    let authoredAt: Date
}

enum SharedPlanRESTWriteKind: String, Codable, Equatable, Sendable {
    case create
    case rename
    case archive
    case reopen
    case acceptInvitation
    case revokeMember
    case reinstateMember
    case transferOwnership
    case createInvitation
    case revokeInvitation
}

enum SharedPlanRESTWriteQuarantineReason: String, Codable, Equatable, Sendable {
    case membershipRevoked
    case revisionConflict
    case terminalFailure
}

struct SharedPlanRESTWrite: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let planID: String
    let kind: SharedPlanRESTWriteKind
    let baseRevision: Int?
    let name: String?
    let comiketNo: Int?
    let inviteToken: String?
    let targetUserID: String?
    let invitationID: String?
    let expiresAt: Date?
    let createdAt: Date

    /// A quarantined write remains durable for user recovery, but is never
    /// eligible for automatic network delivery. Optional fields preserve
    /// decoding of v1 rows created before quarantine metadata existed.
    let quarantineReason: SharedPlanRESTWriteQuarantineReason?
    let conflictRevision: Int?
    let quarantineCode: String?
    let quarantineMessage: String?

    init(
        id: UUID,
        planID: String,
        kind: SharedPlanRESTWriteKind,
        baseRevision: Int?,
        name: String?,
        comiketNo: Int?,
        inviteToken: String?,
        targetUserID: String? = nil,
        invitationID: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date,
        quarantineReason: SharedPlanRESTWriteQuarantineReason? = nil,
        conflictRevision: Int? = nil,
        quarantineCode: String? = nil,
        quarantineMessage: String? = nil
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.baseRevision = baseRevision
        self.name = name
        self.comiketNo = comiketNo
        self.inviteToken = inviteToken
        self.targetUserID = targetUserID
        self.invitationID = invitationID
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.quarantineReason = quarantineReason
        self.conflictRevision = conflictRevision
        self.quarantineCode = quarantineCode
        self.quarantineMessage = quarantineMessage
    }

    var isQuarantined: Bool { quarantineReason != nil }

    func rebased(to revision: Int) -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: id,
            planID: planID,
            kind: kind,
            baseRevision: revision,
            name: name,
            comiketNo: comiketNo,
            inviteToken: inviteToken,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            quarantineReason: quarantineReason,
            conflictRevision: conflictRevision,
            quarantineCode: quarantineCode,
            quarantineMessage: quarantineMessage
        )
    }

    func quarantined(
        for reason: SharedPlanRESTWriteQuarantineReason,
        currentRevision: Int? = nil,
        code: String? = nil,
        message: String? = nil
    ) -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: id,
            planID: planID,
            kind: kind,
            baseRevision: baseRevision,
            name: name,
            comiketNo: comiketNo,
            inviteToken: inviteToken,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            quarantineReason: reason,
            conflictRevision: currentRevision,
            quarantineCode: code,
            quarantineMessage: message
        )
    }

    func removingInviteCapability() -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: id,
            planID: planID,
            kind: kind,
            baseRevision: baseRevision,
            name: name,
            comiketNo: comiketNo,
            inviteToken: nil,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            quarantineReason: quarantineReason,
            conflictRevision: conflictRevision,
            quarantineCode: quarantineCode,
            quarantineMessage: quarantineMessage
        )
    }

    func recordingInvitationID(_ invitationID: String) -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: id,
            planID: planID,
            kind: kind,
            baseRevision: baseRevision,
            name: name,
            comiketNo: comiketNo,
            inviteToken: inviteToken,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            quarantineReason: quarantineReason,
            conflictRevision: conflictRevision,
            quarantineCode: quarantineCode,
            quarantineMessage: quarantineMessage
        )
    }
}

enum SharedPlanSyncIssue: Codable, Equatable, Sendable {
    case membershipRevoked
    case roleChanged
    case conflict(String)
    case unavailable(String)
    /// The server rejected a locally retained semantic change. The support
    /// code is safe to show and helps diagnose client/server rollout skew;
    /// operation payloads and document internals are never exposed.
    case rejectedLocalChanges(supportCode: String?)
    /// An already-durable snapshot cannot stay within the local document or
    /// retained-operation bounds. It is exportable, but not syncable.
    case compactionRequired
    /// The server rejected the exact branch/frame as unsplittable. This is a
    /// terminal sync quarantine until explicit discard/rebase.
    case serverCompactionRequired
    case backlogLimit(maximum: Int, received: Int)
}

enum SharedPlanLocalEditLimit: Codable, Equatable, Sendable {
    case compactionRequired
    case syncBacklog(maximum: Int, pending: Int)
}

struct SharedPlanRecoveryDocument: Equatable, Identifiable, Sendable {
    let id: String
    let planID: String
    let pendingOperationCount: Int
    let metadataIntentCount: Int
    let exportText: String

    init(
        id: String? = nil,
        planID: String,
        pendingOperationCount: Int,
        metadataIntentCount: Int,
        exportText: String
    ) {
        self.id = id ?? planID
        self.planID = planID
        self.pendingOperationCount = pendingOperationCount
        self.metadataIntentCount = metadataIntentCount
        self.exportText = exportText
    }
}

struct SharedPlanCreateAvailability: Equatable, Sendable {
    static let maximumOwnedActivePlans = 50

    let activeOwnedCount: Int

    var remainingCount: Int {
        max(0, Self.maximumOwnedActivePlans - activeOwnedCount)
    }

    var canCreate: Bool {
        activeOwnedCount < Self.maximumOwnedActivePlans
    }
}

enum SharedPlanError: LocalizedError, Equatable {
    case invalidName
    case planLimitReached(comiketNo: Int)
    case planNotFound
    case eventMismatch(expected: Int, received: Int)
    case insufficientRole
    case membershipRevoked
    case invalidInvite
    case removedMember
    case revisionConflict
    case invitationTokenAlreadyReturned(invitationID: String)
    case documentLimit(String)
    case planCompactionRequired
    case planSyncBacklogLimit(maximum: Int, received: Int)
    case syncPayloadTooLarge
    case syncProtocolViolation
    case profileRequired
    case profileMutationPending
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidName:
            String(localized: "プラン名を入力してください。")
        case .planLimitReached:
            String(localized: "このコミケで作成できる有効なプランは50件までです。")
        case .planNotFound:
            String(localized: "プランが見つかりません。")
        case .eventMismatch:
            String(localized: "別のコミケのサークルは追加できません。")
        case .insufficientRole:
            String(localized: "このプランを編集する権限がありません。")
        case .membershipRevoked:
            String(localized: "このプランへの参加権限が取り消されました。未送信の変更は残っています。")
        case .invalidInvite:
            String(localized: "招待リンクが正しくありません。")
        case .removedMember:
            String(localized: "この招待では再参加できません。オーナーに再招待を依頼してください。")
        case .revisionConflict:
            String(localized: "別の場所でプランが更新されました。残っている変更を確認してください。")
        case .invitationTokenAlreadyReturned:
            String(localized: "招待は作成済みですが、安全のため招待コードを再表示できません。新しい招待を作成してください。")
        case .documentLimit(let message):
            message
        case .planCompactionRequired:
            String(localized: "変更が多いため、このプランを続けて編集できません。内容を書き出してから、最新のプランでやり直してください。")
        case .planSyncBacklogLimit:
            String(localized: "変更が多すぎます。内容を書き出してから、最新のプランでやり直してください。")
        case .syncPayloadTooLarge:
            String(localized: "送信する変更が大きすぎます。内容を減らしてもう一度お試しください。")
        case .syncProtocolViolation:
            String(localized: "プランを更新できないため、再接続します。")
        case .profileRequired:
            String(localized: "プロフィールを読み込んでからもう一度お試しください。")
        case .profileMutationPending:
            String(localized: "前のプロフィール変更を確認できるまで、新しい変更は保存できません。もう一度同じ操作をお試しください。")
        case .persistenceFailed:
            String(localized: "変更を保存できませんでした。")
        }
    }
}

enum SharedPlanValidation {
    static func normalizedPlanName(_ value: String) throws -> String {
        try normalized(value, maximumUnicodeScalars: 100)
    }

    static func normalizedProfileDisplayName(_ value: String) throws -> String {
        try normalized(value, maximumUnicodeScalars: 80)
    }

    private static func normalized(
        _ value: String,
        maximumUnicodeScalars: Int
    ) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty,
              result.unicodeScalars.count <= maximumUnicodeScalars
        else { throw SharedPlanError.invalidName }
        return result
    }
}

struct SharedPlanInvitationPreview: Codable, Equatable, Sendable {
    let planID: String
    let planName: String
    let comiketNo: Int
    let expiresAt: Date
}

enum SharedPlanMembershipStatus: String, Codable, Equatable, Sendable {
    case active
    case removed
}

struct SharedPlanMember: Codable, Equatable, Identifiable, Sendable {
    var id: String { userID }

    let userID: String
    let displayName: String
    let avatarURL: URL?
    let role: SharedPlanRole
    let membershipStatus: SharedPlanMembershipStatus
    let joinedAt: Date
    let removedAt: Date?
}

struct SharedPlanMemberPage: Equatable, Sendable {
    let items: [SharedPlanMember]
    let nextCursor: String?
}

struct SharedPlanInvitation: Codable, Equatable, Identifiable, Sendable {
    var id: String { invitationID }

    let invitationID: String
    let createdByUserID: String
    let currentUserCanRevoke: Bool
    let expiresAt: Date
    let revokedAt: Date?
    let createdAt: Date
}

struct SharedPlanInvitationPage: Equatable, Sendable {
    let items: [SharedPlanInvitation]
    let nextCursor: String?
}

struct SharedPlanMutationReceipt: Codable, Equatable, Sendable {
    let requestID: UUID
    let replayed: Bool
    let resultRevision: Int
    let resultStatus: SharedPlanLifecycle
}

struct SharedPlanCreatedInvitation: Codable, Equatable, Identifiable, Sendable {
    var id: String { invitationID }

    let requestID: UUID
    let planID: String
    let invitationID: String
    let token: String
    let expiresAt: Date
    let canonicalURL: URL
    let fallbackURL: URL
    let receipt: SharedPlanMutationReceipt
}

enum SharedPlanNotificationKind: String, Codable, Equatable, Sendable {
    case sharedPlanEvent
}

struct SharedPlanOperationNotificationPayload: Codable, Equatable, Sendable {
    let v: Int
    let planID: String
    let operationID: String
    let operationType: SharedPlanOperationType
    let actorUserID: String
    let payload: [String: SharedPlanJSONValue]
    let heads: [String]
    let membershipEpoch: Int
}

struct SharedPlanConflictNotificationPayload: Codable, Equatable, Sendable {
    let v: Int
    let planID: String
    let conflictID: String
    let path: [String]
    let changeHashes: [String]
    let heads: [String]
    let membershipEpoch: Int
}

enum SharedPlanNotificationPayload: Codable, Equatable, Sendable {
    case operation(SharedPlanOperationNotificationPayload)
    case conflict(SharedPlanConflictNotificationPayload)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let operation = try? container.decode(SharedPlanOperationNotificationPayload.self) {
            self = .operation(operation)
            return
        }
        self = .conflict(try container.decode(SharedPlanConflictNotificationPayload.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .operation(let payload): try container.encode(payload)
        case .conflict(let payload): try container.encode(payload)
        }
    }
}

struct SharedPlanNotificationItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: SharedPlanNotificationKind
    let planID: String
    let eventType: String
    let i18nKey: String
    let payloadVersion: Int
    let payload: SharedPlanNotificationPayload
    let createdAt: Date
    var readAt: Date?
}

struct SharedPlanNotificationPage: Equatable, Sendable {
    let items: [SharedPlanNotificationItem]
    let nextCursor: String?
}

struct SharedPlanNotificationReadReceipt: Equatable, Sendable {
    let id: String
    let readAt: Date
}

struct SharedPlanMutationResult: Equatable, Sendable {
    let plan: SharedPlan
    let receipt: SharedPlanMutationReceipt
    let syncBootstrap: SharedPlanSyncBootstrap?

    init(
        plan: SharedPlan,
        receipt: SharedPlanMutationReceipt,
        syncBootstrap: SharedPlanSyncBootstrap? = nil
    ) {
        self.plan = plan
        self.receipt = receipt
        self.syncBootstrap = syncBootstrap
    }
}

enum SharedPlanErrorHandling {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}

protocol SharedPlanRemoteServicing: Sendable {
    func fetchPlans() async throws -> [SharedPlan]
    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap
    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult
    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult
    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview
    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult
    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage
    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func fetchInvitations(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanInvitationPage
    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation
    func revokeInvitation(
        planID: String,
        invitationID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult
    func fetchNotifications(
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanNotificationPage
    func markNotificationRead(id: String) async throws -> SharedPlanNotificationReadReceipt
}

extension SharedPlanRemoteServicing {
    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage {
        throw URLError(.notConnectedToInternet)
    }

    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }

    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }

    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }

    func fetchInvitations(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanInvitationPage {
        throw URLError(.notConnectedToInternet)
    }

    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation {
        throw URLError(.notConnectedToInternet)
    }

    func revokeInvitation(
        planID: String,
        invitationID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }

    func fetchNotifications(
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanNotificationPage {
        throw URLError(.notConnectedToInternet)
    }

    func markNotificationRead(id: String) async throws -> SharedPlanNotificationReadReceipt {
        throw URLError(.notConnectedToInternet)
    }
}

struct OfflineSharedPlanRemoteService: SharedPlanRemoteServicing {
    func fetchPlans() async throws -> [SharedPlan] { throw URLError(.notConnectedToInternet) }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        throw URLError(.notConnectedToInternet)
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
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
        throw URLError(.notConnectedToInternet)
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        throw URLError(.notConnectedToInternet)
    }
}
