import Foundation
import Observation

struct SharedPlanPresentationFeatures: Equatable, Sendable {
    /// Keep coordinated with the backend mutation flag. Tests inject a disabled
    /// value to preserve the fail-closed rollback path.
    static let production = SharedPlanPresentationFeatures(writesEnabled: true)

    let writesEnabled: Bool
}

struct SharedPlanPrimaryPlanPreference {
    private static let keyPrefix = "shared-plans.primary-plan"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func storageKey(userID: String?, comiketNo: Int?) -> String {
        let account = userID?.lowercased() ?? "anonymous"
        let event = comiketNo.map(String.init) ?? "all"
        return "\(keyPrefix).\(account).\(event)"
    }

    func planID(userID: String?, comiketNo: Int?) -> String? {
        defaults.string(forKey: Self.storageKey(userID: userID, comiketNo: comiketNo))
    }

    func setPlanID(_ planID: String?, userID: String?, comiketNo: Int?) {
        let key = Self.storageKey(userID: userID, comiketNo: comiketNo)
        if let planID {
            defaults.set(planID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func validPlanID(
        _ storedPlanID: String?,
        among plans: [SharedPlan]
    ) -> String? {
        guard let storedPlanID,
              plans.contains(where: {
                  $0.id == storedPlanID && $0.lifecycle == .active
              })
        else { return nil }
        return storedPlanID
    }
}

@MainActor
protocol SharedPlanManagementServicing: AnyObject {
    var plans: [SharedPlan] { get }
    var membersByPlanID: [String: [SharedPlanMember]] { get }
    var memberNextCursorByPlanID: [String: String] { get }
    var invitationsByPlanID: [String: [SharedPlanInvitation]] { get }
    var invitationNextCursorByPlanID: [String: String] { get }
    var createdInvitations: [UUID: SharedPlanCreatedInvitation] { get }
    var pendingRESTWrites: [SharedPlanRESTWrite] { get }
    var quarantinedRESTWrites: [SharedPlanRESTWrite] { get }
    var restWriteIssues: [UUID: String] { get }

    func load() async
    func refreshMembers(planID: String, limit: Int) async throws
    func loadMoreMembers(planID: String, limit: Int) async throws
    func refreshInvitations(planID: String, limit: Int) async throws
    func loadMoreInvitations(planID: String, limit: Int) async throws
    func revokeMember(planID: String, userID: String, now: Date) async throws -> UUID
    func reinstateMember(planID: String, userID: String, now: Date) async throws -> UUID
    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        now: Date
    ) async throws -> UUID
    func createInvitation(planID: String, expiresAt: Date, now: Date) async throws -> UUID
    func revokeInvitation(
        planID: String,
        invitationID: String,
        now: Date
    ) async throws -> UUID
    func discardCreatedInvitation(requestID: UUID) async throws
    func retryQuarantinedMetadataChanges(planID: String, now: Date) async throws
    func discardQuarantinedWrite(id: UUID) async throws
    func drainRESTOutbox() async
}

extension SharedPlanStore: SharedPlanManagementServicing {}

enum SharedPlanAdministrativeAction: Equatable, Identifiable, Sendable {
    case revokeMember(userID: String, displayName: String)
    case reinstateMember(userID: String, displayName: String)
    case transferOwnership(userID: String, displayName: String)
    case revokeInvitation(invitationID: String)

    var id: String {
        switch self {
        case .revokeMember(let userID, _): "revoke-member:\(userID)"
        case .reinstateMember(let userID, _): "reinstate-member:\(userID)"
        case .transferOwnership(let userID, _): "transfer-ownership:\(userID)"
        case .revokeInvitation(let invitationID): "revoke-invitation:\(invitationID)"
        }
    }
}

enum SharedPlanInvitationCreationOutcome: Equatable, Sendable {
    case created(SharedPlanCreatedInvitation)
    case queued
}

enum SharedPlanProtectedInvitationAvailability: Equatable, Sendable {
    case active
    case expired
    case revoked
    case unavailable

    var canShare: Bool { self == .active }
}

@MainActor
@Observable
final class SharedPlanManagementModel {
    let planID: String
    let features: SharedPlanPresentationFeatures

    private(set) var plan: SharedPlan?
    private(set) var members: [SharedPlanMember] = []
    private(set) var invitations: [SharedPlanInvitation] = []
    private(set) var protectedInvitations: [SharedPlanCreatedInvitation] = []
    private(set) var pendingWrites: [SharedPlanRESTWrite] = []
    private(set) var quarantinedWrites: [SharedPlanRESTWrite] = []
    private(set) var writeIssues: [UUID: String] = [:]
    private(set) var canLoadMoreMembers = false
    private(set) var canLoadMoreInvitations = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMoreMembers = false
    private(set) var isLoadingMoreInvitations = false
    private(set) var isPerformingAction = false
    private(set) var memberIssue: String?
    private(set) var invitationIssue: String?
    private(set) var actionIssue: String?

    init(
        planID: String,
        features: SharedPlanPresentationFeatures = .production
    ) {
        self.planID = planID
        self.features = features
    }

    var isOwner: Bool {
        plan?.role == .owner
    }

    var permitsMembershipAdministration: Bool {
        features.writesEnabled
            && plan?.role == .owner
            && plan?.lifecycle == .active
    }

    var permitsInvitationCreation: Bool {
        features.writesEnabled
            && plan != nil
            && plan?.lifecycle == .active
    }

    var visibleInvitations: [SharedPlanInvitation] {
        invitations.filter { $0.revokedAt == nil }
    }

    var permitsQuarantineRetry: Bool {
        !quarantinedWrites.isEmpty && quarantinedWrites.allSatisfy(permits)
    }

    func permitsInvitationRevocation(invitationID: String) -> Bool {
        permitsInvitationCreation
            && invitations.first(where: { $0.invitationID == invitationID })?
                .currentUserCanRevoke == true
    }

    func protectedInvitationAvailability(
        for protectedInvitation: SharedPlanCreatedInvitation,
        now: Date = Date()
    ) -> SharedPlanProtectedInvitationAvailability {
        guard plan?.lifecycle == .active,
              let authoritative = invitations.first(where: {
                  $0.invitationID == protectedInvitation.invitationID
              }),
              authoritative.expiresAt == protectedInvitation.expiresAt
        else { return .unavailable }
        if authoritative.revokedAt != nil { return .revoked }
        if authoritative.expiresAt <= now { return .expired }
        return .active
    }

    var hasRevisionConflictRecovery: Bool {
        quarantinedWrites.contains { $0.quarantineReason == .revisionConflict }
    }

    func load(using service: any SharedPlanManagementServicing) async {
        await service.load()
        synchronize(from: service)
        await refresh(using: service)
    }

    func refresh(using service: any SharedPlanManagementServicing) async {
        guard !isRefreshing,
              !isLoadingMoreMembers,
              !isLoadingMoreInvitations
        else { return }
        isRefreshing = true
        defer {
            synchronize(from: service)
            isRefreshing = false
        }

        do {
            try await service.refreshMembers(planID: planID, limit: 50)
            memberIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            memberIssue = error.localizedDescription
        }

        do {
            try await service.refreshInvitations(planID: planID, limit: 50)
            invitationIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            invitationIssue = error.localizedDescription
        }
    }

    func loadMoreMembers(using service: any SharedPlanManagementServicing) async {
        guard canLoadMoreMembers,
              !isRefreshing,
              !isLoadingMoreMembers,
              !isLoadingMoreInvitations
        else { return }
        isLoadingMoreMembers = true
        defer {
            synchronize(from: service)
            isLoadingMoreMembers = false
        }
        do {
            try await service.loadMoreMembers(planID: planID, limit: 50)
            memberIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            memberIssue = error.localizedDescription
        }
    }

    func loadMoreInvitations(using service: any SharedPlanManagementServicing) async {
        guard canLoadMoreInvitations,
              !isRefreshing,
              !isLoadingMoreMembers,
              !isLoadingMoreInvitations
        else { return }
        isLoadingMoreInvitations = true
        defer {
            synchronize(from: service)
            isLoadingMoreInvitations = false
        }
        do {
            try await service.loadMoreInvitations(planID: planID, limit: 50)
            invitationIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            invitationIssue = error.localizedDescription
        }
    }

    @discardableResult
    func createInvitation(
        expiresAt: Date,
        using service: any SharedPlanManagementServicing,
        now: Date = Date()
    ) async -> SharedPlanInvitationCreationOutcome? {
        guard permitsInvitationCreation, !isPerformingAction else {
            actionIssue = String(localized: "Shared Plan changes are currently read-only.")
            return nil
        }
        isPerformingAction = true
        defer {
            synchronize(from: service)
            isPerformingAction = false
        }
        do {
            let requestID = try await service.createInvitation(
                planID: planID,
                expiresAt: expiresAt,
                now: now
            )
            await service.drainRESTOutbox()
            synchronize(from: service)
            if let invitation = service.createdInvitations[requestID] {
                actionIssue = nil
                return .created(invitation)
            } else if let message = service.restWriteIssues[requestID] {
                actionIssue = message
            }
            return .queued
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return nil
            }
            actionIssue = error.localizedDescription
            return nil
        }
    }

    func perform(
        _ action: SharedPlanAdministrativeAction,
        using service: any SharedPlanManagementServicing,
        now: Date = Date()
    ) async {
        guard permits(action), !isPerformingAction else {
            actionIssue = String(localized: "Shared Plan changes are currently read-only.")
            return
        }
        isPerformingAction = true
        defer {
            synchronize(from: service)
            isPerformingAction = false
        }
        do {
            switch action {
            case .revokeMember(let userID, _):
                _ = try await service.revokeMember(
                    planID: planID,
                    userID: userID,
                    now: now
                )
            case .reinstateMember(let userID, _):
                _ = try await service.reinstateMember(
                    planID: planID,
                    userID: userID,
                    now: now
                )
            case .transferOwnership(let userID, _):
                _ = try await service.transferOwnership(
                    planID: planID,
                    newOwnerUserID: userID,
                    now: now
                )
            case .revokeInvitation(let invitationID):
                _ = try await service.revokeInvitation(
                    planID: planID,
                    invitationID: invitationID,
                    now: now
                )
            }
            await service.drainRESTOutbox()
            actionIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            actionIssue = error.localizedDescription
        }
    }

    func retryQuarantinedWrites(
        using service: any SharedPlanManagementServicing,
        now: Date = Date()
    ) async {
        guard permitsQuarantineRetry, !isPerformingAction else {
            actionIssue = String(localized: "Shared Plan changes are currently read-only.")
            return
        }
        isPerformingAction = true
        defer {
            synchronize(from: service)
            isPerformingAction = false
        }
        do {
            try await service.retryQuarantinedMetadataChanges(planID: planID, now: now)
            await service.drainRESTOutbox()
            actionIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            actionIssue = error.localizedDescription
        }
    }

    func discardQuarantinedWrite(
        id: UUID,
        using service: any SharedPlanManagementServicing
    ) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer {
            synchronize(from: service)
            isPerformingAction = false
        }
        do {
            try await service.discardQuarantinedWrite(id: id)
            actionIssue = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            actionIssue = error.localizedDescription
        }
    }

