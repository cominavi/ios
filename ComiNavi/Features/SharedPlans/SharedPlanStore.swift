import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class SharedPlanStore {
    private(set) var plans: [SharedPlan] = [] {
        didSet { publishEditorProjectionChanges(for: Set(oldValue.map(\.id) + plans.map(\.id))) }
    }
    private(set) var pendingRESTWrites: [SharedPlanRESTWrite] = [] {
        didSet {
            publishEditorProjectionChanges(for: Set(
                oldValue.map(\.planID) + pendingRESTWrites.map(\.planID)
            ))
        }
    }
    private(set) var quarantinedRESTWrites: [SharedPlanRESTWrite] = [] {
        didSet {
            publishEditorProjectionChanges(for: Set(
                oldValue.map(\.planID) + quarantinedRESTWrites.map(\.planID)
            ))
        }
    }
    private(set) var documentSnapshots: [String: SharedPlanDocumentSnapshot] = [:] {
        didSet {
            publishEditorProjectionChanges(for: Set(oldValue.keys).union(documentSnapshots.keys))
        }
    }
    private(set) var archivedRecoveries: [UUID: ArchivedSharedPlanRecovery] = [:] {
        didSet {
            publishEditorProjectionChanges(for: Set(
                oldValue.values.map(\.snapshot.planID)
                    + archivedRecoveries.values.map(\.snapshot.planID)
            ))
        }
    }
    private(set) var syncStatuses: [String: SharedPlanSyncConnectionStatus] = [:] {
        didSet { publishEditorProjectionChanges(for: Set(oldValue.keys).union(syncStatuses.keys)) }
    }
    private(set) var localEditLimits: [String: SharedPlanLocalEditLimit] = [:] {
        didSet { publishEditorProjectionChanges(for: Set(oldValue.keys).union(localEditLimits.keys)) }
    }
    private(set) var membersByPlanID: [String: [SharedPlanMember]] = [:] {
        didSet { publishEditorProjectionChanges(for: Set(oldValue.keys).union(membersByPlanID.keys)) }
    }
    private(set) var memoDraftsByPlanID: [String: [SharedPlanMemoDraft]] = [:] {
        didSet { publishEditorProjectionChanges(for: Set(oldValue.keys).union(memoDraftsByPlanID.keys)) }
    }
    private(set) var editorProjectionGenerations: [String: UInt64] = [:]
    private(set) var memberNextCursorByPlanID: [String: String] = [:]
    private(set) var invitationsByPlanID: [String: [SharedPlanInvitation]] = [:]
    private(set) var invitationNextCursorByPlanID: [String: String] = [:]
    private(set) var createdInvitations: [UUID: SharedPlanCreatedInvitation] = [:]
    private(set) var notifications: [SharedPlanNotificationItem] = []
    private(set) var notificationNextCursor: String?
    private(set) var pendingNotificationReadIDs: Set<String> = []
    private(set) var notificationReadIssues: [String: String] = [:]
    private(set) var isLoaded = false
    private(set) var isRefreshing = false
    private(set) var isDrainingOutbox = false
    private(set) var restWriteIssues: [UUID: String] = [:]
    var issueMessage: String?

    @ObservationIgnored private let persistence: any SharedPlanPersisting
    @ObservationIgnored private let remote: any SharedPlanRemoteServicing
    @ObservationIgnored private let inviteCapabilityVault: any SharedPlanInviteCapabilityVault
    @ObservationIgnored private let createdInvitationVault:
        any SharedPlanCreatedInvitationVault
    @ObservationIgnored private let actorUserID: @MainActor @Sendable () -> String?
    @ObservationIgnored private let syncRequestAuthorizer:
        (any SharedPlanSyncRequestAuthorizing)?
    @ObservationIgnored private let syncConnector: any SharedPlanSyncConnecting
    @ObservationIgnored private let allowsUnconnectedContentMutations: Bool
    @ObservationIgnored private let automaticallySchedulesOutboxDrain: Bool
    @ObservationIgnored private var documents: [String: SharedPlanAutomergeDocument] = [:]
    @ObservationIgnored private var syncCoordinators: [String: SharedPlanSyncCoordinator] = [:]
    @ObservationIgnored private var syncCoordinatorBindings: [String: UUID] = [:]
    @ObservationIgnored private var outboxDrainWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var notificationReadQueue: [String] = []
    @ObservationIgnored private var isDrainingNotificationReadOutbox = false
    @ObservationIgnored private var notificationReadDrainWaiters:
        [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isClearingUserData = false
    @ObservationIgnored private var outboxRetryTask: Task<Void, Never>?
    @ObservationIgnored private var outboxRetryAttempt = 0
    @ObservationIgnored private var notificationReadRetryTask: Task<Void, Never>?
    @ObservationIgnored private var notificationReadRetryAttempt = 0
    @ObservationIgnored private var durableStorageAvailable = true
    @ObservationIgnored private var notificationCollectionGeneration: UInt64 = 0
    @ObservationIgnored private var memberCollectionGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var allocationMemberAuthorityPlanIDs: Set<String> = []
    @ObservationIgnored private var invitationCollectionGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var memoDraftsLoadedPlanIDs: Set<String> = []
    @ObservationIgnored private var editorProjectionContinuations:
        [String: [UUID: AsyncStream<UInt64>.Continuation]] = [:]
    // Local revisioned-write publication, membership refresh, and REST
    // acknowledgements all rewrite the same authoritative plan/outbox state.
    // Keep persistence + in-memory publication in one ordered critical section
    // so a drain cannot observe a durable write before it is available to rebase,
    // or resurrect a plan that a newer membership snapshot removed.
    @ObservationIgnored private var authorityOperationIsActive = false
    @ObservationIgnored private var authorityOperationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var authorityOperationGeneration: UInt64 = 0
    @ObservationIgnored private var contentOperationIsActive = false
    @ObservationIgnored private var contentOperationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistence: any SharedPlanPersisting,
        remote: any SharedPlanRemoteServicing = OfflineSharedPlanRemoteService(),
        inviteCapabilityVault: any SharedPlanInviteCapabilityVault = InMemorySharedPlanInviteCapabilityVault(),
        createdInvitationVault: any SharedPlanCreatedInvitationVault = InMemorySharedPlanCreatedInvitationVault(),
        syncRequestAuthorizer: (any SharedPlanSyncRequestAuthorizing)? = nil,
        syncConnector: any SharedPlanSyncConnecting = NetworkFrameworkSharedPlanSyncConnector(),
        allowsUnconnectedContentMutations: Bool = false,
        automaticallySchedulesOutboxDrain: Bool = true,
        actorUserID: @escaping @MainActor @Sendable () -> String?
    ) {
        self.persistence = persistence
        self.remote = remote
        self.inviteCapabilityVault = inviteCapabilityVault
        self.createdInvitationVault = createdInvitationVault
        self.syncRequestAuthorizer = syncRequestAuthorizer
        self.syncConnector = syncConnector
        self.allowsUnconnectedContentMutations = allowsUnconnectedContentMutations
        self.automaticallySchedulesOutboxDrain = automaticallySchedulesOutboxDrain
        self.actorUserID = actorUserID
    }

    static func live(
        userID: String,
        baseDirectory: URL = DirectoryManager.shared.environmentApplicationSupportDirectory,
        remote: any SharedPlanRemoteServicing = OfflineSharedPlanRemoteService(),
        syncRequestAuthorizer: (any SharedPlanSyncRequestAuthorizing)? = nil,
        actorUserID: @escaping @MainActor @Sendable () -> String?
    ) -> SharedPlanStore {
        let url = databaseURL(baseDirectory: baseDirectory, userID: userID)
        let persistence: any SharedPlanPersisting
        do {
            persistence = try SQLiteSharedPlanPersistence(path: url.path)
        } catch {
            persistence = UnavailableSharedPlanPersistence()
        }
        return SharedPlanStore(
            persistence: persistence,
            remote: remote,
            inviteCapabilityVault: KeychainSharedPlanInviteCapabilityVault(
                account: "\(AppEnvironment.current.storageNamespace).\(url.lastPathComponent)"
            ),
            createdInvitationVault: KeychainSharedPlanCreatedInvitationVault(
                account: "\(AppEnvironment.current.storageNamespace).\(url.lastPathComponent)"
            ),
            syncRequestAuthorizer: syncRequestAuthorizer,
            actorUserID: actorUserID
        )
    }

    nonisolated static func databaseURL(baseDirectory: URL, userID: String) -> URL {
        let digest = SHA256.hash(data: Data(userID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return baseDirectory.appendingPathComponent("shared-plans-\(digest).sqlite")
    }

    func load() async {
        guard !isLoaded else {
            await drainRESTOutbox()
            await drainNotificationReadOutbox()
            return
        }
        do {
            async let cachedPlans = persistence.loadPlans()
            async let writes = persistence.loadRESTWrites()
            async let archivedRecoveryTask = persistence.loadArchivedRecoveryDocuments()
            async let cachedNotifications = persistence.loadNotifications()
            async let notificationReadIntents = persistence.loadNotificationReadIntents()
            var loadedWrites = try await writes
            // One-time migration: old builds stored invite capabilities in the
            // SQLite JSON payload. Move them into ThisDeviceOnly Keychain and
            // overwrite the database row before any network delivery.
            for index in loadedWrites.indices {
                let write = loadedWrites[index]
                guard write.kind == .acceptInvitation, let token = write.inviteToken else {
                    continue
                }
                try await inviteCapabilityVault.save(token: token, requestID: write.id)
                let sanitized = write.removingInviteCapability()
                try await persistence.saveRESTWrite(sanitized)
                loadedWrites[index] = sanitized
            }
            try await inviteCapabilityVault.retainOnly(requestIDs: Set(
                loadedWrites.filter { $0.kind == .acceptInvitation }.map(\.id)
            ))
            let loadedCreatedInvitations = try await createdInvitationVault.loadAll()
            guard loadedCreatedInvitations.allSatisfy({ requestID, invitation in
                requestID == invitation.requestID
                    && Self.isStructurallyValidCreatedInvitation(invitation)
            }) else { throw SharedPlanError.persistenceFailed }
            createdInvitations = loadedCreatedInvitations
            quarantinedRESTWrites = loadedWrites.filter(\.isQuarantined)
            pendingRESTWrites = loadedWrites.filter { !$0.isQuarantined }
            let revokedPlanIDs = Set(quarantinedRESTWrites.compactMap { write in
                write.quarantineReason == .membershipRevoked ? write.planID : nil
            })
            let loadedPlans = try await cachedPlans
            plans = loadedPlans
                .filter { !revokedPlanIDs.contains($0.id) }
                .sorted(by: Self.planOrder)
            // A visible cache row can still be awaiting a fresh membership
            // generation after a transient reinstatement bootstrap failure.
            // Load durable issues before exposing edits, while leaving normal
            // healthy documents lazy.
            for plan in plans {
                guard var snapshot = try await persistence.loadDocument(planID: plan.id)
                else { continue }
                let normalizedLimit = Self.normalizedLocalEditLimit(
                    snapshot.localEditLimit,
                    pendingCount: snapshot.pendingOperationIDs.count
                )
                if normalizedLimit != snapshot.localEditLimit {
                    snapshot = SharedPlanDocumentSnapshot(
                        planID: snapshot.planID,
                        replicaID: snapshot.replicaID,
                        actorID: snapshot.actorID,
                        document: snapshot.document,
                        pendingOperationIDs: snapshot.pendingOperationIDs,
                        syncIssue: snapshot.syncIssue,
                        localEditLimit: normalizedLimit,
                        offlineMutationAuthority: snapshot.offlineMutationAuthority
                    )
                    try await persistence.saveMutation(plan: plan, document: snapshot)
                }
                guard snapshot.syncIssue != nil || snapshot.localEditLimit != nil else {
                    continue
                }
                documentSnapshots[plan.id] = snapshot
                updateLocalEditLimit(planID: plan.id, snapshot: snapshot)
            }
            let orphaned = try await persistence.loadOrphanedDocuments(
                excludingPlanIDs: Set(plans.map(\.id))
            )
            for snapshot in orphaned {
                documentSnapshots[snapshot.planID] = snapshot
            }
            let loadedArchivedRecoveries = try await archivedRecoveryTask
            archivedRecoveries = Dictionary(
                uniqueKeysWithValues: loadedArchivedRecoveries.map {
                    ($0.id, $0)
                }
            )
            for write in quarantinedRESTWrites {
                restWriteIssues[write.id] = Self.issueMessage(for: write)
            }
            let loadedNotifications = try await cachedNotifications
            let loadedNotificationReadIntents = try await notificationReadIntents
            let notificationIDs = Set(loadedNotifications.map(\.id))
            guard notificationIDs.count == loadedNotifications.count,
                  loadedNotifications.allSatisfy({
                      Self.isCanonicalNotificationID($0.id)
                          && Self.isCanonicalUUIDString($0.planID)
                  }),
                  Set(loadedNotificationReadIntents).count
                    == loadedNotificationReadIntents.count,
                  loadedNotificationReadIntents.allSatisfy({
                      Self.isCanonicalNotificationID($0)
                          && notificationIDs.contains($0)
                  })
            else { throw SharedPlanError.persistenceFailed }
            notifications = loadedNotifications
            notificationReadQueue = loadedNotificationReadIntents
            pendingNotificationReadIDs = Set(notificationReadQueue)
            isLoaded = true
            await drainRESTOutbox()
            await drainNotificationReadOutbox()
        } catch {
            issueMessage = error.localizedDescription
        }
    }

    func refresh() async {
        if !isLoaded { await load() }
        guard !isRefreshing, !isClearingUserData else { return }
        isRefreshing = true
        await acquireAuthorityOperation()
        var shouldDrainAfterRefresh = true
        do {
            var refreshIssue: String?
            let fetched = try await remote.fetchPlans()
            let reinstated = fetched.compactMap { plan -> (
                SharedPlan,
                SharedPlanDocumentSnapshot
            )? in
                guard let snapshot = documentSnapshots[plan.id],
                      snapshot.syncIssue == .membershipRevoked
                else { return nil }
                return (plan, snapshot)
            }
            let visiblePlanIDs = Set(fetched.map(\.id))
            let removedPlanIDs = Set(plans.map(\.id)).subtracting(visiblePlanIDs)
            let newlyQuarantined = pendingRESTWrites.compactMap { write -> SharedPlanRESTWrite? in
                guard Self.isMetadataWrite(write.kind),
                      !visiblePlanIDs.contains(write.planID)
                else { return nil }
                return write.quarantined(for: .membershipRevoked)
            }
            let newlyQuarantinedIDs = Set(newlyQuarantined.map(\.id))
            let remainingPending = pendingRESTWrites.filter {
                !newlyQuarantinedIDs.contains($0.id)
            }
            let allQuarantined = Self.mergingQuarantinedWrites(
                quarantinedRESTWrites,
                newlyQuarantined
            )
            let merged = Self.merged(
                remote: fetched,
                local: plans,
                pendingWrites: remainingPending
            )
            // Authority is fail-closed in memory as soon as the server omits a
            // plan, even if the following durability transaction fails.
            plans = merged
            pendingRESTWrites = remainingPending
            quarantinedRESTWrites = allQuarantined
            for planID in removedPlanIDs {
                syncCoordinatorBindings[planID] = nil
                if let coordinator = syncCoordinators.removeValue(forKey: planID) {
                    await coordinator.stop()
                }
                syncStatuses[planID] = .quarantined(.membershipRevoked)
            }
            for write in newlyQuarantined {
                restWriteIssues[write.id] = Self.issueMessage(for: write)
            }
            do {
                var recoveries: [SharedPlanDocumentSnapshot] = []
                for planID in removedPlanIDs {
                    let existing: SharedPlanDocumentSnapshot?
                    if let loaded = documentSnapshots[planID] {
                        existing = loaded
                    } else {
                        existing = try await persistence.loadDocument(planID: planID)
                    }
                    guard let existing else { continue }
                    let recovery = SharedPlanDocumentSnapshot(
                        planID: existing.planID,
                        replicaID: existing.replicaID,
                        actorID: existing.actorID,
                        document: existing.document,
                        pendingOperationIDs: existing.pendingOperationIDs,
                        syncIssue: .membershipRevoked,
                        localEditLimit: existing.localEditLimit,
                        offlineMutationAuthority: existing.offlineMutationAuthority
                    )
                    recoveries.append(recovery)
                }
                try await persistence.reconcileCachedPlans(
                    merged,
                    quarantinedWrites: newlyQuarantined,
                    recoveryDocuments: recoveries
                )
                for recovery in recoveries {
                    documentSnapshots[recovery.planID] = recovery
                }
            } catch {
                durableStorageAvailable = false
                refreshIssue = error.localizedDescription
                shouldDrainAfterRefresh = false
            }
            if durableStorageAvailable {
                var reinstatementIssue: String?
                for (remotePlan, revokedSnapshot) in reinstated {
                    let archivedIntents = quarantinedRESTWrites.filter {
                        $0.planID == remotePlan.id
                            && $0.quarantineReason == .membershipRevoked
                    }
                    do {
                        let bootstrap = try await remote.fetchSyncBootstrap(planID: remotePlan.id)
                        let freshReplicaID = UUID()
                        let rebuilt = try await validatedBootstrapDocument(
                            bootstrap,
                            for: remotePlan,
                            replicaID: freshReplicaID
                        )
                        var reinstatedPlan = remotePlan
                        reinstatedPlan.circleKeys = try await rebuilt.circleKeys()
                        let newSnapshot = await rebuilt.snapshot(pendingOperationIDs: [])
                        let recovery = ArchivedSharedPlanRecovery(
                            id: UUID(),
                            snapshot: revokedSnapshot,
                            metadataIntents: archivedIntents
                        )
                        do {
                            try await persistence.replaceReinstatedPlan(
                                reinstatedPlan,
                                document: newSnapshot,
                                retaining: recovery
                            )
                        } catch {
                            durableStorageAvailable = false
                            shouldDrainAfterRefresh = false
                            throw error
                        }
                        archivedRecoveries[recovery.id] = recovery
                        let archivedIntentIDs = Set(archivedIntents.map(\.id))
                        quarantinedRESTWrites.removeAll {
                            archivedIntentIDs.contains($0.id)
                        }
                        for intent in archivedIntents { restWriteIssues[intent.id] = nil }
                        documents[remotePlan.id] = rebuilt
                        documentSnapshots[remotePlan.id] = newSnapshot
                        syncStatuses[remotePlan.id] = .idle
                        upsert(reinstatedPlan)
                    } catch {
                        reinstatementIssue = error.localizedDescription
                        if !durableStorageAvailable { break }
                    }
                }
                if let reinstatementIssue {
                    refreshIssue = reinstatementIssue
                }
            }
            if let refreshIssue {
                issueMessage = refreshIssue
            } else if shouldDrainAfterRefresh {
                issueMessage = nil
            }
        } catch {
            // The durable cache remains fully usable offline. Avoid replacing a
            // useful screen with a transient network error.
            if plans.isEmpty { issueMessage = error.localizedDescription }
        }
        releaseAuthorityOperation()
        isRefreshing = false
        if shouldDrainAfterRefresh {
            await drainRESTOutbox()
        }
    }

    func createAvailability(comiketNo: Int) -> SharedPlanCreateAvailability {
        let pendingCreates = pendingRESTWrites.filter {
            $0.kind == .create && $0.comiketNo == comiketNo
        }.count
        return SharedPlanCreateAvailability(
            activeOwnedCount: plans.filter {
                $0.comiketNo == comiketNo && $0.isOwnedActive
            }.count + pendingCreates
        )
    }

    @discardableResult
    func createPlan(
        name: String,
        comiketNo: Int,
        now: Date = Date()
    ) async throws -> SharedPlan {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        let name = try SharedPlanValidation.normalizedPlanName(name)
        guard createAvailability(comiketNo: comiketNo).canCreate else {
            throw SharedPlanError.planLimitReached(comiketNo: comiketNo)
        }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        let requestID = UUID()
        let write = SharedPlanRESTWrite(
            id: requestID,
            planID: "pending-create:\(requestID.uuidString.lowercased())",
            kind: .create,
            baseRevision: nil,
            name: name,
            comiketNo: comiketNo,
            inviteToken: nil,
            createdAt: now
        )
        // Persist the idempotent request before network I/O. No editable local
        // plan is exposed until the service returns its UUID and exact root.
        try await persistence.saveRESTWrite(write)
        pendingRESTWrites.append(write)
        do {
            return try await completePendingCreate(write)
        } catch {
            scheduleOutboxDrain()
            throw error
        }
    }

    func retryPendingPlanCreations() async {
        await drainRESTOutbox()
    }

    /// Drains in creation order and stops at the first failure so later writes
    /// cannot overtake a revision-dependent predecessor.
    func drainRESTOutbox() async {
        guard !isClearingUserData else { return }
        guard !isDrainingOutbox else {
            await withCheckedContinuation { continuation in
                outboxDrainWaiters.append(continuation)
            }
            return
        }
        isDrainingOutbox = true
        await acquireAuthorityOperation()
        defer {
            releaseAuthorityOperation()
            isDrainingOutbox = false
            let waiters = outboxDrainWaiters
            outboxDrainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !isClearingUserData else { return }
        while !isClearingUserData,
              let write = pendingRESTWrites.sorted(by: Self.writeOrder).first
        {
            do {
                switch write.kind {
                case .create:
                    _ = try await completePendingCreate(write)
                case .rename:
                    guard let name = write.name, let baseRevision = write.baseRevision else {
                        throw SharedPlanError.persistenceFailed
                    }
                    let result = try await remote.renamePlan(
                        id: write.planID,
                        requestID: write.id,
                        baseRevision: baseRevision,
                        name: name
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                case .archive:
                    guard let baseRevision = write.baseRevision else {
                        throw SharedPlanError.persistenceFailed
                    }
                    let result = try await remote.archivePlan(
                        id: write.planID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                case .reopen:
                    guard let baseRevision = write.baseRevision else {
                        throw SharedPlanError.persistenceFailed
                    }
                    let result = try await remote.reopenPlan(
                        id: write.planID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                case .acceptInvitation:
                    guard let token = try await inviteCapabilityVault.token(requestID: write.id) else {
                        let quarantined = write.quarantined(
                            for: .terminalFailure,
                            code: "invite_capability_missing",
                            message: "保護された招待情報が見つからないため、自動送信を停止しました。招待リンクをもう一度開いてください。"
                        )
                        try await persistence.saveQuarantinedRESTWrites(
                            [quarantined],
                            currentPlan: nil
                        )
                        pendingRESTWrites.removeAll { $0.id == write.id }
                        quarantinedRESTWrites = Self.mergingQuarantinedWrites(
                            quarantinedRESTWrites,
                            [quarantined]
                        )
                        restWriteIssues[write.id] = Self.issueMessage(for: quarantined)
                        continue
                    }
                    let result = try await remote.acceptInvitation(
                        token: token,
                        requestID: write.id
                    )
                    try validateReceipt(result.receipt, for: write)
                    guard result.plan.revision >= result.receipt.resultRevision else {
                        throw SharedPlanError.persistenceFailed
                    }
                    try await bootstrapAcceptedPlan(result.plan, removing: write)
                case .revokeMember:
                    guard let userID = write.targetUserID,
                          let baseRevision = write.baseRevision
                    else { throw SharedPlanError.persistenceFailed }
                    let result = try await remote.revokeMember(
                        planID: write.planID,
                        userID: userID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                    await refreshMembersAfterMutation(planID: write.planID)
                case .reinstateMember:
                    guard let userID = write.targetUserID,
                          let baseRevision = write.baseRevision
                    else { throw SharedPlanError.persistenceFailed }
                    let result = try await remote.reinstateMember(
                        planID: write.planID,
                        userID: userID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                    await refreshMembersAfterMutation(planID: write.planID)
                case .transferOwnership:
                    guard let userID = write.targetUserID,
                          let baseRevision = write.baseRevision
                    else { throw SharedPlanError.persistenceFailed }
                    let result = try await remote.transferOwnership(
                        planID: write.planID,
                        newOwnerUserID: userID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    try await acknowledgeMetadataWrite(write, result: result)
                    await refreshMembersAfterMutation(planID: write.planID)
                case .createInvitation:
                    guard let baseRevision = write.baseRevision,
                          let expiresAt = write.expiresAt
                    else { throw SharedPlanError.persistenceFailed }
                    if let protected = createdInvitations[write.id] {
                        try await acknowledgeCreatedInvitation(write, result: protected)
                    } else {
                        let result = try await remote.createInvitation(
                            planID: write.planID,
                            requestID: write.id,
                            baseRevision: baseRevision,
                            expiresAt: expiresAt
                        )
                        guard Self.isStructurallyValidCreatedInvitation(result) else {
                            throw SharedPlanError.persistenceFailed
                        }
                        try validateCreatedInvitation(result, for: write)
                        try await createdInvitationVault.save(result)
                        createdInvitations[write.id] = result
                        try await acknowledgeCreatedInvitation(write, result: result)
                    }
                case .revokeInvitation:
                    guard let invitationID = write.invitationID,
                          let baseRevision = write.baseRevision
                    else { throw SharedPlanError.persistenceFailed }
                    let result = try await remote.revokeInvitation(
                        planID: write.planID,
                        invitationID: invitationID,
                        requestID: write.id,
                        baseRevision: baseRevision
                    )
                    _ = advanceInvitationCollectionGeneration(planID: write.planID)
                    try await acknowledgeMetadataWrite(write, result: result)
                    invitationNextCursorByPlanID[write.planID] = nil
                    if var invitations = invitationsByPlanID[write.planID],
                       let index = invitations.firstIndex(where: {
                           $0.invitationID == invitationID
                       })
                    {
                        let invitation = invitations[index]
                        invitations[index] = SharedPlanInvitation(
                            invitationID: invitation.invitationID,
                            createdByUserID: invitation.createdByUserID,
                            currentUserCanRevoke: invitation.currentUserCanRevoke,
                            expiresAt: invitation.expiresAt,
                            revokedAt: result.plan.updatedAt,
                            createdAt: invitation.createdAt
                        )
                        invitationsByPlanID[write.planID] = invitations
                    }
                }
                restWriteIssues[write.id] = nil
            } catch let error as CominaviServiceError {
                if case .revisionConflict(
                    _, _, let currentRevision, let currentPlan
                ) = error {
                    do {
                        try await quarantineRevisionConflict(
                            startingWith: write,
                            currentRevision: currentRevision,
                            currentPlan: currentPlan
                        )
                        continue
                    } catch {
                        restWriteIssues[write.id] = error.localizedDescription
                        break
                    }
                }
                if write.kind == .acceptInvitation,
                   Self.isTerminalInvitationError(error)
                {
                    do {
                        try await discardInvitationWrite(write)
                        restWriteIssues[write.id] = error.localizedDescription
                        continue
                    } catch {
                        restWriteIssues[write.id] = error.localizedDescription
                        break
                    }
                }
                if Self.isTerminalRESTError(error) {
                    do {
                        try await quarantineTerminalFailure(write, error: error)
                        continue
                    } catch {
                        restWriteIssues[write.id] = error.localizedDescription
                        break
                    }
                }
                if Self.isTransientRESTError(error) {
                    scheduleTransientOutboxRetry()
                }
                restWriteIssues[write.id] = error.localizedDescription
                // 409/422 require user-visible reconciliation; transient and
                // offline failures retain the exact same durable request too.
                break
            } catch {
                if error is URLError {
                    scheduleTransientOutboxRetry()
                }
                restWriteIssues[write.id] = error.localizedDescription
                break
            }
        }
        if pendingRESTWrites.isEmpty {
            outboxRetryAttempt = 0
            outboxRetryTask?.cancel()
            outboxRetryTask = nil
        }
    }

    func networkBecameReachable() async {
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        outboxRetryAttempt = 0
        notificationReadRetryTask?.cancel()
        notificationReadRetryTask = nil
        notificationReadRetryAttempt = 0
        await drainRESTOutbox()
        await drainNotificationReadOutbox()
        for (planID, coordinator) in syncCoordinators
        where Self.permitsSync(documentSnapshots[planID]?.syncIssue) {
            await coordinator.restartAfterNetworkRecovery()
        }
    }

    func startSync(planID: String) async {
        guard !isClearingUserData, actorUserID() != nil else { return }
        if let issue = documentSnapshots[planID]?.syncIssue,
           !Self.permitsSync(issue)
        {
            syncStatuses[planID] = .quarantined(issue)
            return
        }
        if let existing = syncCoordinators[planID] {
            await existing.start()
            return
        }
        guard let syncRequestAuthorizer else {
            syncStatuses[planID] = .quarantined(.unavailable(
                String(localized: "共同編集サーバーに接続できません。")
            ))
            return
        }

        await acquireAuthorityOperation()
        await acquireContentOperation()
        let document: SharedPlanAutomergeDocument
        do {
            let currentPlan = try plan(id: planID)
            guard currentPlan.lifecycle == .active,
                  [.owner, .editor].contains(currentPlan.role)
            else { throw SharedPlanError.insufficientRole }
            document = try await self.document(for: planID)
            if let issue = documentSnapshots[planID]?.syncIssue,
               !Self.permitsSync(issue)
            {
                throw Self.error(for: issue)
            }
        } catch {
            releaseContentOperation()
            releaseAuthorityOperation()
            issueMessage = error.localizedDescription
            return
        }
        releaseContentOperation()
        releaseAuthorityOperation()

        let bindingID = UUID()
        let session = SharedPlanSyncSession(planID: planID, document: document)
        let callbacks = SharedPlanSyncCoordinatorCallbacks(
            pendingOperationCount: { [weak self] in
                await self?.pendingOperationCount(
                    planID: planID,
                    bindingID: bindingID
                ) ?? 0
            },
            generateOutboundFrame: { [weak self] session in
                guard let self else { throw CancellationError() }
                return try await self.generateSyncFrame(
                    session,
                    planID: planID,
                    bindingID: bindingID
                )
            },
            receiveServerFrame: { [weak self] session, frame in
                guard let self else { throw CancellationError() }
                return try await self.receiveSyncFrame(
                    frame,
                    session: session,
                    planID: planID,
                    bindingID: bindingID
                )
            },
            receiveAcknowledgement: { [weak self] session, acknowledgement in
                guard let self else { throw CancellationError() }
                return try await self.receiveSyncAcknowledgement(
                    acknowledgement,
                    session: session,
                    planID: planID,
                    bindingID: bindingID
                )
            },
            receiveError: { [weak self] error in
                await self?.handleSyncError(
                    error,
                    planID: planID,
                    bindingID: bindingID
                )
            },
            updateStatus: { [weak self] status in
                await self?.updateSyncStatus(
                    status,
                    planID: planID,
                    bindingID: bindingID
                )
            }
        )
        let coordinator = SharedPlanSyncCoordinator(
            planID: planID,
            authorizer: syncRequestAuthorizer,
            connector: syncConnector,
            session: session,
            callbacks: callbacks
        )
        syncCoordinatorBindings[planID] = bindingID
        syncCoordinators[planID] = coordinator
        await coordinator.start()
    }

    func stopSync(planID: String) async {
        syncCoordinatorBindings[planID] = nil
        guard let coordinator = syncCoordinators.removeValue(forKey: planID) else {
            syncStatuses[planID] = .idle
            return
        }
        await coordinator.stop()
        syncStatuses[planID] = .idle
    }

    func activeSyncDocumentIdentity(
        planID: String
    ) async -> SharedPlanSyncDocumentIdentity? {
        guard let coordinator = syncCoordinators[planID] else { return nil }
        return await coordinator.documentIdentity()
    }

    func clearUserData() async {
        isClearingUserData = true
        invalidateCollectionRequests()
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        notificationReadRetryTask?.cancel()
        notificationReadRetryTask = nil
        let coordinators = Array(syncCoordinators.values)
        syncCoordinators.removeAll()
        syncCoordinatorBindings.removeAll()
        for coordinator in coordinators { await coordinator.stop() }
        if isDrainingOutbox {
            await withCheckedContinuation { continuation in
                outboxDrainWaiters.append(continuation)
            }
        }
        if isDrainingNotificationReadOutbox {
            await withCheckedContinuation { continuation in
                notificationReadDrainWaiters.append(continuation)
            }
        }
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        do {
            try await persistence.removeAll()
        } catch {
            issueMessage = error.localizedDescription
        }
        do {
            try await inviteCapabilityVault.removeAll()
        } catch {
            issueMessage = error.localizedDescription
        }
        do {
            try await createdInvitationVault.removeAll()
        } catch {
            issueMessage = error.localizedDescription
        }
        plans.removeAll()
        pendingRESTWrites.removeAll()
        quarantinedRESTWrites.removeAll()
        documentSnapshots.removeAll()
        archivedRecoveries.removeAll()
        syncStatuses.removeAll()
        documents.removeAll()
        restWriteIssues.removeAll()
        membersByPlanID.removeAll()
        allocationMemberAuthorityPlanIDs.removeAll()
        memoDraftsByPlanID.removeAll()
        memoDraftsLoadedPlanIDs.removeAll()
        for continuations in editorProjectionContinuations.values {
            for continuation in continuations.values { continuation.finish() }
        }
        editorProjectionContinuations.removeAll()
        editorProjectionGenerations.removeAll()
        memberNextCursorByPlanID.removeAll()
        invitationsByPlanID.removeAll()
        invitationNextCursorByPlanID.removeAll()
        createdInvitations.removeAll()
        notifications.removeAll()
        notificationNextCursor = nil
        pendingNotificationReadIDs.removeAll()
        notificationReadIssues.removeAll()
        notificationReadQueue.removeAll()
        isLoaded = false
        isClearingUserData = false
    }

    func renamePlan(id: String, name: String, now: Date = Date()) async throws {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        var plan = try editablePlan(id: id, ownerOnly: true)
        let name = try SharedPlanValidation.normalizedPlanName(name)
        guard name != plan.name else { return }
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: id,
            kind: .rename,
            baseRevision: plan.revision,
            name: name,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: now
        )
        plan.name = name
        plan.updatedAt = now
        try await persistence.savePlan(plan, write: write)
        pendingRESTWrites.append(write)
        upsert(plan)
        scheduleOutboxDrain()
    }

    func archivePlan(id: String, now: Date = Date()) async throws {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        var plan = try editablePlan(id: id, ownerOnly: true)
        guard plan.lifecycle != .archived else { return }
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: id,
            kind: .archive,
            baseRevision: plan.revision,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: now
        )
        plan.lifecycle = .archived
        plan.updatedAt = now
        try await persistence.savePlan(plan, write: write)
        pendingRESTWrites.append(write)
        upsert(plan)
        scheduleOutboxDrain()
    }

    func reopenPlan(id: String, now: Date = Date()) async throws {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        var plan = try editablePlan(id: id, ownerOnly: true, allowArchived: true)
        guard plan.lifecycle != .active else { return }
        guard createAvailability(comiketNo: plan.comiketNo).canCreate else {
            throw SharedPlanError.planLimitReached(comiketNo: plan.comiketNo)
        }
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: id,
            kind: .reopen,
            baseRevision: plan.revision,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: now
        )
        plan.lifecycle = .active
        plan.updatedAt = now
        try await persistence.savePlan(plan, write: write)
        pendingRESTWrites.append(write)
        upsert(plan)
        scheduleOutboxDrain()
    }

    @discardableResult
    func acceptInvitation(token: String, now: Date = Date()) async throws -> UUID {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard SharedPlanInvitationLink.isValid(token: token) else {
            throw SharedPlanError.invalidInvite
        }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        let requestID = UUID()
        let write = SharedPlanRESTWrite(
            id: requestID,
            planID: "pending-invite:\(requestID.uuidString.lowercased())",
            kind: .acceptInvitation,
            baseRevision: nil,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            createdAt: now
        )
        try await inviteCapabilityVault.save(token: token, requestID: requestID)
        do {
            try await persistence.saveRESTWrite(write)
        } catch {
            try? await inviteCapabilityVault.remove(requestID: requestID)
            throw error
        }
        pendingRESTWrites.append(write)
        scheduleOutboxDrain()
        return requestID
    }

    func cancelInvitationAcceptance(requestID: UUID) async throws {
        guard let write = pendingRESTWrites.first(where: {
            $0.id == requestID && $0.kind == .acceptInvitation
        }) else { return }
        try await discardInvitationWrite(write)
    }

    func refreshNotifications(limit: Int = 50) async throws {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        notificationCollectionGeneration &+= 1
        let generation = notificationCollectionGeneration
        let page = try await remote.fetchNotifications(limit: limit, cursor: nil)
        guard generation == notificationCollectionGeneration else { return }
        try await persistence.saveNotifications(page.items)
        guard generation == notificationCollectionGeneration else { return }
        notifications = Self.mergingNotifications(notifications, page.items)
        notificationNextCursor = page.nextCursor
    }

    func loadMoreNotifications(limit: Int = 50) async throws {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        guard let cursor = notificationNextCursor else { return }
        let generation = notificationCollectionGeneration
        let page = try await remote.fetchNotifications(limit: limit, cursor: cursor)
        guard generation == notificationCollectionGeneration,
              notificationNextCursor == cursor
        else { return }
        try await persistence.saveNotifications(page.items)
        guard generation == notificationCollectionGeneration,
              notificationNextCursor == cursor
        else { return }
        notifications = Self.mergingNotifications(notifications, page.items)
        notificationNextCursor = page.nextCursor
    }

    func markNotificationRead(id: String, now: Date = Date()) async throws {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        guard Self.isCanonicalNotificationID(id),
              let notification = notifications.first(where: { $0.id == id })
        else { throw SharedPlanError.persistenceFailed }
        guard notification.readAt == nil,
              !pendingNotificationReadIDs.contains(id)
        else { return }
        try await persistence.saveNotificationReadIntent(eventID: id, createdAt: now)
        notificationReadQueue.append(id)
        pendingNotificationReadIDs.insert(id)
        scheduleNotificationReadDrain()
    }

    func drainNotificationReadOutbox() async {
        guard isLoaded, !isClearingUserData, !isDrainingNotificationReadOutbox else {
            return
        }
        isDrainingNotificationReadOutbox = true
        defer {
            isDrainingNotificationReadOutbox = false
            let waiters = notificationReadDrainWaiters
            notificationReadDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        while let eventID = notificationReadQueue.first, !isClearingUserData {
            do {
                let receipt = try await remote.markNotificationRead(id: eventID)
                guard receipt.id == eventID,
                      let notification = notifications.first(where: { $0.id == eventID }),
                      receipt.readAt >= notification.createdAt
                else {
                    throw SharedPlanError.persistenceFailed
                }
                try await persistence.acknowledgeNotificationRead(receipt)
                if let index = notifications.firstIndex(where: { $0.id == eventID }) {
                    notifications[index].readAt = notifications[index].readAt ?? receipt.readAt
                }
                notificationReadQueue.removeFirst()
                pendingNotificationReadIDs.remove(eventID)
                notificationReadIssues[eventID] = nil
                notificationReadRetryAttempt = 0
            } catch let error as CominaviServiceError {
                if Self.isTerminalNotificationReadError(error) {
                    do {
                        try await persistence.removeNotificationReadIntent(eventID: eventID)
                        notificationReadQueue.removeFirst()
                        pendingNotificationReadIDs.remove(eventID)
                        notificationReadIssues[eventID] = error.localizedDescription
                        continue
                    } catch {
                        notificationReadIssues[eventID] = error.localizedDescription
                        break
                    }
                }
                notificationReadIssues[eventID] = error.localizedDescription
                scheduleNotificationReadRetry()
                break
            } catch {
                notificationReadIssues[eventID] = error.localizedDescription
                scheduleNotificationReadRetry()
                break
            }
        }
        if notificationReadQueue.isEmpty {
            notificationReadRetryAttempt = 0
            notificationReadRetryTask?.cancel()
            notificationReadRetryTask = nil
        }
    }

    func refreshMembers(planID: String, limit: Int = 50) async throws {
        _ = try memberVisiblePlan(id: planID, allowArchived: true)
        allocationMemberAuthorityPlanIDs.remove(planID)
        let generation = advanceMemberCollectionGeneration(planID: planID)
        let page = try await remote.fetchMembers(
            planID: planID,
            limit: limit,
            cursor: nil
        )
        guard memberCollectionGenerations[planID] == generation else { return }
        membersByPlanID[planID] = page.items
        memberNextCursorByPlanID[planID] = page.nextCursor
    }

    func loadMoreMembers(planID: String, limit: Int = 50) async throws {
        _ = try memberVisiblePlan(id: planID, allowArchived: true)
        guard let cursor = memberNextCursorByPlanID[planID] else { return }
        let generation = memberCollectionGenerations[planID] ?? 0
        let page = try await remote.fetchMembers(
            planID: planID,
            limit: limit,
            cursor: cursor
        )
        guard (memberCollectionGenerations[planID] ?? 0) == generation,
              memberNextCursorByPlanID[planID] == cursor
        else { return }
        membersByPlanID[planID] = Self.mergingMembers(
            membersByPlanID[planID] ?? [],
            page.items
        )
        memberNextCursorByPlanID[planID] = page.nextCursor
    }

    /// Loads a complete, generation-consistent member authority for buyer
    /// assignment. Active membership is capped at 50 by the service, while an
    /// owner's removed-member history may require additional pages.
    func refreshAllAllocationMembers(planID: String) async throws {
        _ = try memberVisiblePlan(id: planID, allowArchived: true)
        allocationMemberAuthorityPlanIDs.remove(planID)
        let generation = advanceMemberCollectionGeneration(planID: planID)
        var cursor: String?
        var seenCursors: Set<String> = []
        var members: [SharedPlanMember] = []
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= 200 else { throw SharedPlanError.syncProtocolViolation }
            let page = try await remote.fetchMembers(
                planID: planID,
                limit: 50,
                cursor: cursor
            )
            guard memberCollectionGenerations[planID] == generation else { return }
            members = Self.mergingMembers(members, page.items)
            guard members.filter({ $0.membershipStatus == .active }).count <= 50 else {
                throw SharedPlanError.syncProtocolViolation
            }
            if let next = page.nextCursor {
                guard !next.isEmpty, seenCursors.insert(next).inserted else {
                    throw SharedPlanError.syncProtocolViolation
                }
            }
            cursor = page.nextCursor
        } while cursor != nil

        guard memberCollectionGenerations[planID] == generation else { return }
        membersByPlanID[planID] = members
        memberNextCursorByPlanID[planID] = nil
        allocationMemberAuthorityPlanIDs.insert(planID)
    }

    @discardableResult
    func revokeMember(
        planID: String,
        userID: String,
        now: Date = Date()
    ) async throws -> UUID {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let plan = try editablePlan(id: planID, ownerOnly: true)
        guard userID != actorUserID(), Self.isPublicUserID(userID) else {
            throw SharedPlanError.insufficientRole
        }
        return try await enqueueAdministrativeWrite(
            plan: plan,
            kind: .revokeMember,
            targetUserID: userID,
            now: now
        )
    }

    @discardableResult
    func reinstateMember(
        planID: String,
        userID: String,
        now: Date = Date()
    ) async throws -> UUID {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let plan = try editablePlan(id: planID, ownerOnly: true)
        guard Self.isPublicUserID(userID) else { throw SharedPlanError.insufficientRole }
        return try await enqueueAdministrativeWrite(
            plan: plan,
            kind: .reinstateMember,
            targetUserID: userID,
            now: now
        )
    }

    @discardableResult
    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        now: Date = Date()
    ) async throws -> UUID {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let plan = try editablePlan(id: planID, ownerOnly: true)
        guard let member = membersByPlanID[planID]?.first(where: {
            $0.userID == newOwnerUserID
        }), member.membershipStatus == .active, member.role == .editor
        else { throw SharedPlanError.insufficientRole }
        return try await enqueueAdministrativeWrite(
            plan: plan,
            kind: .transferOwnership,
            targetUserID: newOwnerUserID,
            now: now
        )
    }

    func refreshInvitations(planID: String, limit: Int = 50) async throws {
        _ = try memberVisiblePlan(id: planID, allowArchived: true)
        let generation = advanceInvitationCollectionGeneration(planID: planID)
        let page = try await remote.fetchInvitations(
            planID: planID,
            limit: limit,
            cursor: nil
        )
        guard invitationCollectionGenerations[planID] == generation else { return }
        invitationsByPlanID[planID] = page.items
        invitationNextCursorByPlanID[planID] = page.nextCursor
    }

    func loadMoreInvitations(planID: String, limit: Int = 50) async throws {
        _ = try memberVisiblePlan(id: planID, allowArchived: true)
        guard let cursor = invitationNextCursorByPlanID[planID] else { return }
        let generation = invitationCollectionGenerations[planID] ?? 0
        let page = try await remote.fetchInvitations(
            planID: planID,
            limit: limit,
            cursor: cursor
        )
        guard (invitationCollectionGenerations[planID] ?? 0) == generation,
              invitationNextCursorByPlanID[planID] == cursor
        else { return }
        invitationsByPlanID[planID] = Self.mergingInvitations(
            invitationsByPlanID[planID] ?? [],
            page.items
        )
        invitationNextCursorByPlanID[planID] = page.nextCursor
    }

    @discardableResult
    func createInvitation(
        planID: String,
        expiresAt: Date,
        now: Date = Date()
    ) async throws -> UUID {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let plan = try memberVisiblePlan(id: planID, allowArchived: false)
        let expiresAt = SharedPlanInvitationExpiration.canonical(expiresAt)
        guard expiresAt > SharedPlanInvitationExpiration.canonical(now) else {
            throw SharedPlanError.invalidInvite
        }
        return try await enqueueAdministrativeWrite(
            plan: plan,
            kind: .createInvitation,
            expiresAt: expiresAt,
            now: now
        )
    }

    @discardableResult
    func revokeInvitation(
        planID: String,
        invitationID: String,
        now: Date = Date()
    ) async throws -> UUID {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let plan = try memberVisiblePlan(id: planID, allowArchived: false)
        guard let invitation = invitationsByPlanID[planID]?.first(where: {
            $0.invitationID == invitationID
        }), invitation.currentUserCanRevoke
        else { throw SharedPlanError.insufficientRole }
        return try await enqueueAdministrativeWrite(
            plan: plan,
            kind: .revokeInvitation,
            invitationID: invitationID,
            now: now
        )
    }

    func discardCreatedInvitation(requestID: UUID) async throws {
        guard createdInvitations[requestID] != nil else { return }
        try await createdInvitationVault.remove(requestID: requestID)
        createdInvitations[requestID] = nil
    }

    private func enqueueAdministrativeWrite(
        plan: SharedPlan,
        kind: SharedPlanRESTWriteKind,
        targetUserID: String? = nil,
        invitationID: String? = nil,
        expiresAt: Date? = nil,
        now: Date
    ) async throws -> UUID {
        let write = SharedPlanRESTWrite(
            id: UUID(),
            planID: plan.id,
            kind: kind,
            baseRevision: plan.revision,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: now
        )
        try await persistence.savePlan(plan, write: write)
        pendingRESTWrites.append(write)
        scheduleOutboxDrain()
        return write.id
    }

    @discardableResult
    func addCircle(
        _ key: SharedPlanCircleKey,
        to planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setCirclePresence(key, .active)
        )
    }

    @discardableResult
    func removeCircle(
        _ key: SharedPlanCircleKey,
        from planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setCirclePresence(key, .removed)
        )
    }

    @discardableResult
    func updateMemo(
        _ memo: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .replaceMemo(memo, circle: key)
        )
    }

    func persistMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        guard draft.planID == draft.planID.lowercased(),
              Self.isCanonicalUUIDString(draft.planID),
              draft.generation > 0,
              draft.circle.comiketNo > 0,
              draft.circle.wcID > 0
        else { throw SharedPlanError.persistenceFailed }
        var retainedReplicaIDs = Set(
            documentSnapshots.values
                .filter { $0.planID == draft.planID }
                .map(\.replicaID)
        )
        retainedReplicaIDs.formUnion(
            archivedRecoveries.values
                .filter { $0.snapshot.planID == draft.planID }
                .map(\.snapshot.replicaID)
        )
        if retainedReplicaIDs.isEmpty,
           let persisted = try await persistence.loadDocument(planID: draft.planID)
        {
            retainedReplicaIDs.insert(persisted.replicaID)
        }
        guard retainedReplicaIDs.contains(draft.replicaID) else {
            throw SharedPlanError.membershipRevoked
        }
        try await persistence.saveMemoDraft(draft)
        memoDraftsByPlanID[draft.planID] = try await persistence.loadMemoDrafts(
            planID: draft.planID
        )
        memoDraftsLoadedPlanIDs.insert(draft.planID)
    }

    func commitMemoDraft(
        _ draft: SharedPlanMemoDraft,
        now: Date = Date()
    ) async throws -> Bool {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }

        // The durable draft row is the exact-once binding between the staged
        // text and its Automerge operation. A prior atomic commit removes this
        // exact generation. Treating its absence as an acknowledgement makes
        // a response-lost retry a no-op instead of authoring a duplicate memo
        // event after relaunch.
        let durableDrafts = try await persistence.loadMemoDrafts(planID: draft.planID)
        guard durableDrafts.contains(where: {
            $0.id == draft.id && $0.generation == draft.generation && $0 == draft
        }) else {
            memoDraftsByPlanID[draft.planID] = durableDrafts
            memoDraftsLoadedPlanIDs.insert(draft.planID)
            return false
        }

        let result = try await mutateDocumentWhileHoldingContentAuthority(
            planID: draft.planID,
            now: now,
            acknowledgingMemoDraft: draft,
            mutation: .replaceMemo(draft.text, circle: draft.circle)
        )
        if !result {
            guard let snapshot = documentSnapshots[draft.planID] else {
                throw SharedPlanError.persistenceFailed
            }
            try await persistence.saveMemoMutation(
                plan: try plan(id: draft.planID),
                document: snapshot,
                acknowledging: draft
            )
        }
        memoDraftsByPlanID[draft.planID] = durableDrafts.filter {
            !($0.id == draft.id && $0.generation == draft.generation)
        }
        memoDraftsLoadedPlanIDs.insert(draft.planID)
        return result
    }

    func memo(circle key: SharedPlanCircleKey, planID: String) async throws -> String {
        let document = try await document(for: planID)
        return try await document.memo(for: key) ?? ""
    }

    func circleContent(
        circle key: SharedPlanCircleKey,
        planID: String
    ) async throws -> SharedPlanCircleContent? {
        let document = try await document(for: planID)
        return try await document.circleContent(for: key)
    }

    func editorProjectionUpdates(planID: String) -> AsyncStream<UInt64> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            editorProjectionContinuations[planID, default: [:]][continuationID] = continuation
            continuation.yield(editorProjectionGenerations[planID] ?? 0)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeEditorProjectionContinuation(
                        planID: planID,
                        id: continuationID
                    )
                }
            }
        }
    }

    func editorProjection(planID: String) async throws -> SharedPlanEditorProjection {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        let generation = editorProjectionGenerations[planID] ?? 0
        return SharedPlanEditorProjection(
            generation: generation,
            snapshot: try await makeEditorSnapshotWhileHoldingAuthority(planID: planID)
        )
    }

    /// Produces one authority-consistent projection for the editor. Conflict
    /// paths are included even when their visible presence is removed, so the
    /// recovery UI never hides a branch that still needs an explicit choice.
    func editorSnapshot(planID: String) async throws -> SharedPlanEditorSnapshot {
        try await editorProjection(planID: planID).snapshot
    }

    private func makeEditorSnapshotWhileHoldingAuthority(
        planID: String
    ) async throws -> SharedPlanEditorSnapshot {
        let plan = try plan(id: planID)
        var durableSnapshot = documentSnapshots[planID]
        if durableSnapshot == nil {
            durableSnapshot = try await persistence.loadDocument(planID: planID)
        }
        if var snapshot = durableSnapshot {
            let normalizedLimit = Self.normalizedLocalEditLimit(
                snapshot.localEditLimit,
                pendingCount: snapshot.pendingOperationIDs.count
            )
            if normalizedLimit != snapshot.localEditLimit {
                snapshot = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: snapshot.syncIssue,
                    localEditLimit: normalizedLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: snapshot)
            }
            durableSnapshot = snapshot
            documentSnapshots[planID] = snapshot
            updateLocalEditLimit(planID: planID, snapshot: snapshot)
        }

        let usesRecoveryProjection = durableSnapshot.map {
            $0.syncIssue != nil
                || $0.localEditLimit != nil
                || $0.pendingOperationIDs.count
                    > SharedPlanAutomergeDocument.maximumUnacknowledgedOperations
        } ?? false
        let document: SharedPlanAutomergeDocument?
        if usesRecoveryProjection, let durableSnapshot {
            // A structurally valid branch may exceed a policy limit and still
            // needs an inspect/export surface. Never cache this relaxed reader:
            // mutation and transport admission continue through document(for:).
            document = recoveryProjectionDocument(
                from: durableSnapshot,
                matching: plan
            )
        } else {
            do {
                document = try await self.document(for: planID)
                durableSnapshot = documentSnapshots[planID]
            } catch {
                // document(for:) can discover a durable policy violation or
                // malformed retained branch and quarantine it before throwing.
                // The first editor load must immediately expose that retained
                // recovery state; requiring a second user-triggered load hides
                // the only safe export/discard path.
                guard let quarantined = documentSnapshots[planID],
                      quarantined.syncIssue != nil || quarantined.localEditLimit != nil
                else { throw error }
                durableSnapshot = quarantined
                updateLocalEditLimit(planID: planID, snapshot: quarantined)
                document = recoveryProjectionDocument(
                    from: quarantined,
                    matching: plan
                )
            }
        }
        let conflicts = try await document?.conflictInventory() ?? []
        var circleKeys = Set(plan.circleKeys)
        if let document {
            circleKeys.formUnion(try await document.circleKeys())
        }
        for conflict in conflicts {
            guard conflict.path.first == "circles",
                  conflict.path.count >= 2,
                  let wcID = Int(conflict.path[1]),
                  let key = SharedPlanCircleKey(comiketNo: plan.comiketNo, wcID: wcID)
            else { throw SharedPlanError.syncProtocolViolation }
            circleKeys.insert(key)
        }
        var circles: [SharedPlanCircleContent] = []
        for key in circleKeys.sorted(by: { $0.wcID < $1.wcID }) {
            if let content = try await document?.circleContent(for: key) {
                circles.append(content)
            }
        }
        let recovery = syncRecoveryDocument(planID: planID)
        let recoveryRebaseAvailable = recovery != nil
            && document != nil
            && durableSnapshot.map(Self.canRebaseRecoverySnapshot) == true
        if !memoDraftsLoadedPlanIDs.contains(planID) {
            memoDraftsByPlanID[planID] = try await persistence.loadMemoDrafts(planID: planID)
            memoDraftsLoadedPlanIDs.insert(planID)
        }
        return SharedPlanEditorSnapshot(
            plan: plan,
            replicaID: durableSnapshot?.replicaID,
            circles: circles,
            conflicts: conflicts,
            members: membersByPlanID[planID] ?? [],
            memoDrafts: memoDraftsByPlanID[planID] ?? [],
            syncStatus: syncStatuses[planID] ?? .idle,
            pendingOperationCount: durableSnapshot?.pendingOperationIDs.count ?? 0,
            localEditLimit: durableSnapshot?.localEditLimit,
            syncIssue: durableSnapshot?.syncIssue,
            recoveryDocument: recovery,
            recoveryRebaseAvailable: recoveryRebaseAvailable,
            permitsContentMutations: localEditLimits[planID] == nil
                && durableSnapshot?.syncIssue == nil
                && hasContentMutationAuthority(
                    planID: planID,
                    durableSnapshot: durableSnapshot
                )
        )
    }

    func circleParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        _ = try editablePlan(id: planID, ownerOnly: false)
        return try await document(for: planID).circleParentResolutionInventory(
            circle,
            selectedParentOperationID: selectedParentOperationID
        )
    }

    func needParentResolutionInventory(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID
    ) async throws -> SharedPlanParentResolutionInventory {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        _ = try editablePlan(id: planID, ownerOnly: false)
        return try await document(for: planID).needParentResolutionInventory(
            needID,
            circle: circle,
            selectedParentOperationID: selectedParentOperationID
        )
    }

    @discardableResult
    func setPurchaseNeed(
        _ need: SharedPlanPurchaseNeed,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setPurchaseNeed(need, circle: key)
        )
    }

    @discardableResult
    func createPurchaseNeed(
        _ need: SharedPlanPurchaseNeed,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .createNeed(need, circle: key)
        )
    }

    @discardableResult
    func deletePurchaseNeed(
        _ needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .deleteNeed(needID, circle: key)
        )
    }

    @discardableResult
    func setWantedQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setWantedQuantity(quantity, needID: needID, circle: key)
        )
    }

    @discardableResult
    func setBuyerAllocation(
        _ quantity: Int,
        buyerUserID: String,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            requiredActiveBuyerUserID: buyerUserID,
            mutation: .setBuyerAllocation(
                quantity,
                buyerUserID: buyerUserID,
                needID: needID,
                circle: key
            )
        )
    }

    @discardableResult
    func setFulfilledQuantity(
        _ quantity: Int,
        needID: UUID,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setFulfilledQuantity(quantity, needID: needID, circle: key)
        )
    }

    @discardableResult
    func setCommunication(
        _ value: SharedPlanJSONValue,
        field: String,
        circle key: SharedPlanCircleKey,
        planID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .setCommunication(value, key: field, circle: key)
        )
    }

    @discardableResult
    func resolveCircleParent(
        planID: String,
        circle: SharedPlanCircleKey,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .resolveCircleParent(
                circle: circle,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions
            )
        )
    }

    @discardableResult
    func resolveNeedParent(
        planID: String,
        circle: SharedPlanCircleKey,
        needID: UUID,
        selectedParentOperationID: UUID,
        state: SharedPlanPresenceState,
        nestedResolutions: [SharedPlanNestedConflictResolution],
        now: Date = Date()
    ) async throws -> Bool {
        try await mutateDocument(
            planID: planID,
            now: now,
            mutation: .resolveNeedParent(
                needID: needID,
                circle: circle,
                selectedParentOperationID: selectedParentOperationID,
                state: state,
                nestedResolutions: nestedResolutions
            )
        )
    }

    /// Resolves a scalar, presence, or removal/edit conflict only when the
    /// selected candidate is still present in the current durable inventory.
    /// Parent conflicts use their dedicated exhaustive resolver APIs.
    @discardableResult
    func resolveDocumentConflict(
        planID: String,
        conflictID: String,
        selectedChangeHash: String,
        now: Date = Date()
    ) async throws -> Bool {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        let plan = try editablePlan(id: planID, ownerOnly: false)
        let document = try await document(for: planID)
        let inventory = try await document.conflictInventory()
        guard let conflict = inventory.first(where: { $0.id == conflictID }),
              conflict.kind != .parent,
              let candidate = conflict.candidates.first(where: {
                  $0.changeHash == selectedChangeHash
              })
        else { throw SharedPlanError.syncProtocolViolation }
        let mutation = try await durableMutation(
            resolving: conflict,
            with: candidate,
            plan: plan,
            document: document
        )
        return try await mutateDocumentWhileHoldingContentAuthority(
            planID: planID,
            now: now,
            mutation: mutation
        )
    }

    var currentActorUserID: String? { actorUserID() }

    func permitsContentMutations(planID: String) -> Bool {
        localEditLimits[planID] == nil
            && documentSnapshots[planID]?.syncIssue == nil
            && hasContentMutationAuthority(
                planID: planID,
                durableSnapshot: documentSnapshots[planID]
            )
    }

    private func hasContentMutationAuthority(
        planID: String,
        durableSnapshot: SharedPlanDocumentSnapshot?
    ) -> Bool {
        if allowsUnconnectedContentMutations { return true }
        switch syncStatuses[planID] ?? .idle {
        case .connected(let mutationsEnabled, _),
             .synchronized(let mutationsEnabled, _):
            // A current server decision always wins over an older offline
            // lease, including while its durable revocation is being saved.
            return mutationsEnabled
        case .quarantined:
            return false
        case .idle, .connecting, .reconnecting:
            return durableSnapshot?.offlineMutationAuthority == true
        }
    }

    func localEditLimit(planID: String) -> SharedPlanLocalEditLimit? {
        localEditLimits[planID]
    }

    func activePlans(comiketNo: Int) -> [SharedPlan] {
        plans.filter { $0.comiketNo == comiketNo && $0.lifecycle == .active }
    }

    func plansContaining(_ key: SharedPlanCircleKey) -> [SharedPlan] {
        plans.filter { $0.lifecycle == .active && $0.circleKeys.contains(key) }
    }

    func hasPendingChanges(planID: String) -> Bool {
        pendingRESTWrites.contains { $0.planID == planID }
            || quarantinedRESTWrites.contains { $0.planID == planID }
            || documentSnapshots[planID]?.pendingOperationIDs.isEmpty == false
    }

    var recoveryDocuments: [SharedPlanRecoveryDocument] {
        let visiblePlanIDs = Set(plans.map(\.id))
        let orphanedSnapshotIDs = Set(documentSnapshots.values.compactMap { snapshot in
            let hasRecoveryState = snapshot.syncIssue != nil
                || snapshot.localEditLimit != nil
            let isOrphaned = !visiblePlanIDs.contains(snapshot.planID)
            return (hasRecoveryState || (isOrphaned && !snapshot.pendingOperationIDs.isEmpty))
                ? snapshot.planID
                : nil
        })
        let quarantinedIDs = Set(quarantinedRESTWrites.compactMap { write in
            !visiblePlanIDs.contains(write.planID) ? write.planID : nil
        })
        let currentRecoveries: [SharedPlanRecoveryDocument] = orphanedSnapshotIDs
            .union(quarantinedIDs)
            .compactMap {
            planID in
            let snapshot = documentSnapshots[planID]
            let intents = quarantinedRESTWrites.filter { $0.planID == planID }
            guard let export = Self.recoveryExport(snapshot: snapshot, intents: intents) else {
                return nil
            }
            return SharedPlanRecoveryDocument(
                planID: planID,
                pendingOperationCount: snapshot?.pendingOperationIDs.count ?? 0,
                metadataIntentCount: intents.count,
                exportText: export
            )
        }
        let archivedRecoveryDocuments: [SharedPlanRecoveryDocument] = archivedRecoveries.compactMap {
            recoveryID, recovery -> SharedPlanRecoveryDocument? in
            guard let export = Self.recoveryExport(
                snapshot: recovery.snapshot,
                intents: recovery.metadataIntents
            ) else {
                return nil
            }
            return SharedPlanRecoveryDocument(
                id: "archived-\(recoveryID.uuidString.lowercased())",
                planID: recovery.snapshot.planID,
                pendingOperationCount: recovery.snapshot.pendingOperationIDs.count,
                metadataIntentCount: recovery.metadataIntents.count,
                exportText: export
            )
        }
        return (currentRecoveries + archivedRecoveryDocuments).sorted {
            if $0.planID != $1.planID { return $0.planID < $1.planID }
            return $0.id < $1.id
        }
    }

    func syncRecoveryDocument(planID: String) -> SharedPlanRecoveryDocument? {
        guard let snapshot = documentSnapshots[planID],
              snapshot.syncIssue != nil || snapshot.localEditLimit != nil,
              let export = Self.recoveryExport(snapshot: snapshot, intents: [])
        else { return nil }
        return SharedPlanRecoveryDocument(
            planID: planID,
            pendingOperationCount: snapshot.pendingOperationIDs.count,
            metadataIntentCount: 0,
            exportText: export
        )
    }

    /// Explicitly discards a quarantined local content branch. Production
    /// documents are never bootstrap-replaced during ordinary reconnect; this
    /// path exists only behind a destructive user confirmation.
    func discardUnsyncedContentAndRebootstrap(planID: String) async throws {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        var shouldStartFreshCoordinator = false
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
            if shouldStartFreshCoordinator {
                Task { @MainActor [weak self] in
                    await self?.startSync(planID: planID)
                }
            }
        }
        guard durableStorageAvailable, actorUserID() != nil else {
            throw SharedPlanError.persistenceFailed
        }
        var plan = try plan(id: planID)
        guard let currentSnapshot = documentSnapshots[planID],
              (currentSnapshot.syncIssue.map(Self.canRebuildContent(after:)) == true
                || currentSnapshot.localEditLimit != nil)
        else { throw SharedPlanError.syncProtocolViolation }
        let rebuilt = try await serverBootstrapDocument(for: plan)
        plan.circleKeys = try await rebuilt.circleKeys()
        plan.updatedAt = Date()
        let snapshot = await rebuilt.snapshot(pendingOperationIDs: [])
        shouldStartFreshCoordinator = await detachSyncCoordinator(planID: planID)
        try await persistence.saveDiscardedContentRebootstrap(
            plan,
            document: snapshot,
            discardingMemoDraftReplicaID: currentSnapshot.replicaID
        )
        documents[planID] = rebuilt
        documentSnapshots[planID] = snapshot
        memoDraftsByPlanID[planID]?.removeAll {
            $0.replicaID == currentSnapshot.replicaID
        }
        memoDraftsLoadedPlanIDs.insert(planID)
        updateLocalEditLimit(planID: planID, snapshot: snapshot)
        upsert(plan)
    }

    /// Rebuilds a quarantined branch from the server's exact root and the
    /// immutable semantic-operation ledger. A redundant or no-longer-valid
    /// operation aborts the whole rebase and leaves the original exportable
    /// document untouched.
    func rebaseUnsyncedContent(planID: String, now: Date = Date()) async throws {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        var shouldStartFreshCoordinator = false
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
            if shouldStartFreshCoordinator {
                Task { @MainActor [weak self] in
                    await self?.startSync(planID: planID)
                }
            }
        }
        guard durableStorageAvailable, actorUserID() != nil else {
            throw SharedPlanError.persistenceFailed
        }
        var plan = try plan(id: planID)
        guard let existingSnapshot = documentSnapshots[planID],
              (existingSnapshot.syncIssue.map(Self.canRebuildContent(after:)) == true
                || existingSnapshot.localEditLimit != nil)
        else { throw SharedPlanError.syncProtocolViolation }
        let existing = try recoveryDocument(from: existingSnapshot, matching: plan)
        let rebuilt = try await serverBootstrapDocument(for: plan)
        let serverOperationIDs = await rebuilt.semanticOperationIDs()
        let remainingOperationIDs = existingSnapshot.pendingOperationIDs.filter {
            !serverOperationIDs.contains($0)
        }
        guard remainingOperationIDs.count
                <= SharedPlanAutomergeDocument.maximumUnacknowledgedOperations
        else {
            throw SharedPlanError.planSyncBacklogLimit(
                maximum: SharedPlanAutomergeDocument.maximumUnacknowledgedOperations,
                received: remainingOperationIDs.count
            )
        }
        let records = Dictionary(
            uniqueKeysWithValues: try await existing.operationRecords().map { ($0.id, $0) }
        )
        var remaining: [UUID] = []
        for operationID in remainingOperationIDs {
            guard let record = records[operationID] else {
                throw SharedPlanError.syncProtocolViolation
            }
            let mutation = try record.durableMutation(comiketNo: plan.comiketNo)
            let applied = try await rebuilt.applyRebasedMutation(
                mutation,
                operationID: operationID,
                actorUserID: record.actorUserID,
                authoredAt: now
            )
            guard applied else { throw SharedPlanError.syncProtocolViolation }
            remaining.append(operationID)
        }
        plan.circleKeys = try await rebuilt.circleKeys()
        plan.updatedAt = now
        let snapshot = await rebuilt.snapshot(
            pendingOperationIDs: remaining,
            localEditLimit: Self.normalizedLocalEditLimit(
                nil,
                pendingCount: remaining.count
            )
        )
        shouldStartFreshCoordinator = await detachSyncCoordinator(planID: planID)
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: nil
        )
        documents[planID] = rebuilt
        documentSnapshots[planID] = snapshot
        updateLocalEditLimit(planID: planID, snapshot: snapshot)
        upsert(plan)
    }

    func discardRecoveryDocument(planID: String) async throws {
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        guard !plans.contains(where: { $0.id == planID }),
              (documentSnapshots[planID] != nil
                || quarantinedRESTWrites.contains(where: { $0.planID == planID }))
        else { throw SharedPlanError.planNotFound }
        let writes = quarantinedRESTWrites.filter { $0.planID == planID }
        try await persistence.removePlan(id: planID)
        documentSnapshots[planID] = nil
        documents[planID] = nil
        quarantinedRESTWrites.removeAll { $0.planID == planID }
        pendingRESTWrites.removeAll { $0.planID == planID }
        for write in writes { restWriteIssues[write.id] = nil }
    }

    func discardRecoveryDocument(id: String) async throws {
        let prefix = "archived-"
        if id.hasPrefix(prefix),
           let recoveryID = UUID(uuidString: String(id.dropFirst(prefix.count))),
           archivedRecoveries[recoveryID] != nil
        {
            try await persistence.removeArchivedRecoveryDocument(id: recoveryID)
            archivedRecoveries[recoveryID] = nil
            return
        }
        try await discardRecoveryDocument(planID: id)
    }

    /// Explicit recovery for a revision conflict. Quarantined intents are
    /// never silently rebased because the request may have committed before a
    /// lost response. Discard is user-driven and leaves unrelated outbox work
    /// eligible to continue.
    func discardQuarantinedMetadataChanges(planID: String) async throws {
        let selectedWrites = quarantinedRESTWrites.filter {
            $0.planID == planID && $0.quarantineReason == .revisionConflict
        }
        guard !selectedWrites.isEmpty else { return }
        let selectedIDs = Set(selectedWrites.map(\.id))
        let observedGeneration = authorityOperationGeneration
        let fetchedPlan = try await authoritativePlan(id: planID)
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let writes = quarantinedRESTWrites.filter {
            selectedIDs.contains($0.id)
                && $0.planID == planID
                && $0.quarantineReason == .revisionConflict
        }
        guard !writes.isEmpty else { return }
        let currentPlan = try await revalidatedAuthorityPlan(
            id: planID,
            fetchedPlan: fetchedPlan,
            observedGeneration: observedGeneration
        )
        let ids = Set(writes.map(\.id))
        let reconciled = Self.applyingMetadataIntents(
            pendingRESTWrites.filter { $0.planID == planID },
            to: currentPlan
        )
        try await persistence.replaceQuarantinedRESTWrites(
            removing: ids,
            with: [],
            plan: reconciled
        )
        for write in writes { restWriteIssues[write.id] = nil }
        quarantinedRESTWrites.removeAll { ids.contains($0.id) }
        upsert(reconciled)
    }

    func retryQuarantinedMetadataChanges(planID: String, now: Date = Date()) async throws {
        let selected = quarantinedRESTWrites
            .filter { $0.planID == planID && $0.quarantineReason == .revisionConflict }
            .sorted(by: Self.writeOrder)
        guard !selected.isEmpty else { return }
        let selectedIDs = Set(selected.map(\.id))
        let observedGeneration = authorityOperationGeneration
        let fetchedPlan = try await authoritativePlan(id: planID)
        await acquireAuthorityOperation()
        defer { releaseAuthorityOperation() }
        let quarantined = quarantinedRESTWrites
            .filter {
                selectedIDs.contains($0.id)
                    && $0.planID == planID
                    && $0.quarantineReason == .revisionConflict
            }
            .sorted(by: Self.writeOrder)
        guard !quarantined.isEmpty else { return }
        let currentPlan = try await revalidatedAuthorityPlan(
            id: planID,
            fetchedPlan: fetchedPlan,
            observedGeneration: observedGeneration
        )
        let pending = quarantined.enumerated().map { index, write in
            SharedPlanRESTWrite(
                id: UUID(),
                planID: write.planID,
                kind: write.kind,
                baseRevision: currentPlan.revision,
                name: write.name,
                comiketNo: write.comiketNo,
                inviteToken: nil,
                targetUserID: write.targetUserID,
                invitationID: write.invitationID,
                expiresAt: write.expiresAt,
                createdAt: now.addingTimeInterval(Double(index) / 1_000)
            )
        }
        let optimistic = Self.applyingMetadataIntents(pending, to: currentPlan)
        let oldIDs = Set(quarantined.map(\.id))
        try await persistence.replaceQuarantinedRESTWrites(
            removing: oldIDs,
            with: pending,
            plan: optimistic
        )
        quarantinedRESTWrites.removeAll { oldIDs.contains($0.id) }
        for write in quarantined { restWriteIssues[write.id] = nil }
        pendingRESTWrites.append(contentsOf: pending)
        pendingRESTWrites.sort(by: Self.writeOrder)
        upsert(optimistic)
        scheduleOutboxDrain()
    }

    func quarantinedMetadataChanges(planID: String) -> [SharedPlanRESTWrite] {
        quarantinedRESTWrites.filter {
            $0.planID == planID && $0.quarantineReason == .revisionConflict
        }.sorted(by: Self.writeOrder)
    }

    func quarantinedChanges(planID: String) -> [SharedPlanRESTWrite] {
        quarantinedRESTWrites.filter { $0.planID == planID }.sorted(by: Self.writeOrder)
    }

    func discardQuarantinedWrite(id: UUID) async throws {
        guard let write = quarantinedRESTWrites.first(where: { $0.id == id }) else { return }
        if Self.isMetadataWrite(write.kind) {
            let observedGeneration = authorityOperationGeneration
            let fetchedPlan = try await authoritativePlan(id: write.planID)
            await acquireAuthorityOperation()
            defer { releaseAuthorityOperation() }
            guard quarantinedRESTWrites.contains(where: { $0.id == write.id }) else {
                return
            }
            let currentPlan = try await revalidatedAuthorityPlan(
                id: write.planID,
                fetchedPlan: fetchedPlan,
                observedGeneration: observedGeneration
            )
            let reconciled = Self.applyingMetadataIntents(
                pendingRESTWrites.filter { $0.planID == write.planID },
                to: currentPlan
            )
            try await persistence.replaceQuarantinedRESTWrites(
                removing: [write.id],
                with: [],
                plan: reconciled
            )
            quarantinedRESTWrites.removeAll { $0.id == write.id }
            restWriteIssues[write.id] = nil
            upsert(reconciled)
            return
        } else {
            try await persistence.removeRESTWrite(id: write.id)
        }
        quarantinedRESTWrites.removeAll { $0.id == write.id }
        restWriteIssues[write.id] = nil
        if write.kind == .acceptInvitation {
            try? await inviteCapabilityVault.remove(requestID: write.id)
        }
    }

    private func pendingOperationCount(planID: String, bindingID: UUID) -> Int {
        guard syncCoordinatorBindings[planID] == bindingID else { return 0 }
        return documentSnapshots[planID]?.pendingOperationIDs.count ?? 0
    }

    private func updateSyncStatus(
        _ status: SharedPlanSyncConnectionStatus,
        planID: String,
        bindingID: UUID
    ) async {
        guard syncCoordinatorBindings[planID] == bindingID else { return }
        syncStatuses[planID] = status
        let advertisedAuthority: Bool?
        switch status {
        case .connected(let mutationsEnabled, _),
             .synchronized(let mutationsEnabled, _):
            advertisedAuthority = mutationsEnabled
        default:
            advertisedAuthority = nil
        }
        guard let advertisedAuthority,
              documentSnapshots[planID]?.offlineMutationAuthority != advertisedAuthority
        else { return }

        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        guard syncCoordinatorBindings[planID] == bindingID,
              let plan = plans.first(where: { $0.id == planID }),
              let document = documents[planID],
              let current = documentSnapshots[planID],
              current.offlineMutationAuthority != advertisedAuthority
        else { return }

        await document.setOfflineMutationAuthority(advertisedAuthority)
        let updated = await document.snapshot(
            pendingOperationIDs: current.pendingOperationIDs,
            syncIssue: current.syncIssue,
            localEditLimit: current.localEditLimit
        )
        do {
            try await persistence.saveMutation(plan: plan, document: updated)
            documentSnapshots[planID] = updated
        } catch {
            await document.setOfflineMutationAuthority(current.offlineMutationAuthority)
            durableStorageAvailable = false
            issueMessage = error.localizedDescription
            syncStatuses[planID] = .quarantined(.unavailable(error.localizedDescription))
        }
    }

    private func generateSyncFrame(
        _ session: SharedPlanSyncSession,
        planID: String,
        bindingID: UUID
    ) async throws -> SharedPlanClientSyncFrame? {
        await acquireContentOperation()
        defer { releaseContentOperation() }
        guard syncCoordinatorBindings[planID] == bindingID else {
            throw CancellationError()
        }
        guard !isClearingUserData, actorUserID() != nil else {
            throw SharedPlanError.profileRequired
        }
        let pending = documentSnapshots[planID]?.pendingOperationIDs ?? []
        return try await session.nextOutboundFrame(pendingOperationIDs: pending)
    }

    private func receiveSyncFrame(
        _ frame: SharedPlanServerSyncFrame,
        session: SharedPlanSyncSession,
        planID: String,
        bindingID: UUID
    ) async throws -> Bool {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        guard syncCoordinatorBindings[planID] == bindingID else {
            throw CancellationError()
        }
        guard !isClearingUserData, actorUserID() != nil else {
            throw SharedPlanError.profileRequired
        }

        var currentPlan = try plan(id: planID)
        let document = try await self.document(for: planID)
        let currentSnapshot = documentSnapshots[planID]
        let pending = currentSnapshot?.pendingOperationIDs ?? []
        let issue = currentSnapshot?.syncIssue
        let localEditLimit = currentSnapshot?.localEditLimit
        let persistedAt = Date()
        var stagedPlan = currentPlan
        stagedPlan.updatedAt = persistedAt
        let persistedPlan = stagedPlan
        let applied = try await session.receiveServerFrame(
            frame,
            pendingOperationIDs: pending,
            syncIssue: issue,
            localEditLimit: localEditLimit
        ) { [persistence] snapshot, circleKeys in
            var plan = persistedPlan
            plan.circleKeys = circleKeys
            try await persistence.saveMutation(plan: plan, document: snapshot)
        }
        guard applied else { return false }

        let acknowledged = try await session.resolveDeferredAcknowledgements {
            [persistence] operationIDs in
            guard !operationIDs.isEmpty else { return }
            let remaining = pending.filter { !operationIDs.contains($0) }
            let remainingLocalEditLimit = Self.localEditLimit(
                afterAcknowledging: localEditLimit,
                remainingPendingCount: remaining.count
            )
            let snapshot = await document.snapshot(
                pendingOperationIDs: remaining,
                syncIssue: issue,
                localEditLimit: remainingLocalEditLimit
            )
            try await persistence.saveMutation(plan: persistedPlan, document: snapshot)
        }
        let remaining = pending.filter { !acknowledged.contains($0) }
        let remainingLocalEditLimit = Self.localEditLimit(
            afterAcknowledging: localEditLimit,
            remainingPendingCount: remaining.count
        )

        currentPlan.circleKeys = try await document.circleKeys()
        currentPlan.updatedAt = persistedAt
        documentSnapshots[planID] = await document.snapshot(
            pendingOperationIDs: remaining,
            syncIssue: issue,
            localEditLimit: remainingLocalEditLimit
        )
        updateLocalEditLimit(planID: planID, snapshot: documentSnapshots[planID])
        upsert(currentPlan)
        return true
    }

    private func receiveSyncAcknowledgement(
        _ acknowledgement: SharedPlanSyncAcknowledgement,
        session: SharedPlanSyncSession,
        planID: String,
        bindingID: UUID
    ) async throws -> Set<UUID> {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        guard syncCoordinatorBindings[planID] == bindingID else {
            throw CancellationError()
        }
        guard !isClearingUserData, actorUserID() != nil else {
            throw SharedPlanError.profileRequired
        }
        let currentPlan = try plan(id: planID)
        let document = try await self.document(for: planID)
        let currentSnapshot = documentSnapshots[planID]
        let pending = currentSnapshot?.pendingOperationIDs ?? []
        let issue = currentSnapshot?.syncIssue
        let localEditLimit = currentSnapshot?.localEditLimit

        let acknowledged = try await session.receiveAcknowledgement(
            acknowledgement
        ) { [persistence] operationIDs in
            let remaining = pending.filter { !operationIDs.contains($0) }
            let remainingLocalEditLimit = Self.localEditLimit(
                afterAcknowledging: localEditLimit,
                remainingPendingCount: remaining.count
            )
            let snapshot = await document.snapshot(
                pendingOperationIDs: remaining,
                syncIssue: issue,
                localEditLimit: remainingLocalEditLimit
            )
            try await persistence.saveMutation(plan: currentPlan, document: snapshot)
        }
        guard !acknowledged.isEmpty else { return [] }
        let remaining = pending.filter { !acknowledged.contains($0) }
        let remainingLocalEditLimit = Self.localEditLimit(
            afterAcknowledging: localEditLimit,
            remainingPendingCount: remaining.count
        )
        documentSnapshots[planID] = await document.snapshot(
            pendingOperationIDs: remaining,
            syncIssue: issue,
            localEditLimit: remainingLocalEditLimit
        )
        updateLocalEditLimit(planID: planID, snapshot: documentSnapshots[planID])
        return acknowledged
    }

    private func handleSyncError(
        _ error: SharedPlanSyncErrorFrame,
        planID: String,
        bindingID: UUID
    ) async -> SharedPlanSyncIssue? {
        guard syncCoordinatorBindings[planID] == bindingID else { return nil }
        let issue: SharedPlanSyncIssue?
        switch error.code {
        case "plan_compaction_required":
            issue = .serverCompactionRequired
        case "plan_sync_backlog_limit":
            issue = .backlogLimit(
                maximum: error.details?.maximumNewOperationsPerSyncFrame
                    ?? SharedPlanAutomergeDocument.maximumUnacknowledgedOperations,
                received: error.details?.receivedChanges
                    ?? pendingOperationCount(planID: planID, bindingID: bindingID)
            )
        case "membership_revoked", "plan_membership_required":
            issue = .membershipRevoked
        case "role_changed", "owner_required", "plan_archived":
            issue = .roleChanged
        default:
            issue = error.retryable ? nil : .unavailable(error.message)
        }
        guard let issue else { return nil }
        do {
            try await recordSyncIssue(
                issue,
                planID: planID,
                expectedSyncBindingID: bindingID
            )
        } catch {
            issueMessage = error.localizedDescription
        }
        return issue
    }

    func recordSyncIssue(
        _ issue: SharedPlanSyncIssue,
        planID: String,
        expectedSyncBindingID: UUID? = nil
    ) async throws {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        if let expectedSyncBindingID,
           syncCoordinatorBindings[planID] != expectedSyncBindingID
        {
            throw CancellationError()
        }
        var plan = try plan(id: planID)
        let document = try await document(for: planID)
        let pending = documentSnapshots[planID]?.pendingOperationIDs ?? []
        let localEditLimit = documentSnapshots[planID]?.localEditLimit
        let snapshot = await document.snapshot(
            pendingOperationIDs: pending,
            syncIssue: issue,
            localEditLimit: localEditLimit
        )
        plan.updatedAt = Date()
        try await persistence.saveMutation(plan: plan, document: snapshot)
        documentSnapshots[planID] = snapshot
        updateLocalEditLimit(planID: planID, snapshot: snapshot)
        upsert(plan)
    }

    func acknowledgeOperations(_ ids: Set<UUID>, planID: String) async throws {
        guard !ids.isEmpty else { return }
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        let plan = try plan(id: planID)
        let document = try await document(for: planID)
        let pending = (documentSnapshots[planID]?.pendingOperationIDs ?? [])
            .filter { !ids.contains($0) }
        let issue = documentSnapshots[planID]?.syncIssue
        let localEditLimit = Self.localEditLimit(
            afterAcknowledging: documentSnapshots[planID]?.localEditLimit,
            remainingPendingCount: pending.count
        )
        let snapshot = await document.snapshot(
            pendingOperationIDs: pending,
            syncIssue: issue,
            localEditLimit: localEditLimit
        )
        try await persistence.saveMutation(plan: plan, document: snapshot)
        documentSnapshots[planID] = snapshot
        updateLocalEditLimit(planID: planID, snapshot: snapshot)
    }

    func documentForSync(planID: String) async throws -> SharedPlanAutomergeDocument {
        try await document(for: planID)
    }

    private func durableMutation(
        resolving conflict: SharedPlanDocumentConflict,
        with candidate: SharedPlanConflictCandidate,
        plan: SharedPlan,
        document: SharedPlanAutomergeDocument
    ) async throws -> SharedPlanDurableMutation {
        let path = conflict.path
        guard path.first == "circles",
              path.count >= 3,
              let wcID = Int(path[1]),
              let circle = SharedPlanCircleKey(comiketNo: plan.comiketNo, wcID: wcID)
        else { throw SharedPlanError.syncProtocolViolation }

        if path == ["circles", String(wcID), "presence"] {
            return .setCirclePresence(
                circle,
                try Self.selectedPresenceState(candidate.value)
            )
        }

        if path.count == 5,
           path[2] == "needs",
           path[4] == "presence",
           let needID = UUID(uuidString: path[3]),
           path[3] == needID.uuidString.lowercased()
        {
            switch try Self.selectedPresenceState(candidate.value) {
            case .active:
                guard let need = try await document.purchaseNeed(
                    id: needID,
                    circleKey: circle
                ) else { throw SharedPlanError.syncProtocolViolation }
                return .createNeed(need, circle: circle)
            case .removed:
                return .deleteNeed(needID, circle: circle)
            }
        }

        guard conflict.kind == .scalar else {
            throw SharedPlanError.syncProtocolViolation
        }
        if path.count == 5,
           path[2] == "needs",
           let needID = UUID(uuidString: path[3]),
           path[3] == needID.uuidString.lowercased()
        {
            switch path[4] {
            case "wantedQuantity":
                guard let quantity = candidate.value.integerValue.flatMap(Int.init(exactly:))
                else { throw SharedPlanError.syncProtocolViolation }
                return .setWantedQuantity(quantity, needID: needID, circle: circle)
            case "fulfilledQuantity":
                guard let quantity = candidate.value.integerValue.flatMap(Int.init(exactly:))
                else { throw SharedPlanError.syncProtocolViolation }
                return .setFulfilledQuantity(quantity, needID: needID, circle: circle)
            default:
                break
            }
        }
        if path.count == 6,
           path[2] == "needs",
           path[4] == "buyerAllocations",
           let needID = UUID(uuidString: path[3]),
           path[3] == needID.uuidString.lowercased(),
           !path[5].isEmpty,
           let quantity = candidate.value.integerValue.flatMap(Int.init(exactly:))
        {
            return .setBuyerAllocation(
                quantity,
                buyerUserID: path[5],
                needID: needID,
                circle: circle
            )
        }
        if path.count == 4,
           path[2] == "communicationState",
           !path[3].isEmpty
        {
            return .setCommunication(candidate.value, key: path[3], circle: circle)
        }
        throw SharedPlanError.syncProtocolViolation
    }

    private static func selectedPresenceState(
        _ value: SharedPlanJSONValue
    ) throws -> SharedPlanPresenceState {
        let raw: String?
        switch value {
        case .string(let state):
            raw = state
        case .object(let fields):
            raw = fields["state"]?.stringValue
        default:
            raw = nil
        }
        guard let raw, let state = SharedPlanPresenceState(rawValue: raw) else {
            throw SharedPlanError.syncProtocolViolation
        }
        return state
    }

    private func mutateDocument(
        planID: String,
        now: Date,
        requiredActiveBuyerUserID: String? = nil,
        acknowledgingMemoDraft: SharedPlanMemoDraft? = nil,
        mutation: SharedPlanDurableMutation
    ) async throws -> Bool {
        await acquireAuthorityOperation()
        await acquireContentOperation()
        defer {
            releaseContentOperation()
            releaseAuthorityOperation()
        }
        return try await mutateDocumentWhileHoldingContentAuthority(
            planID: planID,
            now: now,
            requiredActiveBuyerUserID: requiredActiveBuyerUserID,
            acknowledgingMemoDraft: acknowledgingMemoDraft,
            mutation: mutation
        )
    }

    private func mutateDocumentWhileHoldingContentAuthority(
        planID: String,
        now: Date,
        requiredActiveBuyerUserID: String? = nil,
        acknowledgingMemoDraft: SharedPlanMemoDraft? = nil,
        mutation: SharedPlanDurableMutation
    ) async throws -> Bool {
        var plan = try editablePlan(id: planID, ownerOnly: false)
        if let requiredActiveBuyerUserID {
            guard allocationMemberAuthorityPlanIDs.contains(planID),
                  membersByPlanID[planID]?.contains(where: {
                      $0.userID == requiredActiveBuyerUserID
                          && $0.membershipStatus == .active
                  }) == true
            else { throw SharedPlanError.insufficientRole }
        }
        let legalPlanBeforeMutation = plan
        if let limit = localEditLimits[planID] {
            throw Self.error(for: limit)
        }
        if let issue = documentSnapshots[planID]?.syncIssue {
            throw Self.error(for: issue)
        }
        // A healthy document stays lazy across launch. Load its persisted
        // replica-bound offline authority before deciding whether a
        // disconnected edit is admissible.
        let document = try await document(for: planID)
        guard hasContentMutationAuthority(
            planID: planID,
            durableSnapshot: documentSnapshots[planID]
        )
        else {
            throw SharedPlanError.documentLimit(
                String(localized: "共同編集が有効になるまで内容は変更できません。")
            )
        }
        guard let userID = actorUserID() else { throw SharedPlanError.profileRequired }
        if let acknowledgingMemoDraft {
            guard acknowledgingMemoDraft.planID == planID,
                  acknowledgingMemoDraft.replicaID == documentSnapshots[planID]?.replicaID,
                  acknowledgingMemoDraft.circle.comiketNo == plan.comiketNo
            else { throw SharedPlanError.membershipRevoked }
        }
        if let issue = documentSnapshots[planID]?.syncIssue {
            throw Self.error(for: issue)
        }
        let operationID = UUID()
        var pending = documentSnapshots[planID]?.pendingOperationIDs ?? []
        pending.append(operationID)
        plan.updatedAt = now
        let basePlan = plan
        let result: SharedPlanDurableMutationResult
        do {
            guard let mutationResult = try await document.performDurableMutation(
                mutation,
                operationID: operationID,
                actorUserID: userID,
                authoredAt: now,
                pendingOperationIDs: pending,
                persist: { [persistence] snapshot, circleKeys in
                    var persistedPlan = basePlan
                    persistedPlan.circleKeys = circleKeys
                    if let acknowledgingMemoDraft {
                        try await persistence.saveMemoMutation(
                            plan: persistedPlan,
                            document: snapshot,
                            acknowledging: acknowledgingMemoDraft
                        )
                    } else {
                        try await persistence.saveMutation(
                            plan: persistedPlan,
                            document: snapshot
                        )
                    }
                }
            ) else { return false }
            result = mutationResult
        } catch SharedPlanError.planCompactionRequired {
            let legalPending = Array(pending.dropLast())
            let snapshot = await document.snapshot(
                pendingOperationIDs: legalPending,
                syncIssue: documentSnapshots[planID]?.syncIssue,
                localEditLimit: .compactionRequired
            )
            try await persistence.saveMutation(
                plan: legalPlanBeforeMutation,
                document: snapshot
            )
            documentSnapshots[planID] = snapshot
            updateLocalEditLimit(planID: planID, snapshot: snapshot)
            throw SharedPlanError.planCompactionRequired
        } catch SharedPlanError.planSyncBacklogLimit(let maximum, let received) {
            let legalPending = Array(pending.dropLast())
            let limit = SharedPlanLocalEditLimit.syncBacklog(
                maximum: maximum,
                pending: legalPending.count
            )
            let snapshot = await document.snapshot(
                pendingOperationIDs: legalPending,
                syncIssue: documentSnapshots[planID]?.syncIssue,
                localEditLimit: limit
            )
            try await persistence.saveMutation(
                plan: legalPlanBeforeMutation,
                document: snapshot
            )
            documentSnapshots[planID] = snapshot
            updateLocalEditLimit(planID: planID, snapshot: snapshot)
            throw SharedPlanError.planSyncBacklogLimit(
                maximum: maximum,
                received: received
            )
        }

        plan.circleKeys = result.circleKeys
        let snapshot = result.snapshot
        documentSnapshots[planID] = snapshot
        updateLocalEditLimit(planID: planID, snapshot: snapshot)
        upsert(plan)
        if let coordinator = syncCoordinators[planID] {
            Task { await coordinator.restartAfterDurableMutation() }
        }
        return true
    }

    private func document(for planID: String) async throws -> SharedPlanAutomergeDocument {
        if let document = documents[planID] { return document }
        let plan = try plan(id: planID)
        let document: SharedPlanAutomergeDocument
        if var snapshot = try await persistence.loadDocument(planID: planID) {
            // The persisted snapshot is the authority for this plan's local
            // membership generation. Different plans intentionally need not
            // share one replica/actor identity.
            let replicaID = snapshot.replicaID
            if snapshot.pendingOperationIDs.count
                > SharedPlanAutomergeDocument.maximumUnacknowledgedOperations
            {
                let issue = SharedPlanSyncIssue.backlogLimit(
                    maximum: SharedPlanAutomergeDocument.maximumUnacknowledgedOperations,
                    received: snapshot.pendingOperationIDs.count
                )
                let quarantined = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: issue,
                    localEditLimit: snapshot.localEditLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: quarantined)
                documentSnapshots[planID] = quarantined
                throw Self.error(for: issue)
            }
            do {
                document = try SharedPlanAutomergeDocument(
                    data: snapshot.document,
                    replicaID: replicaID,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
            } catch SharedPlanError.documentLimit {
                let quarantined = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: .compactionRequired,
                    localEditLimit: snapshot.localEditLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: quarantined)
                documentSnapshots[planID] = quarantined
                throw SharedPlanError.planCompactionRequired
            } catch {
                let issue = SharedPlanSyncIssue.unavailable(
                    String(localized: "端末に保存された共同編集データを安全に読み込めません。")
                )
                let quarantined = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: issue,
                    localEditLimit: snapshot.localEditLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: quarantined)
                documentSnapshots[planID] = quarantined
                throw Self.error(for: issue)
            }
            guard document.planID == plan.id, document.comiketNo == plan.comiketNo else {
                let issue = SharedPlanSyncIssue.unavailable(
                    String(localized: "保存されたプランが現在のプランと一致しません。")
                )
                let quarantined = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: issue,
                    localEditLimit: snapshot.localEditLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: quarantined)
                documentSnapshots[planID] = quarantined
                throw Self.error(for: issue)
            }
            let normalizedLimit = Self.normalizedLocalEditLimit(
                snapshot.localEditLimit,
                pendingCount: snapshot.pendingOperationIDs.count
            )
            if normalizedLimit != snapshot.localEditLimit {
                snapshot = SharedPlanDocumentSnapshot(
                    planID: snapshot.planID,
                    replicaID: snapshot.replicaID,
                    actorID: snapshot.actorID,
                    document: snapshot.document,
                    pendingOperationIDs: snapshot.pendingOperationIDs,
                    syncIssue: snapshot.syncIssue,
                    localEditLimit: normalizedLimit,
                    offlineMutationAuthority: snapshot.offlineMutationAuthority
                )
                try await persistence.saveMutation(plan: plan, document: snapshot)
            }
            documentSnapshots[planID] = snapshot
            updateLocalEditLimit(planID: planID, snapshot: snapshot)
        } else {
            let replicaID = UUID()
            let bootstrap = try await remote.fetchSyncBootstrap(planID: planID)
            document = try await validatedBootstrapDocument(
                bootstrap,
                for: plan,
                replicaID: replicaID
            )
            let snapshot = await document.snapshot(pendingOperationIDs: [])
            try await persistence.saveBootstrappedPlan(
                plan,
                document: snapshot,
                removingWriteID: nil
            )
            documentSnapshots[planID] = snapshot
            updateLocalEditLimit(planID: planID, snapshot: snapshot)
        }
        documents[planID] = document
        return document
    }

    /// Decodes a retained branch for explicit inspection/rebase only. Policy
    /// overflow is permitted so the user can recover legal structure, while
    /// the hard saved-document, circle, operation, schema, and provenance
    /// bounds remain enforced by SharedPlanAutomergeDocument.
    private func retainedDocument(
        from snapshot: SharedPlanDocumentSnapshot,
        matching plan: SharedPlan,
        allowingPolicyLimitOverflow: Bool
    ) throws -> SharedPlanAutomergeDocument {
        guard snapshot.planID == plan.id else {
            throw SharedPlanError.syncProtocolViolation
        }
        let document = try SharedPlanAutomergeDocument(
            data: snapshot.document,
            replicaID: snapshot.replicaID,
            allowingPolicyLimitOverflow: allowingPolicyLimitOverflow,
            offlineMutationAuthority: snapshot.offlineMutationAuthority
        )
        guard document.planID == plan.id, document.comiketNo == plan.comiketNo else {
            throw SharedPlanError.syncProtocolViolation
        }
        return document
    }

    private func recoveryDocument(
        from snapshot: SharedPlanDocumentSnapshot,
        matching plan: SharedPlan
    ) throws -> SharedPlanAutomergeDocument {
        try retainedDocument(
            from: snapshot,
            matching: plan,
            allowingPolicyLimitOverflow: true
        )
    }

    /// `.unavailable` is also used for malformed retained bytes. Never relax
    /// policy validation for that state: a standard decode may still project a
    /// valid branch carrying a non-document availability issue, while malformed
    /// bytes remain opaque and discard-only.
    private func recoveryProjectionDocument(
        from snapshot: SharedPlanDocumentSnapshot,
        matching plan: SharedPlan
    ) -> SharedPlanAutomergeDocument? {
        if case .unavailable = snapshot.syncIssue {
            return try? retainedDocument(
                from: snapshot,
                matching: plan,
                allowingPolicyLimitOverflow: false
            )
        }
        return try? recoveryDocument(from: snapshot, matching: plan)
    }

    /// A coordinator owns a session that is permanently bound to one document
    /// actor. Replacing the document must first fence and stop that session;
    /// ordinary mutations of the same actor use restartAfterDurableMutation.
    @discardableResult
    private func detachSyncCoordinator(planID: String) async -> Bool {
        syncCoordinatorBindings[planID] = nil
        guard let coordinator = syncCoordinators.removeValue(forKey: planID) else {
            return false
        }
        await coordinator.stop()
        syncStatuses[planID] = .idle
        return true
    }

    private func serverBootstrapDocument(
        for plan: SharedPlan
    ) async throws -> SharedPlanAutomergeDocument {
        let bootstrap = try await remote.fetchSyncBootstrap(planID: plan.id)
        let storedSnapshot = try await persistence.loadDocument(planID: plan.id)
        let replicaID = documentSnapshots[plan.id]?.replicaID
            ?? storedSnapshot?.replicaID
            ?? UUID()
        return try await validatedBootstrapDocument(
            bootstrap,
            for: plan,
            replicaID: replicaID
        )
    }

    private func validatedBootstrapDocument(
        _ bootstrap: SharedPlanSyncBootstrap,
        for plan: SharedPlan,
        replicaID: UUID
    ) async throws -> SharedPlanAutomergeDocument {
        guard bootstrap.v == 1,
              let bytes = Data(base64URLString: bootstrap.document),
              !bootstrap.heads.isEmpty,
              Set(bootstrap.heads).count == bootstrap.heads.count,
              bootstrap.heads.allSatisfy(Self.isCanonicalChangeHash)
        else { throw SharedPlanError.persistenceFailed }
        let document = try SharedPlanAutomergeDocument(data: bytes, replicaID: replicaID)
        let actualHeads = await document.heads()
        guard document.planID == plan.id,
              document.comiketNo == plan.comiketNo,
              Set(actualHeads) == Set(bootstrap.heads)
        else { throw SharedPlanError.persistenceFailed }
        return document
    }

    private static func isCanonicalChangeHash(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private static func canRebuildContent(after issue: SharedPlanSyncIssue) -> Bool {
        switch issue {
        case .compactionRequired, .serverCompactionRequired, .backlogLimit, .unavailable:
            true
        case .membershipRevoked, .roleChanged, .conflict:
            false
        }
    }

    private static func canRebaseRecoverySnapshot(
        _ snapshot: SharedPlanDocumentSnapshot
    ) -> Bool {
        if snapshot.localEditLimit != nil { return true }
        return snapshot.syncIssue.map(canRebuildContent(after:)) == true
    }

    private func editablePlan(
        id: String,
        ownerOnly: Bool,
        allowArchived: Bool = false
    ) throws -> SharedPlan {
        let plan = try accessiblePlan(id: id, allowArchived: allowArchived)
        if quarantinedRESTWrites.contains(where: {
            $0.planID == id && Self.blocksPlanEditing($0)
        }) {
            throw SharedPlanError.revisionConflict
        }
        guard !ownerOnly || plan.role == .owner else { throw SharedPlanError.insufficientRole }
        return plan
    }

    private func accessiblePlan(
        id: String,
        allowArchived: Bool
    ) throws -> SharedPlan {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        let plan = try plan(id: id)
        if documentSnapshots[id]?.syncIssue == .membershipRevoked {
            throw SharedPlanError.membershipRevoked
        }
        guard [.owner, .editor].contains(plan.role) else {
            throw SharedPlanError.insufficientRole
        }
        guard allowArchived || plan.lifecycle == .active else {
            throw SharedPlanError.insufficientRole
        }
        return plan
    }

    private func memberVisiblePlan(
        id: String,
        allowArchived: Bool
    ) throws -> SharedPlan {
        guard durableStorageAvailable else { throw SharedPlanError.persistenceFailed }
        guard actorUserID() != nil else { throw SharedPlanError.profileRequired }
        let plan = try plan(id: id)
        if documentSnapshots[id]?.syncIssue == .membershipRevoked {
            throw SharedPlanError.membershipRevoked
        }
        guard allowArchived || plan.lifecycle == .active else {
            throw SharedPlanError.insufficientRole
        }
        return plan
    }

    private func plan(id: String) throws -> SharedPlan {
        guard let plan = plans.first(where: { $0.id == id }) else {
            throw SharedPlanError.planNotFound
        }
        return plan
    }

    private func upsert(_ plan: SharedPlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        } else {
            plans.append(plan)
        }
        plans.sort(by: Self.planOrder)
    }

    private func publishEditorProjectionChanges(for planIDs: Set<String>) {
        for planID in planIDs where Self.isCanonicalUUIDString(planID) {
            let generation = (editorProjectionGenerations[planID] ?? 0) &+ 1
            editorProjectionGenerations[planID] = generation
            if let continuations = editorProjectionContinuations[planID] {
                for continuation in continuations.values {
                    continuation.yield(generation)
                }
            }
        }
    }

    private func removeEditorProjectionContinuation(planID: String, id: UUID) {
        editorProjectionContinuations[planID]?[id] = nil
        if editorProjectionContinuations[planID]?.isEmpty == true {
            editorProjectionContinuations[planID] = nil
        }
    }

    private static func planOrder(_ lhs: SharedPlan, _ rhs: SharedPlan) -> Bool {
        if lhs.lifecycle != rhs.lifecycle { return lhs.lifecycle == .active }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func completePendingCreate(_ write: SharedPlanRESTWrite) async throws -> SharedPlan {
        guard write.kind == .create,
              let name = write.name,
              let comiketNo = write.comiketNo
        else { throw SharedPlanError.persistenceFailed }
        let result = try await remote.createPlan(
            requestID: write.id,
            name: name,
            comiketNo: comiketNo
        )
        try validateReceipt(result.receipt, for: write)
        let plan = result.plan
        // The receipt proves the immutable creation outcome. The returned
        // resource is current state and may already be archived/transferred
        // when a response-loss retry is replayed.
        guard plan.comiketNo == comiketNo,
              plan.revision >= result.receipt.resultRevision
        else {
            throw SharedPlanError.persistenceFailed
        }
        guard let bootstrap = result.syncBootstrap else {
            throw SharedPlanError.persistenceFailed
        }
        let replicaID = UUID()
        let document = try await validatedBootstrapDocument(
            bootstrap,
            for: plan,
            replicaID: replicaID
        )
        let snapshot = await document.snapshot(pendingOperationIDs: [])
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: write.id
        )
        pendingRESTWrites.removeAll { $0.id == write.id }
        documents[plan.id] = document
        documentSnapshots[plan.id] = snapshot
        upsert(plan)
        return plan
    }

    private func acknowledgeMetadataWrite(
        _ write: SharedPlanRESTWrite,
        result: SharedPlanMutationResult
    ) async throws {
        try validateReceipt(result.receipt, for: write)
        let remotePlan = result.plan
        guard remotePlan.id == write.planID,
              remotePlan.revision >= result.receipt.resultRevision
        else { throw SharedPlanError.persistenceFailed }
        let remaining = pendingRESTWrites.filter { $0.id != write.id }
        let rebased = remaining.map { candidate in
            guard candidate.planID == write.planID,
                  Self.isMetadataWrite(candidate.kind)
            else { return candidate }
            // These entries are later in the ordered outbox and have never
            // been sent. Rebinding their payload to the acknowledged revision
            // is therefore compatible with requestId + payload binding.
            return candidate.rebased(to: remotePlan.revision)
        }
        var reconciled = remotePlan
        reconciled.circleKeys = plans.first(where: { $0.id == remotePlan.id })?.circleKeys ?? []
        reconciled = Self.applyingMetadataIntents(
            rebased.filter { $0.planID == remotePlan.id },
            to: reconciled
        )
        try await persistence.saveAcknowledgedPlan(
            reconciled,
            removingWriteID: write.id,
            rebasedWrites: rebased.filter { $0.planID == write.planID }
        )
        pendingRESTWrites = rebased
        upsert(reconciled)
    }

    private func acknowledgeCreatedInvitation(
        _ write: SharedPlanRESTWrite,
        result: SharedPlanCreatedInvitation
    ) async throws {
        _ = advanceInvitationCollectionGeneration(planID: write.planID)
        try validateCreatedInvitation(result, for: write)
        guard let currentPlan = plans.first(where: { $0.id == write.planID }) else {
            throw SharedPlanError.persistenceFailed
        }
        let remaining = pendingRESTWrites.filter { $0.id != write.id }
        let acknowledgedRevision = max(
            currentPlan.revision,
            result.receipt.resultRevision
        )
        let rebased = remaining.map { candidate in
            guard candidate.planID == write.planID,
                  Self.isMetadataWrite(candidate.kind)
            else { return candidate }
            return candidate.rebased(to: acknowledgedRevision)
        }
        var reconciled = currentPlan
        reconciled.revision = acknowledgedRevision
        reconciled.updatedAt = max(reconciled.updatedAt, write.createdAt)
        reconciled = Self.applyingMetadataIntents(
            rebased.filter { $0.planID == write.planID },
            to: reconciled
        )
        try await persistence.saveAcknowledgedPlan(
            reconciled,
            removingWriteID: write.id,
            rebasedWrites: rebased.filter { $0.planID == write.planID }
        )
        pendingRESTWrites = rebased
        upsert(reconciled)
        invitationNextCursorByPlanID[write.planID] = nil
        if let creator = actorUserID(), Self.isPublicUserID(creator) {
            let invitation = SharedPlanInvitation(
                invitationID: result.invitationID,
                createdByUserID: creator,
                currentUserCanRevoke: true,
                expiresAt: result.expiresAt,
                revokedAt: nil,
                createdAt: write.createdAt
            )
            invitationsByPlanID[write.planID] = Self.mergingInvitations(
                invitationsByPlanID[write.planID] ?? [],
                [invitation]
            )
        }
    }

    private func validateCreatedInvitation(
        _ result: SharedPlanCreatedInvitation,
        for write: SharedPlanRESTWrite
    ) throws {
        try validateReceipt(result.receipt, for: write)
        guard Self.isStructurallyValidCreatedInvitation(result),
              result.requestID == write.id,
              result.planID == write.planID,
              result.expiresAt == write.expiresAt
        else { throw SharedPlanError.persistenceFailed }
    }

    private func refreshMembersAfterMutation(planID: String) async {
        allocationMemberAuthorityPlanIDs.remove(planID)
        // The mutation receipt has no member resource. Discard any pre-write
        // projection before awaiting the authoritative page so a lost-response
        // replay cannot synthesize a state that an inverse mutation superseded.
        let generation = advanceMemberCollectionGeneration(planID: planID)
        membersByPlanID[planID] = nil
        memberNextCursorByPlanID[planID] = nil
        do {
            let page = try await remote.fetchMembers(
                planID: planID,
                limit: 50,
                cursor: nil
            )
            guard memberCollectionGenerations[planID] == generation else { return }
            membersByPlanID[planID] = page.items
            memberNextCursorByPlanID[planID] = page.nextCursor
        } catch {
            issueMessage = error.localizedDescription
        }
    }

    private func advanceMemberCollectionGeneration(planID: String) -> UInt64 {
        let generation = (memberCollectionGenerations[planID] ?? 0) &+ 1
        memberCollectionGenerations[planID] = generation
        return generation
    }

    private func advanceInvitationCollectionGeneration(planID: String) -> UInt64 {
        let generation = (invitationCollectionGenerations[planID] ?? 0) &+ 1
        invitationCollectionGenerations[planID] = generation
        return generation
    }

    private func invalidateCollectionRequests() {
        notificationCollectionGeneration &+= 1
        memberCollectionGenerations = memberCollectionGenerations.mapValues { $0 &+ 1 }
        invitationCollectionGenerations = invitationCollectionGenerations.mapValues { $0 &+ 1 }
    }

    private func validateReceipt(
        _ receipt: SharedPlanMutationReceipt,
        for write: SharedPlanRESTWrite
    ) throws {
        guard receipt.requestID == write.id else {
            throw SharedPlanError.persistenceFailed
        }
        switch write.kind {
        case .create, .acceptInvitation:
            guard receipt.resultStatus == .active else {
                throw SharedPlanError.persistenceFailed
            }
        case .archive:
            guard let baseRevision = write.baseRevision,
                  receipt.resultRevision == baseRevision + 1,
                  receipt.resultStatus == .archived
            else { throw SharedPlanError.persistenceFailed }
        case .rename, .reopen,
             .revokeMember, .reinstateMember, .transferOwnership,
             .createInvitation, .revokeInvitation:
            guard let baseRevision = write.baseRevision,
                  receipt.resultRevision == baseRevision + 1,
                  receipt.resultStatus == .active
            else { throw SharedPlanError.persistenceFailed }
        }
    }

    private func scheduleOutboxDrain() {
        guard automaticallySchedulesOutboxDrain else { return }
        Task { @MainActor [weak self] in
            await self?.drainRESTOutbox()
        }
    }

    private func scheduleNotificationReadDrain() {
        Task { @MainActor [weak self] in
            await self?.drainNotificationReadOutbox()
        }
    }

    #if DEBUG
    func authorityOperationWaiterCountForTesting() -> Int {
        authorityOperationWaiters.count
    }
    #endif

    private func acquireAuthorityOperation() async {
        guard authorityOperationIsActive else {
            authorityOperationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            authorityOperationWaiters.append(continuation)
        }
    }

    private func releaseAuthorityOperation() {
        authorityOperationGeneration &+= 1
        guard !authorityOperationWaiters.isEmpty else {
            authorityOperationIsActive = false
            return
        }
        let continuation = authorityOperationWaiters.removeFirst()
        continuation.resume()
    }

    private func revalidatedAuthorityPlan(
        id: String,
        fetchedPlan: SharedPlan,
        observedGeneration: UInt64
    ) async throws -> SharedPlan {
        guard authorityOperationGeneration != observedGeneration else {
            return fetchedPlan
        }
        return try await authoritativePlan(id: id)
    }

    private func acquireContentOperation() async {
        guard contentOperationIsActive else {
            contentOperationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            contentOperationWaiters.append(continuation)
        }
    }

    private func releaseContentOperation() {
        guard !contentOperationWaiters.isEmpty else {
            contentOperationIsActive = false
            return
        }
        let continuation = contentOperationWaiters.removeFirst()
        continuation.resume()
    }

    private static func error(for issue: SharedPlanSyncIssue) -> SharedPlanError {
        switch issue {
        case .membershipRevoked: .membershipRevoked
        case .roleChanged: .insufficientRole
        case .compactionRequired, .serverCompactionRequired:
            .planCompactionRequired
        case .backlogLimit(let maximum, let received):
            .planSyncBacklogLimit(maximum: maximum, received: received)
        case .conflict: .revisionConflict
        case .unavailable(let message): .documentLimit(message)
        }
    }

    private static func error(for limit: SharedPlanLocalEditLimit) -> SharedPlanError {
        switch limit {
        case .compactionRequired:
            .planCompactionRequired
        case .syncBacklog(let maximum, let pending):
            .planSyncBacklogLimit(maximum: maximum, received: pending + 1)
        }
    }

    private static func permitsSync(_ issue: SharedPlanSyncIssue?) -> Bool {
        switch issue {
        case nil:
            true
        case .membershipRevoked, .roleChanged, .conflict, .unavailable,
             .compactionRequired, .serverCompactionRequired, .backlogLimit:
            false
        }
    }

    nonisolated private static func normalizedLocalEditLimit(
        _ limit: SharedPlanLocalEditLimit?,
        pendingCount: Int
    ) -> SharedPlanLocalEditLimit? {
        switch limit {
        case .compactionRequired:
            .compactionRequired
        case .syncBacklog(let maximum, _):
            pendingCount >= maximum
                ? .syncBacklog(maximum: maximum, pending: pendingCount)
                : nil
        case nil:
            pendingCount >= SharedPlanAutomergeDocument.maximumUnacknowledgedOperations
                ? .syncBacklog(
                    maximum: SharedPlanAutomergeDocument.maximumUnacknowledgedOperations,
                    pending: pendingCount
                )
                : nil
        }
    }

    nonisolated private static func localEditLimit(
        afterAcknowledging limit: SharedPlanLocalEditLimit?,
        remainingPendingCount: Int
    ) -> SharedPlanLocalEditLimit? {
        normalizedLocalEditLimit(limit, pendingCount: remainingPendingCount)
    }

    private func updateLocalEditLimit(
        planID: String,
        snapshot: SharedPlanDocumentSnapshot?
    ) {
        guard let snapshot else {
            localEditLimits[planID] = nil
            return
        }
        localEditLimits[planID] = snapshot.localEditLimit
    }

    private func scheduleTransientOutboxRetry() {
        guard outboxRetryTask == nil, !pendingRESTWrites.isEmpty, !isClearingUserData else {
            return
        }
        let seconds = min(60, 1 << min(outboxRetryAttempt, 5))
        outboxRetryAttempt += 1
        outboxRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.outboxRetryTask = nil
            await self.drainRESTOutbox()
        }
    }

    private func scheduleNotificationReadRetry() {
        guard notificationReadRetryTask == nil,
              !notificationReadQueue.isEmpty,
              !isClearingUserData
        else { return }
        let seconds = min(60, 1 << min(notificationReadRetryAttempt, 5))
        notificationReadRetryAttempt += 1
        notificationReadRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.notificationReadRetryTask = nil
            await self.drainNotificationReadOutbox()
        }
    }

    private func bootstrapAcceptedPlan(
        _ plan: SharedPlan,
        removing write: SharedPlanRESTWrite
    ) async throws {
        let bootstrap = try await remote.fetchSyncBootstrap(planID: plan.id)
        let replicaID = UUID()
        let document = try await validatedBootstrapDocument(
            bootstrap,
            for: plan,
            replicaID: replicaID
        )
        let snapshot = await document.snapshot(pendingOperationIDs: [])
        try await persistence.saveBootstrappedPlan(
            plan,
            document: snapshot,
            removingWriteID: write.id
        )
        pendingRESTWrites.removeAll { $0.id == write.id }
        documents[plan.id] = document
        documentSnapshots[plan.id] = snapshot
        upsert(plan)
        do {
            try await inviteCapabilityVault.remove(requestID: write.id)
        } catch {
            issueMessage = SharedPlanError.persistenceFailed.localizedDescription
        }
    }

    private static func merged(
        remote: [SharedPlan],
        local: [SharedPlan],
        pendingWrites: [SharedPlanRESTWrite]
    ) -> [SharedPlan] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var byID: [String: SharedPlan] = [:]
        for var plan in remote {
            if let cached = localByID[plan.id] {
                plan.circleKeys = cached.circleKeys
            }
            byID[plan.id] = applyingMetadataIntents(
                pendingWrites.filter { $0.planID == plan.id },
                to: plan
            )
        }
        return byID.values.sorted(by: planOrder)
    }

    private func quarantineRevisionConflict(
        startingWith write: SharedPlanRESTWrite,
        currentRevision: Int?,
        currentPlan: SharedPlan?
    ) async throws {
        let affected = pendingRESTWrites.filter { candidate in
            candidate.planID == write.planID && Self.isMetadataWrite(candidate.kind)
        }.map {
            $0.quarantined(for: .revisionConflict, currentRevision: currentRevision)
        }
        guard !affected.isEmpty else { return }
        var authoritativePlan = currentPlan
        if var remotePlan = authoritativePlan {
            guard remotePlan.id == write.planID else {
                throw SharedPlanError.persistenceFailed
            }
            remotePlan.circleKeys = plans.first(where: { $0.id == write.planID })?.circleKeys ?? []
            authoritativePlan = remotePlan
        }
        try await persistence.saveQuarantinedRESTWrites(
            affected,
            currentPlan: authoritativePlan
        )
        let affectedIDs = Set(affected.map(\.id))
        pendingRESTWrites.removeAll { affectedIDs.contains($0.id) }
        quarantinedRESTWrites = Self.mergingQuarantinedWrites(
            quarantinedRESTWrites,
            affected
        )
        for affectedWrite in affected {
            restWriteIssues[affectedWrite.id] = Self.issueMessage(for: affectedWrite)
        }
        if let authoritativePlan { upsert(authoritativePlan) }
    }

    private func quarantineTerminalFailure(
        _ write: SharedPlanRESTWrite,
        error: CominaviServiceError
    ) async throws {
        let code: String
        let message: String
        let status: Int
        switch error {
        case .server(let value, let detail, let httpStatus):
            code = value
            message = detail
            status = httpStatus
        case .planOwnerRequired(let value, let detail):
            code = value
            message = detail
            status = 403
        case .invitationTokenAlreadyReturned(let detail, _):
            code = "invitation_token_already_returned"
            message = detail
            status = 409
        default:
            throw SharedPlanError.persistenceFailed
        }
        let candidates: [SharedPlanRESTWrite]
        if Self.isMetadataWrite(write.kind) {
            candidates = pendingRESTWrites.filter {
                $0.planID == write.planID && Self.isMetadataWrite($0.kind)
            }
        } else {
            candidates = [write]
        }
        let fetchedPlans: [SharedPlan]?
        if Self.isMetadataWrite(write.kind) {
            fetchedPlans = try? await remote.fetchPlans()
        } else {
            fetchedPlans = nil
        }
        let currentPlan = fetchedPlans?.first(where: { $0.id == write.planID })
        let quarantineReason: SharedPlanRESTWriteQuarantineReason =
            status == 404 && currentPlan == nil ? .membershipRevoked : .terminalFailure
        let lostInvitationID: String?
        if case .invitationTokenAlreadyReturned(_, let invitationID) = error {
            lostInvitationID = invitationID
        } else {
            lostInvitationID = nil
        }
        let quarantined = candidates.map { candidate in
            let normalized: SharedPlanRESTWrite
            if candidate.id == write.id, let lostInvitationID {
                normalized = candidate.recordingInvitationID(lostInvitationID)
            } else {
                normalized = candidate
            }
            return normalized.quarantined(
                for: quarantineReason,
                code: code,
                message: message
            )
        }
        if quarantineReason == .membershipRevoked {
            let visiblePlans = plans.filter { $0.id != write.planID }
            // Remove authority in memory before any fallible recovery I/O.
            plans = visiblePlans
            do {
                let existing: SharedPlanDocumentSnapshot?
                if let loaded = documentSnapshots[write.planID] {
                    existing = loaded
                } else {
                    existing = try await persistence.loadDocument(planID: write.planID)
                }
                let recovery = existing.map {
                    SharedPlanDocumentSnapshot(
                        planID: $0.planID,
                        replicaID: $0.replicaID,
                        actorID: $0.actorID,
                        document: $0.document,
                        pendingOperationIDs: $0.pendingOperationIDs,
                        syncIssue: .membershipRevoked,
                        localEditLimit: $0.localEditLimit,
                        offlineMutationAuthority: $0.offlineMutationAuthority
                    )
                }
                try await persistence.reconcileCachedPlans(
                    visiblePlans,
                    quarantinedWrites: quarantined,
                    recoveryDocuments: recovery.map { [$0] } ?? []
                )
                if let recovery { documentSnapshots[write.planID] = recovery }
            } catch {
                durableStorageAvailable = false
                throw error
            }
        } else {
            var authoritative = currentPlan
            if var plan = authoritative {
                plan.circleKeys = plans.first(where: { $0.id == write.planID })?.circleKeys ?? []
                authoritative = plan
            }
            try await persistence.saveQuarantinedRESTWrites(
                quarantined,
                currentPlan: authoritative
            )
            if let authoritative { upsert(authoritative) }
        }
        let ids = Set(quarantined.map(\.id))
        pendingRESTWrites.removeAll { ids.contains($0.id) }
        quarantinedRESTWrites = Self.mergingQuarantinedWrites(
            quarantinedRESTWrites,
            quarantined
        )
        for quarantinedWrite in quarantined {
            restWriteIssues[quarantinedWrite.id] = Self.issueMessage(for: quarantinedWrite)
        }
    }

    private static func mergingQuarantinedWrites(
        _ existing: [SharedPlanRESTWrite],
        _ incoming: [SharedPlanRESTWrite]
    ) -> [SharedPlanRESTWrite] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for write in incoming { byID[write.id] = write }
        return byID.values.sorted(by: writeOrder)
    }

    private static func issueMessage(for write: SharedPlanRESTWrite) -> String {
        switch write.quarantineReason {
        case .membershipRevoked:
            SharedPlanError.membershipRevoked.localizedDescription
        case .revisionConflict:
            SharedPlanError.revisionConflict.localizedDescription
        case .terminalFailure:
            write.quarantineMessage ?? SharedPlanError.persistenceFailed.localizedDescription
        case nil:
            ""
        }
    }

    private func discardInvitationWrite(_ write: SharedPlanRESTWrite) async throws {
        try await persistence.removeRESTWrite(id: write.id)
        pendingRESTWrites.removeAll { $0.id == write.id }
        try await inviteCapabilityVault.remove(requestID: write.id)
    }

    private func authoritativePlan(id: String) async throws -> SharedPlan {
        guard var remotePlan = try await remote.fetchPlans().first(where: { $0.id == id }) else {
            throw SharedPlanError.membershipRevoked
        }
        remotePlan.circleKeys = plans.first(where: { $0.id == id })?.circleKeys ?? []
        return remotePlan
    }

    private static func isTerminalInvitationError(_ error: CominaviServiceError) -> Bool {
        switch error {
        case .server(_, _, let status):
            [400, 403, 404, 409, 422].contains(status)
        case .revisionConflict:
            true
        case .favoriteMutationRejected:
            false
        case .planOwnerRequired, .invitationTokenAlreadyReturned:
            true
        case .notLoggedIn, .authenticationStorageUnavailable,
             .logoutPending, .accountDeletionPending,
             .circlemsCredentialTransferPending, .invalidResponse:
            false
        }
    }

    private static func isTerminalRESTError(_ error: CominaviServiceError) -> Bool {
        switch error {
        case .server(_, _, let status):
            [400, 403, 404, 409, 422].contains(status)
        case .planOwnerRequired, .invitationTokenAlreadyReturned:
            true
        default:
            false
        }
    }

    private static func isTransientRESTError(_ error: CominaviServiceError) -> Bool {
        guard case .server(_, _, let status) = error else { return false }
        return status == 429 || status >= 500
    }

    private static func isTerminalNotificationReadError(
        _ error: CominaviServiceError
    ) -> Bool {
        guard case .server(_, _, let status) = error else { return false }
        return [400, 404, 409, 422].contains(status)
    }

    private static func applyingMetadataIntents(
        _ writes: [SharedPlanRESTWrite],
        to plan: SharedPlan
    ) -> SharedPlan {
        var result = plan
        for write in writes.sorted(by: writeOrder) {
            switch write.kind {
            case .rename:
                if let name = write.name { result.name = name }
            case .archive:
                result.lifecycle = .archived
            case .reopen:
                result.lifecycle = .active
            case .create, .acceptInvitation:
                break
            case .revokeMember, .reinstateMember, .transferOwnership,
                 .createInvitation, .revokeInvitation:
                break
            }
            result.updatedAt = max(result.updatedAt, write.createdAt)
        }
        return result
    }

    private static func isMetadataWrite(_ kind: SharedPlanRESTWriteKind) -> Bool {
        switch kind {
        case .rename, .archive, .reopen,
             .revokeMember, .reinstateMember, .transferOwnership,
             .createInvitation, .revokeInvitation:
            true
        case .create, .acceptInvitation:
            false
        }
    }

    private static func blocksPlanEditing(_ write: SharedPlanRESTWrite) -> Bool {
        switch write.kind {
        case .rename, .archive, .reopen:
            true
        case .create, .acceptInvitation, .revokeMember, .reinstateMember,
             .transferOwnership, .createInvitation, .revokeInvitation:
            false
        }
    }

    private static func mergingMembers(
        _ existing: [SharedPlanMember],
        _ incoming: [SharedPlanMember]
    ) -> [SharedPlanMember] {
        var result = existing
        for member in incoming {
            if let index = result.firstIndex(where: { $0.userID == member.userID }) {
                result[index] = member
            } else {
                result.append(member)
            }
        }
        return result
    }

    private static func mergingInvitations(
        _ existing: [SharedPlanInvitation],
        _ incoming: [SharedPlanInvitation]
    ) -> [SharedPlanInvitation] {
        var result = existing
        for invitation in incoming {
            if let index = result.firstIndex(where: {
                $0.invitationID == invitation.invitationID
            }) {
                result[index] = invitation
            } else {
                result.append(invitation)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.invitationID > rhs.invitationID
        }
    }

    private static func mergingNotifications(
        _ existing: [SharedPlanNotificationItem],
        _ incoming: [SharedPlanNotificationItem]
    ) -> [SharedPlanNotificationItem] {
        var result = existing
        for notification in incoming {
            if let index = result.firstIndex(where: { $0.id == notification.id }) {
                var merged = notification
                merged.readAt = notification.readAt ?? result[index].readAt
                result[index] = merged
            } else {
                result.append(notification)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id > rhs.id
        }
    }

    private static func isCanonicalNotificationID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private static func isPublicUserID(_ value: String) -> Bool {
        value.count == 32
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private static func isStructurallyValidCreatedInvitation(
        _ invitation: SharedPlanCreatedInvitation
    ) -> Bool {
        isCanonicalUUIDString(invitation.planID)
            && isCanonicalUUIDString(invitation.invitationID)
            && invitation.receipt.requestID == invitation.requestID
            && invitation.receipt.resultRevision > 0
            && invitation.receipt.resultStatus == .active
            && SharedPlanInvitationLink.isValid(token: invitation.token)
            && invitation.canonicalURL == SharedPlanInvitationLink.canonicalURL(
                token: invitation.token
            )
            && invitation.fallbackURL == SharedPlanInvitationLink.fallbackURL(
                token: invitation.token
            )
    }

    private static func isCanonicalUUIDString(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    private struct RecoveryExport: Encodable {
        let v: Int
        let planID: String
        let replicaID: String?
        let actorID: String?
        let automergeSave: String?
        let automergeSaveByteCount: Int?
        let automergeSaveOmittedForSafety: Bool
        let pendingOperationIDs: [String]
        let syncIssue: SharedPlanSyncIssue?
        let localEditLimit: SharedPlanLocalEditLimit?
        let metadataIntents: [SharedPlanRESTWrite]
    }

    private static func recoveryExport(
        snapshot: SharedPlanDocumentSnapshot?,
        intents: [SharedPlanRESTWrite]
    ) -> String? {
        guard let planID = snapshot?.planID ?? intents.first?.planID else { return nil }
        let retainedBytesAreBounded = snapshot.map {
            $0.document.count <= SharedPlanAutomergeDocument.maximumSavedDocumentBytes
        } ?? false
        let value = RecoveryExport(
            v: 1,
            planID: planID,
            replicaID: snapshot?.replicaID.uuidString.lowercased(),
            actorID: snapshot?.actorID.lowercased(),
            automergeSave: retainedBytesAreBounded
                ? snapshot?.document.base64URLEncodedString
                : nil,
            automergeSaveByteCount: snapshot?.document.count,
            automergeSaveOmittedForSafety: snapshot != nil && !retainedBytesAreBounded,
            pendingOperationIDs: (snapshot?.pendingOperationIDs ?? []).map {
                $0.uuidString.lowercased()
            },
            syncIssue: snapshot?.syncIssue,
            localEditLimit: snapshot?.localEditLimit,
            metadataIntents: intents.sorted(by: writeOrder)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeOrder(
        _ lhs: SharedPlanRESTWrite,
        _ rhs: SharedPlanRESTWrite
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
