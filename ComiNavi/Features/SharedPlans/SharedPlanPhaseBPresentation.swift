import Foundation
import Observation

struct SharedPlanEditorSnapshot: Equatable, Sendable {
    let plan: SharedPlan
    let replicaID: UUID?
    let circles: [SharedPlanCircleContent]
    let conflicts: [SharedPlanDocumentConflict]
    let members: [SharedPlanMember]
    let memoDrafts: [SharedPlanMemoDraft]
    let syncStatus: SharedPlanSyncConnectionStatus
    let pendingOperationCount: Int
    let localEditLimit: SharedPlanLocalEditLimit?
    let syncIssue: SharedPlanSyncIssue?
    let recoveryDocument: SharedPlanRecoveryDocument?
    let recoveryRebaseAvailable: Bool
    let permitsContentMutations: Bool

    init(
        plan: SharedPlan,
        replicaID: UUID? = nil,
        circles: [SharedPlanCircleContent],
        conflicts: [SharedPlanDocumentConflict],
        members: [SharedPlanMember] = [],
        memoDrafts: [SharedPlanMemoDraft] = [],
        syncStatus: SharedPlanSyncConnectionStatus,
        pendingOperationCount: Int,
        localEditLimit: SharedPlanLocalEditLimit?,
        syncIssue: SharedPlanSyncIssue?,
        recoveryDocument: SharedPlanRecoveryDocument?,
        recoveryRebaseAvailable: Bool,
        permitsContentMutations: Bool
    ) {
        self.plan = plan
        self.replicaID = replicaID
        self.circles = circles
        self.conflicts = conflicts
        self.members = members
        self.memoDrafts = memoDrafts
        self.syncStatus = syncStatus
        self.pendingOperationCount = pendingOperationCount
        self.localEditLimit = localEditLimit
        self.syncIssue = syncIssue
        self.recoveryDocument = recoveryDocument
        self.recoveryRebaseAvailable = recoveryRebaseAvailable
        self.permitsContentMutations = permitsContentMutations
    }
}

struct SharedPlanEditorProjection: Equatable, Sendable {
    let generation: UInt64
    let snapshot: SharedPlanEditorSnapshot
}

enum SharedPlanMemoDraftReason: String, Codable, Equatable, Sendable {
    case staged
    case authorityLost
    case circleUnavailable
    case mutationFailed
}

struct SharedPlanMemoDraft: Codable, Equatable, Identifiable, Sendable {
    let planID: String
    let replicaID: UUID
    let circle: SharedPlanCircleKey
    let text: String
    let generation: UInt64
    let reason: SharedPlanMemoDraftReason
    let updatedAt: Date
    let recoveryMessage: String?

    var id: String {
        "\(planID):\(replicaID.uuidString.lowercased()):\(circle.id)"
    }

    func requiringRecovery(
        _ reason: SharedPlanMemoDraftReason,
        message: String,
        updatedAt: Date = Date()
    ) -> SharedPlanMemoDraft {
        SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: circle,
            text: text,
            generation: generation,
            reason: reason,
            updatedAt: updatedAt,
            recoveryMessage: message
        )
    }
}

struct SharedPlanMemoDraftRecovery: Equatable, Identifiable, Sendable {
    let planID: String
    let circle: SharedPlanCircleKey
    let text: String
    let generation: UInt64
    let reason: String
    let exportText: String

    var id: String { "\(planID):\(circle.id):\(generation)" }
}

enum SharedPlanEditorReadOnlyReason: Equatable, Sendable {
    case featureDisabled
    case archived
    case insufficientRole
    case waitingForWritableSync
    case localLimit(SharedPlanLocalEditLimit)
    case quarantine(SharedPlanSyncIssue)
}

enum SharedPlanMemberOutcome: String, CaseIterable, Identifiable, Sendable {
    case unavailable
    case skipped
    case deferred

    static let communicationField = "memberOutcome"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unavailable: String(localized: "Unavailable")
        case .skipped: String(localized: "Skipped")
        case .deferred: String(localized: "Deferred")
        }
    }

    static func value(in content: SharedPlanCircleContent) -> Self? {
        guard case .string(let value) = content.communicationState[communicationField] else {
            return nil
        }
        return Self(rawValue: value)
    }
}

struct SharedPlanProgressSummary: Equatable, Sendable {
    let wanted: Int
    let assigned: Int
    let covered: Int
    let fulfilled: Int
    let outstanding: Int
    let overAssigned: Int
    let conflicted: Int
    let terminalOutcomeCircles: Int