    func discardProtectedInvitation(
        requestID: UUID,
        using service: any SharedPlanManagementServicing
    ) async -> Bool {
        do {
            try await service.discardCreatedInvitation(requestID: requestID)
            synchronize(from: service)
            actionIssue = nil
            return true
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return false
            }
            actionIssue = error.localizedDescription
            return false
        }
    }

    func synchronize(from service: any SharedPlanManagementServicing) {
        plan = service.plans.first { $0.id == planID }
        members = service.membersByPlanID[planID] ?? []
        invitations = service.invitationsByPlanID[planID] ?? []
        protectedInvitations = service.createdInvitations.values
            .filter { $0.planID == planID }
            .sorted {
                if $0.expiresAt != $1.expiresAt { return $0.expiresAt > $1.expiresAt }
                return $0.invitationID > $1.invitationID
            }
        pendingWrites = service.pendingRESTWrites
            .filter { $0.planID == planID && $0.kind.isAdministrative }
            .sorted(by: SharedPlanRESTWrite.presentationOrder)
        quarantinedWrites = service.quarantinedRESTWrites
            .filter { $0.planID == planID && $0.kind.isAdministrative }
            .sorted(by: SharedPlanRESTWrite.presentationOrder)
        writeIssues = service.restWriteIssues
        canLoadMoreMembers = service.memberNextCursorByPlanID[planID] != nil
        canLoadMoreInvitations = service.invitationNextCursorByPlanID[planID] != nil
    }

    func dismissActionIssue() {
        actionIssue = nil
    }

    private func permits(_ action: SharedPlanAdministrativeAction) -> Bool {
        switch action {
        case .revokeMember, .reinstateMember, .transferOwnership:
            permitsMembershipAdministration
        case .revokeInvitation(let invitationID):
            permitsInvitationRevocation(invitationID: invitationID)
        }
    }

    private func permits(_ write: SharedPlanRESTWrite) -> Bool {
        switch write.kind {
        case .revokeMember, .reinstateMember, .transferOwnership:
            permitsMembershipAdministration
        case .createInvitation:
            permitsInvitationCreation
        case .revokeInvitation:
            if let invitationID = write.invitationID {
                permitsInvitationRevocation(invitationID: invitationID)
            } else {
                false
            }
        case .create, .rename, .archive, .reopen, .acceptInvitation:
            false
        }
    }
}

@MainActor
protocol SharedPlanNotificationServicing: AnyObject {
    var plans: [SharedPlan] { get }
    var notifications: [SharedPlanNotificationItem] { get }
    var notificationNextCursor: String? { get }
    var pendingNotificationReadIDs: Set<String> { get }
    var notificationReadIssues: [String: String] { get }

    func load() async
    func refreshNotifications(limit: Int) async throws
    func loadMoreNotifications(limit: Int) async throws
    func markNotificationRead(id: String, now: Date) async throws
    func drainNotificationReadOutbox() async
}

extension SharedPlanStore: SharedPlanNotificationServicing {}

@MainActor
@Observable
final class SharedPlanNotificationInboxModel {
    private(set) var notifications: [SharedPlanNotificationItem] = []
    private(set) var planNames: [String: String] = [:]
    private(set) var planComiketNumbers: [String: Int] = [:]
    private(set) var pendingReadIDs: Set<String> = []
    private(set) var readIssues: [String: String] = [:]
    private(set) var canLoadMore = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var issueMessage: String?

    @ObservationIgnored private var markingSeenIDs: Set<String> = []

    var displayItems: [SharedPlanNotificationDisplayItem] {
        SharedPlanNotificationDisplayItem.collapsing(notifications)
    }

    var unreadCount: Int {
        notifications.count { $0.readAt == nil && !pendingReadIDs.contains($0.id) }
    }