    init(circles: [SharedPlanCircleContent], conflictCount: Int) {
        let active = circles.filter { $0.presence != .removed }
        wanted = active.flatMap(\.needs).reduce(0) { $0 + $1.wantedQuantity }
        assigned = active.flatMap(\.needs).reduce(0) {
            $0 + $1.buyerAllocations.values.reduce(0, +)
        }
        covered = active.flatMap(\.needs).reduce(0) {
            $0 + min($1.wantedQuantity, $1.buyerAllocations.values.reduce(0, +))
        }
        fulfilled = active.flatMap(\.needs).reduce(0) {
            $0 + min($1.wantedQuantity, $1.fulfilledQuantity)
        }
        outstanding = active.flatMap(\.needs).reduce(0) {
            $0 + max(0, $1.wantedQuantity - $1.fulfilledQuantity)
        }
        overAssigned = active.flatMap(\.needs).reduce(0) {
            $0 + max(0, $1.buyerAllocations.values.reduce(0, +) - $1.wantedQuantity)
        }
        conflicted = conflictCount
        terminalOutcomeCircles = active.filter {
            SharedPlanMemberOutcome.value(in: $0) != nil
        }.count
    }
}

enum SharedPlanParentTarget: Equatable, Sendable {
    case circle(SharedPlanCircleKey)
    case need(SharedPlanCircleKey, UUID)
}

struct SharedPlanParentResolutionDraft: Equatable, Identifiable, Sendable {
    let conflictID: String
    let target: SharedPlanParentTarget
    let inventory: SharedPlanParentResolutionInventory
    var state: SharedPlanPresenceState?
    var selectedChangeHashes: [String: String]

    var id: String {
        "\(conflictID):\(inventory.selectedParentOperationID.uuidString.lowercased())"
    }

    var isComplete: Bool {
        state != nil && inventory.requiredNestedConflicts.allSatisfy { conflict in
            guard let selectedHash = selectedChangeHashes[conflict.id] else {
                return false
            }
            return conflict.candidates.contains { $0.changeHash == selectedHash }
        }
    }

    func selectedCandidate(
        for conflict: SharedPlanDocumentConflict
    ) -> SharedPlanConflictCandidate? {
        guard let selectedHash = selectedChangeHashes[conflict.id] else { return nil }
        return conflict.candidates.first { $0.changeHash == selectedHash }
    }
}

@MainActor
protocol SharedPlanEditorServicing: AnyObject {
    func load() async
    func editorSnapshot(planID: String) async throws -> SharedPlanEditorSnapshot
    func editorProjection(planID: String) async throws -> SharedPlanEditorProjection
    func editorProjectionUpdates(planID: String) -> AsyncStream<UInt64>
    func refreshAllAllocationMembers(planID: String) async throws
    func startSync(planID: String) async
    func stopSync(planID: String) async

    func persistMemoDraft(_ draft: SharedPlanMemoDraft) async throws
    func commitMemoDraft(_ draft: SharedPlanMemoDraft, now: Date) async throws -> Bool