    func load(using service: any SharedPlanNotificationServicing) async {
        await service.load()
        synchronize(from: service)
        await refresh(using: service)
    }

    func refresh(using service: any SharedPlanNotificationServicing) async {
        guard !isRefreshing, !isLoadingMore else { return }
        isRefreshing = true
        defer {
            synchronize(from: service)
            isRefreshing = false
        }
        do {
            try await service.refreshNotifications(limit: 50)
            issueMessage = nil
        } catch {
            if !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled {
                issueMessage = error.localizedDescription
            }
        }
    }

    func loadMore(using service: any SharedPlanNotificationServicing) async {
        guard canLoadMore, !isRefreshing, !isLoadingMore else { return }
        isLoadingMore = true
        defer {
            synchronize(from: service)
            isLoadingMore = false
        }
        do {
            try await service.loadMoreNotifications(limit: 50)
            issueMessage = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            issueMessage = error.localizedDescription
        }
    }

    func markSeen(
        _ displayItem: SharedPlanNotificationDisplayItem,
        using service: any SharedPlanNotificationServicing,
        now: Date = Date()
    ) async {
        let unread = displayItem.notifications.filter {
            $0.readAt == nil
                && !pendingReadIDs.contains($0.id)
                && !markingSeenIDs.contains($0.id)
        }
        guard !unread.isEmpty else { return }

        let ids = Set(unread.map(\.id))
        markingSeenIDs.formUnion(ids)
        defer { markingSeenIDs.subtract(ids) }

        do {
            for notification in unread {
                try await service.markNotificationRead(id: notification.id, now: now)
            }
        } catch {
            if !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled {
                issueMessage = error.localizedDescription
            }
        }
        await service.drainNotificationReadOutbox()
        synchronize(from: service)
    }

    func retryRead(
        _ displayItem: SharedPlanNotificationDisplayItem,
        using service: any SharedPlanNotificationServicing,
        now: Date = Date()
    ) async {
        await markSeen(displayItem, using: service, now: now)
    }

    func synchronize(from service: any SharedPlanNotificationServicing) {
        notifications = service.notifications
        planNames = Dictionary(uniqueKeysWithValues: service.plans.map { ($0.id, $0.name) })
        planComiketNumbers = Dictionary(
            uniqueKeysWithValues: service.plans.map { ($0.id, $0.comiketNo) }
        )
        pendingReadIDs = service.pendingNotificationReadIDs
        readIssues = service.notificationReadIssues
        canLoadMore = service.notificationNextCursor != nil
    }
}

struct SharedPlanNotificationDisplayItem: Identifiable, Equatable, Sendable {
    let notifications: [SharedPlanNotificationItem]

    private init(notifications: [SharedPlanNotificationItem]) {
        precondition(!notifications.isEmpty)
        self.notifications = notifications
    }

    var id: String { primary.id }
    var primary: SharedPlanNotificationItem { notifications[0] }
    var isUnread: Bool { notifications.contains { $0.readAt == nil } }
    var isCircleAndPurchaseAddition: Bool {
        notifications.count == 2
            && Self.isCommonCircleAndPurchaseAddition(notifications[0], notifications[1])
    }

    static func collapsing(
        _ notifications: [SharedPlanNotificationItem]
    ) -> [SharedPlanNotificationDisplayItem] {
        var result: [SharedPlanNotificationDisplayItem] = []
        var index = notifications.startIndex
        while index < notifications.endIndex {
            let current = notifications[index]
            let nextIndex = notifications.index(after: index)
            if nextIndex < notifications.endIndex,
               isCommonCircleAndPurchaseAddition(current, notifications[nextIndex])
            {
                result.append(SharedPlanNotificationDisplayItem(
                    notifications: [current, notifications[nextIndex]]
                ))
                index = notifications.index(after: nextIndex)
            } else {
                result.append(SharedPlanNotificationDisplayItem(notifications: [current]))
                index = nextIndex
            }
        }
        return result
    }

    private static func isCommonCircleAndPurchaseAddition(
        _ first: SharedPlanNotificationItem,
        _ second: SharedPlanNotificationItem
    ) -> Bool {
        guard first.planID == second.planID,
              abs(first.createdAt.timeIntervalSince(second.createdAt)) <= 15,
              case .operation(let firstPayload) = first.payload,
              case .operation(let secondPayload) = second.payload,
              firstPayload.actorUserID == secondPayload.actorUserID,
              let firstCircleID = publicCircleID(in: firstPayload.payload),
              firstCircleID == publicCircleID(in: secondPayload.payload)
        else { return false }

        let isExpectedPair =
            firstPayload.operationType == .circlePresence
                && secondPayload.operationType == .needCreate
            || firstPayload.operationType == .needCreate
                && secondPayload.operationType == .circlePresence
        guard isExpectedPair else { return false }

        let circlePayload = firstPayload.operationType == .circlePresence
            ? firstPayload.payload
            : secondPayload.payload
        return circlePayload["state"]?.stringValue != SharedPlanPresenceState.removed.rawValue
    }