    func addCircle(
        _ key: SharedPlanCircleKey,
        to planID: String,
        now: Date
    ) async throws -> Bool
    func removeCircle(
        _ key: SharedPlanCircleKey,
        from planID: String,
        now: Date
    ) async throws -> Bool
    func updateMemo(
        _ memo: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func createPurchaseNeed(
        _ need: SharedPlanPurchaseNeed,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func deletePurchaseNeed(
        _ needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func setWantedQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func setBuyerAllocation(
        _ quantity: Int,
        buyerUserID: String,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func setFulfilledQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func setCommunication(
        _ value: SharedPlanJSONValue,
        field: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date
    ) async throws -> Bool
    func resolveDocumentConflict(
        planID: String,
        conflictID: String,
        selectedChangeHash: String,
        now: Date
    ) async throws -> Bool
    func circleParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory
    func needParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory
    func resolveCircleParent(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date
    ) async throws -> Bool
    func resolveNeedParent(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date
    ) async throws -> Bool
    func discardUnsyncedContentAndRebootstrap(planID: String) async throws
    func rebaseUnsyncedContent(planID: String, now: Date) async throws
}

extension SharedPlanEditorServicing {
    func editorProjection(planID: String) async throws -> SharedPlanEditorProjection {
        SharedPlanEditorProjection(
            generation: 0,
            snapshot: try await editorSnapshot(planID: planID)
        )
    }

    func editorProjectionUpdates(planID: String) -> AsyncStream<UInt64> {
        AsyncStream { continuation in
            continuation.yield(0)
            continuation.finish()
        }
    }

    func refreshAllAllocationMembers(planID: String) async throws {}

    func persistMemoDraft(_ draft: SharedPlanMemoDraft) async throws {}

    func commitMemoDraft(_ draft: SharedPlanMemoDraft, now: Date) async throws -> Bool {
        try await updateMemo(
            draft.text,
            circle: draft.circle,
            planID: draft.planID,
            now: now
        )
    }
}

extension SharedPlanStore: SharedPlanEditorServicing {}

@MainActor
@Observable
final class SharedPlanEditorModel {
    let planID: String
    let features: SharedPlanPresentationFeatures

    private(set) var plan: SharedPlan?
    private(set) var replicaID: UUID?
    private(set) var circles: [SharedPlanCircleContent] = []
    private(set) var conflicts: [SharedPlanDocumentConflict] = []
    private(set) var members: [SharedPlanMember] = []
    private(set) var syncStatus: SharedPlanSyncConnectionStatus = .idle
    private(set) var pendingOperationCount = 0
    private(set) var localEditLimit: SharedPlanLocalEditLimit?
    private(set) var syncIssue: SharedPlanSyncIssue?
    private(set) var recoveryDocument: SharedPlanRecoveryDocument?
    private(set) var recoveryRebaseAvailable = false
    private(set) var readOnlyReason: SharedPlanEditorReadOnlyReason?
    private(set) var memoDrafts: [String: SharedPlanMemoDraft] = [:]
    private(set) var parentResolutionDraft: SharedPlanParentResolutionDraft?
    private(set) var isLoading = false
    private(set) var isStartingSync = false
    private(set) var isPerformingMutation = false
    private(set) var issueMessage: String?
    private(set) var appliedProjectionGeneration: UInt64?
    private(set) var persistedMemoDraftGenerations: [String: UInt64] = [:]

    @ObservationIgnored private let memoDebounce: Duration
    @ObservationIgnored private let memoRetryDelay: Duration
    @ObservationIgnored private var memoTasks: [String: MemoTask] = [:]
    @ObservationIgnored private var memoPersistenceTasks: [String: MemoPersistenceTask] = [:]
    @ObservationIgnored private var nextMemoGeneration: UInt64 = 0
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var reloadRequestID: UInt64 = 0
    @ObservationIgnored private var parentResolutionRequest: ParentResolutionRequest?

    private struct MemoTask {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct MemoPersistenceTask {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct ParentResolutionRequest: Equatable {
        let id: UUID
        let conflictID: String
        let parentID: UUID
    }

    init(
        planID: String,
        features: SharedPlanPresentationFeatures = .production,
        memoDebounce: Duration = .seconds(4),
        memoRetryDelay: Duration = .seconds(2)
    ) {
        self.planID = planID
        self.features = features
        self.memoDebounce = memoDebounce
        self.memoRetryDelay = memoRetryDelay
    }

    var canEdit: Bool { readOnlyReason == nil }

    var activeMembers: [SharedPlanMember] {
        members.filter { $0.membershipStatus == .active }
    }

    var activeMembersByUserID: [String: SharedPlanMember] {
        Dictionary(uniqueKeysWithValues: activeMembers.map { ($0.userID, $0) })
    }

    var hasUnsavedMemoDrafts: Bool {
        !memoDrafts.isEmpty
    }

    var progress: SharedPlanProgressSummary {
        SharedPlanProgressSummary(circles: circles, conflictCount: conflicts.count)
    }

    func memberOutcome(for key: SharedPlanCircleKey) -> SharedPlanMemberOutcome? {
        circleContent(for: key).flatMap(SharedPlanMemberOutcome.value(in:))
    }

    func setMemberOutcome(
        _ outcome: SharedPlanMemberOutcome?,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await setCommunication(
            outcome.map { .string($0.rawValue) } ?? .null,
            field: SharedPlanMemberOutcome.communicationField,
            circle: circle,
            using: service,
            now: now
        )
    }

    var memoDraftRecoveries: [SharedPlanMemoDraftRecovery] {
        memoDrafts.values.compactMap { draft in
            guard persistedMemoDraftGenerations[draft.id] == draft.generation else {
                return nil
            }
            let reason = draft.recoveryMessage
                ?? (draft.replicaID != replicaID
                    || readOnlyReason != nil
                    || circleContent(for: draft.circle) == nil
                    ? String(localized: "未保存のメモを同期できないため、端末に保持しています。")
                    : nil)
            guard let reason,
                  let exportText = Self.memoDraftExport(
                      planID: planID,
                      draft: draft,
                      reason: reason
                  )
            else { return nil }
            return SharedPlanMemoDraftRecovery(
                planID: planID,
                circle: draft.circle,
                text: draft.text,
                generation: draft.generation,
                reason: reason,
                exportText: exportText
            )
        }.sorted { $0.id < $1.id }
    }

    func circleContent(for key: SharedPlanCircleKey) -> SharedPlanCircleContent? {
        circles.first { $0.key == key }
    }

    func memoText(for key: SharedPlanCircleKey) -> String {
        currentMemoDraft(for: key)?.text ?? circleContent(for: key)?.memo ?? ""
    }

    func hasMemoDraft(for key: SharedPlanCircleKey) -> Bool {
        currentMemoDraft(for: key) != nil
    }

    func isMemoDraftDurablyRetained(for key: SharedPlanCircleKey) -> Bool {
        guard let draft = currentMemoDraft(for: key) else { return false }
        return persistedMemoDraftGenerations[draft.id] == draft.generation
    }

    func member(userID: String) -> SharedPlanMember? {
        members.first { $0.userID == userID }
    }

    func load(using service: any SharedPlanEditorServicing) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await service.load()
        await reload(using: service)
        guard plan != nil else { return }
        if features.writesEnabled, isEligibleForLiveSync {
            do {
                try await service.refreshAllAllocationMembers(planID: planID)
                await reload(using: service)
            } catch {
                issueMessage = error.localizedDescription
            }
        }
        scheduleHydratedMemoDrafts(using: service)
        if isEligibleForLiveSync {
            await startSync(using: service)
        }
    }

    /// Owns the editor's structured observation lifetime. SwiftUI cancellation
    /// ends the stream, flushes retained drafts, and closes sync before this
    /// method returns; no polling or detached post-navigation observer remains.
    func run(using service: any SharedPlanEditorServicing) async {
        let updates = service.editorProjectionUpdates(planID: planID)
        await load(using: service)
        for await minimumGeneration in updates {
            guard !Task.isCancelled else { break }
            await reload(
                using: service,
                minimumGeneration: minimumGeneration
            )
        }
        await stop(using: service)
    }

    func reload(using service: any SharedPlanEditorServicing) async {
        await reload(using: service, minimumGeneration: nil)
    }

    private func reload(
        using service: any SharedPlanEditorServicing,
        minimumGeneration: UInt64?
    ) async {
        reloadRequestID &+= 1
        let requestID = reloadRequestID
        do {
            let projection = try await service.editorProjection(planID: planID)
            guard !Task.isCancelled,
                  minimumGeneration.map({ projection.generation >= $0 }) ?? true,
                  appliedProjectionGeneration.map({ projection.generation >= $0 }) ?? true,
                  requestID == reloadRequestID
                    || projection.generation > (appliedProjectionGeneration ?? 0)
            else { return }
            apply(projection.snapshot)
            appliedProjectionGeneration = projection.generation
            issueMessage = nil
        } catch {
            guard requestID == reloadRequestID else { return }
            issueMessage = error.localizedDescription
        }
    }

    func startSync(using service: any SharedPlanEditorServicing) async {
        guard !isStartingSync, isEligibleForLiveSync else { return }
        isStartingSync = true
        await service.startSync(planID: planID)
        await reload(using: service)
        isStartingSync = false
    }

    func retrySync(using service: any SharedPlanEditorServicing) async {
        await service.stopSync(planID: planID)
        await startSync(using: service)
    }

    func stop(using service: any SharedPlanEditorServicing, now: Date = Date()) async {
        cancelParentResolution()
        await awaitMemoPersistenceTasks()
        await flushAllMemos(using: service, now: now)
        for task in memoTasks.values { task.task.cancel() }
        memoTasks.removeAll()
        await service.stopSync(planID: planID)
    }

    func setCirclePresence(
        _ state: SharedPlanPresenceState,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            switch state {
            case .active:
                try await service.addCircle(circle, to: self.planID, now: now)
            case .removed:
                try await service.removeCircle(circle, from: self.planID, now: now)
            }
        }
    }

    func stageMemo(
        _ value: String,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) {
        guard canEdit, let replicaID else {
            issueMessage = String(localized: "このプランは現在読み取り専用です。")
            return
        }
        nextMemoGeneration &+= 1
        let draft = SharedPlanMemoDraft(
            planID: planID,
            replicaID: replicaID,
            circle: circle,
            text: value,
            generation: nextMemoGeneration,
            reason: .staged,
            updatedAt: now,
            recoveryMessage: nil
        )
        memoDrafts[draft.id] = draft
        persistedMemoDraftGenerations[draft.id] = nil
        cancelScheduledMemoFlush(draftID: draft.id)
        memoPersistenceTasks[draft.id]?.task.cancel()
        let persistenceTask = Task { [weak self, weak service] in
            guard let self, let service else { return }
            do {
                try await service.persistMemoDraft(draft)
                guard !Task.isCancelled,
                      self.memoDrafts[draft.id]?.generation == draft.generation
                else { return }
                self.persistedMemoDraftGenerations[draft.id] = draft.generation
                self.scheduleMemoFlush(draft, using: service, after: self.memoDebounce)
            } catch {
                guard self.memoDrafts[draft.id]?.generation == draft.generation else { return }
                self.memoDrafts[draft.id] = draft.requiringRecovery(
                    .mutationFailed,
                    message: error.localizedDescription
                )
                self.issueMessage = error.localizedDescription
            }
            if self.memoPersistenceTasks[draft.id]?.generation == draft.generation {
                self.memoPersistenceTasks[draft.id] = nil
            }
        }
        memoPersistenceTasks[draft.id] = MemoPersistenceTask(
            generation: draft.generation,
            task: persistenceTask
        )
    }

    func flushMemo(
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        guard let draft = currentMemoDraft(for: circle) else { return }
        cancelScheduledMemoFlush(draftID: draft.id)
        await awaitMemoPersistenceTask(draftID: draft.id)
        await flushMemoDraft(
            draftID: draft.id,
            expectedGeneration: nil,
            using: service,
            now: now
        )
    }

    func flushAllMemos(
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await awaitMemoPersistenceTasks()
        let drafts = memoDrafts.values
            .filter { $0.replicaID == replicaID }
            .sorted { $0.id < $1.id }
        for draft in drafts {
            await flushMemo(circle: draft.circle, using: service, now: now)
        }
    }

    func createNeed(
        requesterUserID: String,
        itemName: String = "Purchase item",
        unitPrice: Int? = nil,
        wantedQuantity: Int,
        circle: SharedPlanCircleKey,
        id: UUID = UUID(),
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        let need = SharedPlanPurchaseNeed(
            id: id,
            requesterUserID: requesterUserID,
            itemName: itemName.trimmingCharacters(in: .whitespacesAndNewlines),
            unitPrice: unitPrice,
            wantedQuantity: wantedQuantity
        )
        guard !need.itemName.isEmpty else {
            issueMessage = String(localized: "Enter what should be purchased.")
            return
        }
        await performMutation(using: service) {
            try await service.createPurchaseNeed(
                need,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func deleteNeed(
        _ needID: UUID,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.deletePurchaseNeed(
                needID,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func setWantedQuantity(
        _ quantity: Int,
        needID: UUID,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.setWantedQuantity(
                quantity,
                needID: needID,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func setPurchaseProgress(
        requestedQuantity: Int,
        boughtQuantity: Int,
        needID: UUID,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        guard let need = circleContent(for: circle)?.needs.first(where: { $0.id == needID })
        else {
            issueMessage = SharedPlanError.planNotFound.localizedDescription
            return
        }
        let requestedChanged = requestedQuantity != need.wantedQuantity
        let boughtChanged = boughtQuantity != need.fulfilledQuantity
        guard requestedChanged || boughtChanged else { return }

        await performMutation(using: service) {
            var changed = false

            if boughtChanged, boughtQuantity < need.fulfilledQuantity {
                changed = try await service.setFulfilledQuantity(
                    boughtQuantity,
                    needID: needID,
                    circle: circle,
                    planID: self.planID,
                    now: now
                ) || changed
            }

            if requestedChanged {
                changed = try await service.setWantedQuantity(
                    requestedQuantity,
                    needID: needID,
                    circle: circle,
                    planID: self.planID,
                    now: now
                ) || changed
            }

            if boughtChanged, boughtQuantity >= need.fulfilledQuantity {
                changed = try await service.setFulfilledQuantity(
                    boughtQuantity,
                    needID: needID,
                    circle: circle,
                    planID: self.planID,
                    now: now
                ) || changed
            }

            return changed
        }
    }

    func setBuyerAllocation(
        _ quantity: Int,
        buyerUserID: String,
        needID: UUID,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.setBuyerAllocation(
                quantity,
                buyerUserID: buyerUserID,
                needID: needID,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func setFulfilledQuantity(
        _ quantity: Int,
        needID: UUID,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.setFulfilledQuantity(
                quantity,
                needID: needID,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func setCommunication(
        _ value: SharedPlanJSONValue,
        field: String,
        circle: SharedPlanCircleKey,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.setCommunication(
                value,
                field: field,
                circle: circle,
                planID: self.planID,
                now: now
            )
        }
    }

    func resolveConflict(
        conflictID: String,
        selectedChangeHash: String,
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        await performMutation(using: service) {
            try await service.resolveDocumentConflict(
                planID: self.planID,
                conflictID: conflictID,
                selectedChangeHash: selectedChangeHash,
                now: now
            )
        }
    }

    func prepareParentResolution(
        conflictID: String,
        selectedParentOperationID: UUID,
        using service: any SharedPlanEditorServicing
    ) async {
        guard let conflict = conflicts.first(where: { $0.id == conflictID }),
              conflict.kind == .parent
        else {
            issueMessage = SharedPlanError.syncProtocolViolation.localizedDescription
            return
        }
        let request = ParentResolutionRequest(
            id: UUID(),
            conflictID: conflictID,
            parentID: selectedParentOperationID
        )
        parentResolutionRequest = request
        parentResolutionDraft = nil
        do {
            let target = try Self.parentTarget(for: conflict, comiketNo: plan?.comiketNo)
            let inventory: SharedPlanParentResolutionInventory
            switch target {
            case .circle(let circle):
                inventory = try await service.circleParentResolutionInventory(
                    planID: planID,
                    circle: circle,
                    selectedParentOperationID: selectedParentOperationID
                )
            case .need(let circle, let needID):
                inventory = try await service.needParentResolutionInventory(
                    planID: planID,
                    circle: circle,
                    needID: needID,
                    selectedParentOperationID: selectedParentOperationID
                )
            }
            guard inventory.parentConflict.id == conflictID else {
                throw SharedPlanError.syncProtocolViolation
            }
            guard !Task.isCancelled, parentResolutionRequest == request else { return }
            parentResolutionDraft = SharedPlanParentResolutionDraft(
                conflictID: conflictID,
                target: target,
                inventory: inventory,
                state: nil,
                selectedChangeHashes: [:]
            )
            parentResolutionRequest = nil
            issueMessage = nil
        } catch {
            guard parentResolutionRequest == request else { return }
            parentResolutionRequest = nil
            issueMessage = error.localizedDescription
        }
    }

    func selectParentPresence(_ state: SharedPlanPresenceState) {
        guard var draft = parentResolutionDraft else { return }
        draft.state = state
        parentResolutionDraft = draft
    }

    func selectNestedCandidate(conflictID: String, changeHash: String) {
        guard var draft = parentResolutionDraft,
              let conflict = draft.inventory.requiredNestedConflicts.first(where: {
                  $0.id == conflictID
              }),
              conflict.candidates.contains(where: { $0.changeHash == changeHash })
        else {
            issueMessage = SharedPlanError.syncProtocolViolation.localizedDescription
            return
        }
        draft.selectedChangeHashes[conflictID] = changeHash
        parentResolutionDraft = draft
        issueMessage = nil
    }

    func cancelParentResolution() {
        parentResolutionRequest = nil
        parentResolutionDraft = nil
    }

    func cancelParentResolutionRequest(conflictID: String, parentID: UUID) {
        if parentResolutionRequest?.conflictID == conflictID,
           parentResolutionRequest?.parentID == parentID
        {
            parentResolutionRequest = nil
        }
        if parentResolutionDraft?.conflictID == conflictID,
           parentResolutionDraft?.inventory.selectedParentOperationID == parentID
        {
            parentResolutionDraft = nil
        }
    }

    func submitParentResolution(
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        guard let draft = parentResolutionDraft,
              let state = draft.state,
              draft.isComplete
        else {
            issueMessage = String(localized: "すべての競合に対する選択が必要です。")
            return
        }
        do {
            let nested = try draft.inventory.requiredNestedConflicts.map { conflict in
                guard let candidate = draft.selectedCandidate(for: conflict) else {
                    throw SharedPlanError.syncProtocolViolation
                }
                return SharedPlanNestedConflictResolution(
                    conflictID: conflict.id,
                    path: conflict.path,
                    selectedChangeHash: candidate.changeHash,
                    value: candidate.value
                )
            }
            await performMutation(using: service) {
                switch draft.target {
                case .circle(let circle):
                    try await service.resolveCircleParent(
                        planID: self.planID,
                        circle: circle,
                        selectedParentOperationID: draft.inventory.selectedParentOperationID,
                        state: state,
                        nestedResolutions: nested,
                        now: now
                    )
                case .need(let circle, let needID):
                    try await service.resolveNeedParent(
                        planID: self.planID,
                        circle: circle,
                        needID: needID,
                        selectedParentOperationID: draft.inventory.selectedParentOperationID,
                        state: state,
                        nestedResolutions: nested,
                        now: now
                    )
                }
            }
            if !conflicts.contains(where: { $0.id == draft.conflictID }) {
                parentResolutionDraft = nil
            }
        } catch {
            issueMessage = error.localizedDescription
        }
    }

    func discardAndRebootstrap(using service: any SharedPlanEditorServicing) async {
        guard recoveryDocument != nil else {
            issueMessage = SharedPlanError.syncProtocolViolation.localizedDescription
            return
        }
        await performRecovery(using: service) {
            try await service.discardUnsyncedContentAndRebootstrap(planID: self.planID)
        }
    }

    func rebaseUnsyncedContent(
        using service: any SharedPlanEditorServicing,
        now: Date = Date()
    ) async {
        guard recoveryDocument != nil, recoveryRebaseAvailable else {
            issueMessage = SharedPlanError.syncProtocolViolation.localizedDescription
            return
        }
        await performRecovery(using: service) {
            try await service.rebaseUnsyncedContent(planID: self.planID, now: now)
        }
    }

    func dismissIssue() {
        issueMessage = nil
    }

    func reportStaleAllocationMember() {
        issueMessage = String(localized: "This member is no longer active. Reload the plan before assigning a quantity.")
    }

    private func performMutation(
        using service: any SharedPlanEditorServicing,
        operation: () async throws -> Bool
    ) async {
        guard canEdit else {
            issueMessage = String(localized: "このプランは現在読み取り専用です。")
            return
        }
        await acquireMutationOperation()
        defer { releaseMutationOperation() }
        guard canEdit else {
            issueMessage = String(localized: "このプランは現在読み取り専用です。")
            return
        }
        do {
            _ = try await operation()
            await reload(using: service)
        } catch {
            issueMessage = error.localizedDescription
            await reloadPreservingIssue(using: service)
        }
    }

    private func performRecovery(
        using service: any SharedPlanEditorServicing,
        operation: () async throws -> Void
    ) async {
        await acquireMutationOperation()
        defer { releaseMutationOperation() }
        do {
            try await operation()
            await reload(using: service)
        } catch {
            issueMessage = error.localizedDescription
            await reloadPreservingIssue(using: service)
        }
    }

    private func reloadPreservingIssue(using service: any SharedPlanEditorServicing) async {
        let mutationIssue = issueMessage
        await reload(using: service)
        if plan == nil {
            readOnlyReason = .waitingForWritableSync
        }
        if let mutationIssue { issueMessage = mutationIssue }
    }

    private func apply(_ snapshot: SharedPlanEditorSnapshot) {
        plan = snapshot.plan
        replicaID = snapshot.replicaID
        circles = snapshot.circles
        conflicts = snapshot.conflicts
        members = snapshot.members
        syncStatus = snapshot.syncStatus
        pendingOperationCount = snapshot.pendingOperationCount
        localEditLimit = snapshot.localEditLimit
        syncIssue = snapshot.syncIssue
        recoveryDocument = snapshot.recoveryDocument
        recoveryRebaseAvailable = snapshot.recoveryRebaseAvailable
        let persistedDrafts = Dictionary(
            snapshot.memoDrafts.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        persistedMemoDraftGenerations = Dictionary(
            uniqueKeysWithValues: snapshot.memoDrafts.map { ($0.id, $0.generation) }
        )
        let pendingLocalDrafts = memoDrafts.filter {
            memoPersistenceTasks[$0.key] != nil
        }
        memoDrafts = persistedDrafts.merging(pendingLocalDrafts) { persisted, local in
            local.generation > persisted.generation ? local : persisted
        }
        nextMemoGeneration = max(
            nextMemoGeneration,
            memoDrafts.values.map(\.generation).max() ?? 0
        )
        readOnlyReason = Self.readOnlyReason(
            snapshot: snapshot,
            features: features
        )
    }

    private func flushMemoDraft(
        draftID: String,
        expectedGeneration: UInt64?,
        using service: any SharedPlanEditorServicing,
        now: Date
    ) async {
        guard let initialDraft = memoDrafts[draftID],
              expectedGeneration == nil || initialDraft.generation == expectedGeneration
        else { return }

        await acquireMutationOperation()
        defer { releaseMutationOperation() }

        guard !Task.isCancelled || expectedGeneration == nil,
              let draft = memoDrafts[draftID],
              expectedGeneration == nil || draft.generation == expectedGeneration
        else { return }
        guard draft.replicaID == replicaID,
              circleContent(for: draft.circle) != nil
        else {
            await preserveMemoDraftForRecovery(
                draft,
                reason: draft.replicaID == replicaID ? .circleUnavailable : .authorityLost,
                message: String(localized: "編集権限が変わったため、未保存のメモを端末に保持しています。"),
                using: service
            )
            return
        }
        guard canEdit else {
            await preserveMemoDraftForRecovery(
                draft,
                reason: .authorityLost,
                message: String(localized: "編集権限がないため、未保存のメモを端末に保持しています。"),
                using: service
            )
            return
        }

        do {
            _ = try await service.commitMemoDraft(draft, now: now)
            if memoDrafts[draftID]?.generation == draft.generation {
                memoDrafts[draftID] = nil
                persistedMemoDraftGenerations[draftID] = nil
            }
            await reload(using: service)
        } catch {
            let failure = error.localizedDescription
            if memoDrafts[draftID]?.generation == draft.generation {
                await preserveMemoDraftForRecovery(
                    draft,
                    reason: .mutationFailed,
                    message: failure,
                    using: service
                )
            }
            issueMessage = failure
            await reloadPreservingIssue(using: service)
            if canEdit, let retained = memoDrafts[draftID],
               retained.generation == draft.generation
            {
                scheduleMemoFlush(retained, using: service, after: memoRetryDelay)
            }
        }
    }

    private func scheduleMemoFlush(
        _ draft: SharedPlanMemoDraft,
        using service: any SharedPlanEditorServicing,
        after delay: Duration
    ) {
        cancelScheduledMemoFlush(draftID: draft.id)
        let taskID = UUID()
        let task = Task { [weak self, weak service] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let service else { return }
                await self.flushMemoDraft(
                    draftID: draft.id,
                    expectedGeneration: draft.generation,
                    using: service,
                    now: Date()
                )
                self.clearScheduledMemoFlush(
                    draftID: draft.id,
                    taskID: taskID
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        memoTasks[draft.id] = MemoTask(
            id: taskID,
            generation: draft.generation,
            task: task
        )
    }

    private func cancelScheduledMemoFlush(draftID: String) {
        memoTasks[draftID]?.task.cancel()
        memoTasks[draftID] = nil
    }

    private func clearScheduledMemoFlush(draftID: String, taskID: UUID) {
        guard memoTasks[draftID]?.id == taskID else { return }
        memoTasks[draftID] = nil
    }

    private func preserveMemoDraftForRecovery(
        _ draft: SharedPlanMemoDraft,
        reason: SharedPlanMemoDraftReason,
        message: String,
        using service: any SharedPlanEditorServicing
    ) async {
        guard memoDrafts[draft.id]?.generation == draft.generation else { return }
        let retained = draft.requiringRecovery(reason, message: message)
        do {
            try await service.persistMemoDraft(retained)
            guard memoDrafts[draft.id]?.generation == draft.generation else { return }
            memoDrafts[draft.id] = retained
            persistedMemoDraftGenerations[draft.id] = retained.generation
        } catch {
            issueMessage = error.localizedDescription
            memoDrafts[draft.id] = retained
        }
    }

    private func currentMemoDraft(
        for circle: SharedPlanCircleKey
    ) -> SharedPlanMemoDraft? {
        memoDrafts.values
            .filter { $0.circle == circle && $0.replicaID == replicaID }
            .max { $0.generation < $1.generation }
    }

    private func awaitMemoPersistenceTask(draftID: String) async {
        guard let persistenceTask = memoPersistenceTasks[draftID] else { return }
        await persistenceTask.task.value
    }

    private func awaitMemoPersistenceTasks() async {
        let tasks = memoPersistenceTasks.values.map(\.task)
        for task in tasks { await task.value }
    }

    private func scheduleHydratedMemoDrafts(
        using service: any SharedPlanEditorServicing
    ) {
        guard canEdit, let replicaID else { return }
        for draft in memoDrafts.values where draft.replicaID == replicaID {
            scheduleMemoFlush(draft, using: service, after: memoDebounce)
        }
    }

    private func acquireMutationOperation() async {
        if !isPerformingMutation {
            isPerformingMutation = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationOperation() {
        guard !mutationWaiters.isEmpty else {
            isPerformingMutation = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private struct MemoDraftExport: Encodable {
        let v = 1
        let planID: String
        let comiketNo: Int
        let wcID: Int
        let text: String
        let generation: UInt64
        let reason: String
    }

    private static func memoDraftExport(
        planID: String,
        draft: SharedPlanMemoDraft,
        reason: String
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(MemoDraftExport(
            planID: planID,
            comiketNo: draft.circle.comiketNo,
            wcID: draft.circle.wcID,
            text: draft.text,
            generation: draft.generation,
            reason: reason
        )) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readOnlyReason(
        snapshot: SharedPlanEditorSnapshot,
        features: SharedPlanPresentationFeatures
    ) -> SharedPlanEditorReadOnlyReason? {
        guard snapshot.plan.lifecycle == .active else { return .archived }
        guard [.owner, .editor].contains(snapshot.plan.role) else {
            return .insufficientRole
        }
        if let issue = snapshot.syncIssue { return .quarantine(issue) }
        if let limit = snapshot.localEditLimit { return .localLimit(limit) }
        guard snapshot.permitsContentMutations else { return .waitingForWritableSync }
        guard features.writesEnabled else { return .featureDisabled }
        return nil
    }

    private var isEligibleForLiveSync: Bool {
        guard let plan,
              plan.lifecycle == .active,
              [.owner, .editor].contains(plan.role),
              syncIssue == nil
        else { return false }
        return true
    }

    private static func parentTarget(
        for conflict: SharedPlanDocumentConflict,
        comiketNo: Int?
    ) throws -> SharedPlanParentTarget {
        guard let comiketNo,
              conflict.path.first == "circles",
              conflict.path.count == 2 || conflict.path.count == 4,
              let wcID = Int(conflict.path[1]),
              let circle = SharedPlanCircleKey(comiketNo: comiketNo, wcID: wcID)
        else { throw SharedPlanError.syncProtocolViolation }
        if conflict.path.count == 2 { return .circle(circle) }
        guard conflict.path[2] == "needs",
              let needID = UUID(uuidString: conflict.path[3]),
              conflict.path[3] == needID.uuidString.lowercased()
        else { throw SharedPlanError.syncProtocolViolation }
        return .need(circle, needID)
    }
}