    private static func publicCircleID(
        in payload: [String: SharedPlanJSONValue]
    ) -> Int? {
        payload["wcID"]?.integerValue.flatMap(Int.init(exactly:))
    }
}

enum SharedPlanNotificationLocalizationKey: String, CaseIterable, Sendable {
    case circlePresence = "shared_plan.circle.presence"
    case circleResolveParent = "shared_plan.circle.resolve_parent"
    case circleMemoSplice = "shared_plan.circle.memo.splice"
    case needCreate = "shared_plan.need.create"
    case needDelete = "shared_plan.need.delete"
    case needResolveParent = "shared_plan.need.resolve_parent"
    case needWantedQuantity = "shared_plan.need.wanted_quantity"
    case needBuyerAllocation = "shared_plan.need.buyer_allocation"
    case needFulfilledQuantity = "shared_plan.need.fulfilled_quantity"
    case circleCommunicationSet = "shared_plan.circle.communication.set"
    case conflict = "shared_plan.conflict"
}

struct SharedPlanNotificationPresentation {
    let localizationKey: SharedPlanNotificationLocalizationKey
    let title: LocalizedStringResource
    let detail: String
    let systemImage: String
    let isConflict: Bool
    let publicCircleID: Int?

    static func make(
        displayItem: SharedPlanNotificationDisplayItem,
        planName: String?
    ) -> SharedPlanNotificationPresentation? {
        guard displayItem.isCircleAndPurchaseAddition,
              let purchaseNotification = displayItem.notifications.first(where: {
                  guard case .operation(let payload) = $0.payload else { return false }
                  return payload.operationType == .needCreate
              }),
              let presentation = make(
                  notification: purchaseNotification,
                  planName: planName
              )
        else {
            return make(notification: displayItem.primary, planName: planName)
        }
        return SharedPlanNotificationPresentation(
            localizationKey: .needCreate,
            title: "Circle and purchase added",
            detail: presentation.detail,
            systemImage: "cart.badge.plus",
            isConflict: false,
            publicCircleID: presentation.publicCircleID
        )
    }

    static func make(
        notification: SharedPlanNotificationItem,
        planName: String?
    ) -> SharedPlanNotificationPresentation? {
        guard notification.payloadVersion == 1,
              let key = SharedPlanNotificationLocalizationKey(rawValue: notification.i18nKey)
        else { return nil }

        switch (key, notification.payload) {
        case (.circlePresence, .operation(let payload)):
            guard payload.operationType == .circlePresence else { return nil }
            let removed = payload.payload["state"]?.stringValue == "removed"
            return operation(
                key: key,
                title: removed ? "Circle removed" : "Circle added",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: removed ? "minus.circle" : "plus.circle",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.circleResolveParent, .operation(let payload)):
            guard payload.operationType == .circleResolveParent else { return nil }
            return operation(
                key: key,
                title: "Circle conflict resolved",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: "checkmark.circle",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.circleMemoSplice, .operation(let payload)):
            guard payload.operationType == .circleMemoSplice else { return nil }
            return operation(
                key: key,
                title: "Circle memo updated",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: "note.text",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needCreate, .operation(let payload)):
            guard payload.operationType == .needCreate else { return nil }
            return operation(
                key: key,
                title: "Purchase added",
                detail: purchaseDetail(payload.payload, planName: planName),
                systemImage: "cart.badge.plus",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needDelete, .operation(let payload)):
            guard payload.operationType == .needDelete else { return nil }
            return operation(
                key: key,
                title: "Purchase removed",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: "cart.badge.minus",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needResolveParent, .operation(let payload)):
            guard payload.operationType == .needResolveParent else { return nil }
            return operation(
                key: key,
                title: "Purchase conflict resolved",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: "checkmark.circle",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needWantedQuantity, .operation(let payload)):
            guard payload.operationType == .needWantedQuantity else { return nil }
            return operation(
                key: key,
                title: "Wanted quantity updated",
                detail: quantityDetail(
                    payload.payload,
                    quantityKey: "wantedQuantity",
                    format: "%@ • Wanted quantity: %lld",
                    planName: planName
                ),
                systemImage: "number.circle",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needBuyerAllocation, .operation(let payload)):
            guard payload.operationType == .needBuyerAllocation else { return nil }
            return operation(
                key: key,
                title: "Buyer assignment updated",
                detail: quantityDetail(
                    payload.payload,
                    quantityKey: "quantity",
                    format: "%@ • Assigned: %lld",
                    planName: planName
                ),
                systemImage: "person.2",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.needFulfilledQuantity, .operation(let payload)):
            guard payload.operationType == .needFulfilledQuantity else { return nil }
            return operation(
                key: key,
                title: "Purchase progress updated",
                detail: quantityDetail(
                    payload.payload,
                    quantityKey: "fulfilledQuantity",
                    format: "%@ • Purchased: %lld",
                    planName: planName
                ),
                systemImage: "checkmark.circle",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.circleCommunicationSet, .operation(let payload)):
            guard payload.operationType == .circleCommunicationSet else { return nil }
            return operation(
                key: key,
                title: "Circle status updated",
                detail: circleDetail(payload.payload, planName: planName),
                systemImage: "bubble.left.and.bubble.right",
                publicCircleID: publicCircleID(in: payload.payload)
            )
        case (.conflict, .conflict(let payload)):
            let detail = String.localizedStringWithFormat(
                String(localized: "%@ • Open the plan to review the conflict."),
                planName ?? String(localized: "Shared Plan")
            )
            return SharedPlanNotificationPresentation(
                localizationKey: key,
                title: "Plan conflict needs review",
                detail: detail,
                systemImage: "exclamationmark.triangle.fill",
                isConflict: true,
                publicCircleID: circleID(in: payload.path)
            )
        default:
            return nil
        }
    }

    private static func operation(
        key: SharedPlanNotificationLocalizationKey,
        title: LocalizedStringResource,
        detail: String,
        systemImage: String,
        publicCircleID: Int?
    ) -> SharedPlanNotificationPresentation {
        SharedPlanNotificationPresentation(
            localizationKey: key,
            title: title,
            detail: detail,
            systemImage: systemImage,
            isConflict: false,
            publicCircleID: publicCircleID
        )
    }

    private static func circleDetail(
        _ payload: [String: SharedPlanJSONValue],
        planName: String?
    ) -> String {
        planName ?? String(localized: "Shared Plan")
    }

    private static func quantityDetail(
        _ payload: [String: SharedPlanJSONValue],
        quantityKey: String,
        format: LocalizedStringResource,
        planName: String?
    ) -> String {
        guard let quantity = payload[quantityKey]?.integerValue
        else { return circleDetail(payload, planName: planName) }
        return String.localizedStringWithFormat(
            String(localized: format),
            planName ?? String(localized: "Shared Plan"),
            quantity
        )
    }

    private static func purchaseDetail(
        _ payload: [String: SharedPlanJSONValue],
        planName: String?
    ) -> String {
        guard let itemName = payload["itemName"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !itemName.isEmpty
        else { return circleDetail(payload, planName: planName) }
        return String.localizedStringWithFormat(
            String(localized: "%@ • %@"),
            planName ?? String(localized: "Shared Plan"),
            itemName
        )
    }

    private static func circleID(in path: [String]) -> Int? {
        guard let index = path.firstIndex(of: "circles"), path.indices.contains(index + 1)
        else { return nil }
        return Int(path[index + 1])
    }

    private static func publicCircleID(
        in payload: [String: SharedPlanJSONValue]
    ) -> Int? {
        guard let rawValue = payload["wcID"]?.integerValue else { return nil }
        return Int(exactly: rawValue)
    }
}

private extension SharedPlanRESTWriteKind {
    var isAdministrative: Bool {
        switch self {
        case .revokeMember, .reinstateMember, .transferOwnership,
             .createInvitation, .revokeInvitation:
            true
        case .create, .rename, .archive, .reopen, .acceptInvitation:
            false
        }
    }
}

private extension SharedPlanRESTWrite {
    static func presentationOrder(_ lhs: SharedPlanRESTWrite, _ rhs: SharedPlanRESTWrite) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
