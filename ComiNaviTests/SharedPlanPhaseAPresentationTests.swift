@testable import ComiNavi
import Foundation
import XCTest

@MainActor
final class SharedPlanPhaseAPresentationTests: XCTestCase {
    func testPrimaryPlanPreferenceIsLocalScopedAndRejectsArchivedPlans() throws {
        let suiteName = "SharedPlanPrimaryPlanPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preference = SharedPlanPrimaryPlanPreference(defaults: defaults)

        preference.setPlanID(planID, userID: userA, comiketNo: 108)

        XCTAssertEqual(preference.planID(userID: userA, comiketNo: 108), planID)
        XCTAssertNil(preference.planID(userID: userB, comiketNo: 108))
        XCTAssertNil(preference.planID(userID: userA, comiketNo: 109))
        XCTAssertEqual(
            SharedPlanPrimaryPlanPreference.validPlanID(planID, among: [makePlan()]),
            planID
        )

        var archived = makePlan()
        archived.lifecycle = .archived
        XCTAssertNil(
            SharedPlanPrimaryPlanPreference.validPlanID(planID, among: [archived])
        )

        preference.setPlanID(nil, userID: userA, comiketNo: 108)
        XCTAssertNil(preference.planID(userID: userA, comiketNo: 108))
    }

    func testProductionSharedPlanWritesAreEnabled() {
        XCTAssertTrue(SharedPlanPresentationFeatures.production.writesEnabled)

        let store = PhaseAStoreStub(plan: makePlan())
        let model = SharedPlanManagementModel(planID: planID)
        model.synchronize(from: store)

        XCTAssertTrue(model.permitsMembershipAdministration)
        XCTAssertTrue(model.permitsInvitationCreation)
    }

    func testManagementPaginationPreservesCachedRowsWhenRefreshFails() async throws {
        let store = PhaseAStoreStub(plan: makePlan())
        store.firstMembers = [makeMember(userID: userA, name: "Owner", role: .owner)]
        store.nextMembers = [makeMember(userID: userB, name: "Editor", role: .editor)]
        store.firstInvitations = [makeInvitation(id: invitationA)]
        store.nextInvitations = [makeInvitation(id: invitationB)]

        let model = SharedPlanManagementModel(
            planID: planID,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )
        await model.load(using: store)
        XCTAssertEqual(model.members.map(\.userID), [userA])
        XCTAssertEqual(model.invitations.map(\.invitationID), [invitationA])
        XCTAssertTrue(model.canLoadMoreMembers)
        XCTAssertTrue(model.canLoadMoreInvitations)

        await model.loadMoreMembers(using: store)
        await model.loadMoreInvitations(using: store)
        XCTAssertEqual(model.members.map(\.userID), [userA, userB])
        XCTAssertEqual(model.invitations.map(\.invitationID), [invitationA, invitationB])
        XCTAssertFalse(model.canLoadMoreMembers)
        XCTAssertFalse(model.canLoadMoreInvitations)

        store.memberError = URLError(.notConnectedToInternet)
        store.invitationError = URLError(.notConnectedToInternet)
        await model.refresh(using: store)
        XCTAssertEqual(model.members.map(\.userID), [userA, userB])
        XCTAssertEqual(model.invitations.map(\.invitationID), [invitationA, invitationB])
        XCTAssertNotNil(model.memberIssue)
        XCTAssertNotNil(model.invitationIssue)
    }

    func testExplicitReadOnlyGateRejectsAdministrativeMutation() async {
        let store = PhaseAStoreStub(plan: makePlan())
        let model = SharedPlanManagementModel(
            planID: planID,
            features: SharedPlanPresentationFeatures(writesEnabled: false)
        )
        model.synchronize(from: store)

        await model.perform(
            .revokeMember(userID: userB, displayName: "Editor"),
            using: store
        )

        XCTAssertEqual(store.administrativeActions, [])
        XCTAssertNotNil(model.actionIssue)
        XCTAssertFalse(model.permitsMembershipAdministration)
        XCTAssertFalse(model.permitsInvitationCreation)
    }

    func testNonOwnerCannotAdministerWhenWriteFeatureIsEnabled() async {
        let store = PhaseAStoreStub(plan: makePlan(role: .editor))
        let model = SharedPlanManagementModel(
            planID: planID,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )
        model.synchronize(from: store)

        await model.perform(
            .revokeMember(userID: userB, displayName: "Editor"),
            using: store
        )

        XCTAssertEqual(store.administrativeActions, [])
        XCTAssertNotNil(model.actionIssue)
        XCTAssertFalse(model.permitsMembershipAdministration)
        XCTAssertTrue(model.permitsInvitationCreation)
    }

    func testEditorCanCreateAndRevokeOnlyInvitationsAuthorizedByTheRow() async {
        let store = PhaseAStoreStub(plan: makePlan(role: .editor))
        store.invitationsByPlanID[planID] = [
            makeInvitation(id: invitationA, currentUserCanRevoke: true),
            makeInvitation(id: invitationB, currentUserCanRevoke: false),
        ]
        let model = SharedPlanManagementModel(
            planID: planID,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )
        model.synchronize(from: store)

        XCTAssertFalse(model.permitsMembershipAdministration)
        XCTAssertTrue(model.permitsInvitationCreation)
        XCTAssertTrue(model.permitsInvitationRevocation(invitationID: invitationA))
        XCTAssertFalse(model.permitsInvitationRevocation(invitationID: invitationB))

        await model.perform(
            .revokeInvitation(invitationID: invitationA),
            using: store
        )
        XCTAssertEqual(store.administrativeActions, ["revoke-invitation:\(invitationA)"])

        await model.perform(
            .revokeInvitation(invitationID: invitationB),
            using: store
        )
        XCTAssertEqual(store.administrativeActions, ["revoke-invitation:\(invitationA)"])

        let outcome = await model.createInvitation(
            expiresAt: Date(timeIntervalSince1970: 1_786_886_400),
            using: store,
            now: Date(timeIntervalSince1970: 1_786_281_600)
        )
        guard case .created = outcome else {
            return XCTFail("An active editor should be allowed to create an invitation")
        }
    }

    func testOwnerCreateInvitationDrainsToProtectedOneTimeResult() async throws {
        let store = PhaseAStoreStub(plan: makePlan())
        let model = SharedPlanManagementModel(planID: planID)
        model.synchronize(from: store)
        let expiresAt = Date(timeIntervalSince1970: 1_786_886_400)

        let outcome = await model.createInvitation(
            expiresAt: expiresAt,
            using: store,
            now: Date(timeIntervalSince1970: 1_786_281_600)
        )

        guard case .created(let invitation) = outcome else {
            return XCTFail("Expected protected invitation result")
        }
        XCTAssertEqual(invitation.token, "AQEBAQEBAQEB")
        XCTAssertEqual(model.protectedInvitations.map(\.requestID), [invitation.requestID])
        XCTAssertEqual(store.drainRESTCount, 1)

        let discarded = await model.discardProtectedInvitation(
            requestID: invitation.requestID,
            using: store
        )
        XCTAssertTrue(discarded)
        XCTAssertEqual(model.protectedInvitations, [])
    }

    func testOwnerActionsAndQuarantineRecoveryUseStoreAuthority() async {
        let store = PhaseAStoreStub(plan: makePlan())
        let quarantinedID = UUID()
        store.quarantinedRESTWrites = [makeAdministrativeWrite(
            id: quarantinedID,
            kind: .revokeMember,
            targetUserID: userB,
            quarantineReason: .revisionConflict
        )]
        let model = SharedPlanManagementModel(
            planID: planID,
            features: SharedPlanPresentationFeatures(writesEnabled: true)
        )
        model.synchronize(from: store)
        XCTAssertTrue(model.hasRevisionConflictRecovery)

        await model.perform(
            .transferOwnership(userID: userB, displayName: "Editor"),
            using: store
        )
        XCTAssertEqual(store.administrativeActions, ["transfer:\(userB)"])
        XCTAssertEqual(store.drainRESTCount, 1)

        await model.retryQuarantinedWrites(using: store)
        XCTAssertEqual(store.retryQuarantineCount, 1)
        await model.discardQuarantinedWrite(id: quarantinedID, using: store)
        XCTAssertEqual(store.discardedQuarantineIDs, [quarantinedID])
    }

    func testProtectedInvitationRequiresMatchingAuthoritativeActiveRowAcrossRelaunch() {
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let protected = makeProtectedInvitation(expiresAt: expiresAt)
        let store = PhaseAStoreStub(plan: makePlan())
        store.createdInvitations[protected.requestID] = protected
        store.invitationsByPlanID[planID] = [makeInvitation(
            id: protected.invitationID,
            expiresAt: expiresAt
        )]
        let model = SharedPlanManagementModel(planID: planID)
        model.synchronize(from: store)

        XCTAssertEqual(
            model.protectedInvitationAvailability(
                for: protected,
                now: expiresAt.addingTimeInterval(-1)
            ),
            .active
        )

        store.invitationsByPlanID[planID] = [makeInvitation(
            id: protected.invitationID,
            expiresAt: expiresAt,
            revokedAt: expiresAt.addingTimeInterval(-10)
        )]
        model.synchronize(from: store)
        XCTAssertEqual(
            model.protectedInvitationAvailability(
                for: protected,
                now: expiresAt.addingTimeInterval(-1)
            ),
            .revoked
        )

        let relaunchedModel = SharedPlanManagementModel(planID: planID)
        relaunchedModel.synchronize(from: store)
        XCTAssertEqual(
            relaunchedModel.protectedInvitationAvailability(
                for: protected,
                now: expiresAt.addingTimeInterval(-1)
            ),
            .revoked
        )

        store.invitationsByPlanID[planID] = [makeInvitation(
            id: protected.invitationID,
            expiresAt: expiresAt
        )]
        relaunchedModel.synchronize(from: store)
        XCTAssertEqual(
            relaunchedModel.protectedInvitationAvailability(
                for: protected,
                now: expiresAt
            ),
            .expired
        )
        store.invitationsByPlanID[planID] = []
        relaunchedModel.synchronize(from: store)
        XCTAssertEqual(
            relaunchedModel.protectedInvitationAvailability(
                for: protected,
                now: expiresAt.addingTimeInterval(-1)
            ),
            .unavailable
        )
    }

    func testPresentationModelsMutuallyExcludeRefreshAndPagination() async {
        let store = PhaseAStoreStub(plan: makePlan())
        store.firstMembers = [makeMember(userID: userA, name: "Owner", role: .owner)]
        store.nextMembers = [makeMember(userID: userB, name: "Editor", role: .editor)]
        store.firstInvitations = [makeInvitation(id: invitationA)]
        store.nextInvitations = [makeInvitation(id: invitationB)]
        let management = SharedPlanManagementModel(planID: planID)
        await management.load(using: store)

        let refreshGate = PhaseATestGate()
        store.memberRefreshGate = refreshGate
        let refresh = Task { @MainActor in
            await management.refresh(using: store)
        }
        await refreshGate.waitUntilEntered()
        await management.loadMoreMembers(using: store)
        await management.loadMoreInvitations(using: store)
        XCTAssertEqual(store.memberLoadMoreCount, 0)
        XCTAssertEqual(store.invitationLoadMoreCount, 0)
        await refreshGate.open()
        await refresh.value

        let cached = makeNotification(idCharacter: "a", operationType: .circleMemoSplice)
        store.firstNotifications = [cached]
        store.nextNotifications = [makeNotification(
            idCharacter: "b",
            operationType: .needCreate
        )]
        let inbox = SharedPlanNotificationInboxModel()
        await inbox.load(using: store)
        let loadMoreGate = PhaseATestGate()
        store.notificationLoadMoreGate = loadMoreGate
        let loadMore = Task { @MainActor in
            await inbox.loadMore(using: store)
        }
        await loadMoreGate.waitUntilEntered()
        let refreshCount = store.notificationRefreshCount
        await inbox.refresh(using: store)
        XCTAssertEqual(store.notificationRefreshCount, refreshCount)
        await loadMoreGate.open()
        await loadMore.value
    }

    func testNotificationInboxRetainsCachedHistoryPaginatesAndMarksRead() async throws {
        let cached = makeNotification(idCharacter: "a", operationType: .circleMemoSplice)
        let next = makeNotification(idCharacter: "b", operationType: .needCreate)
        let store = PhaseAStoreStub(plan: makePlan())
        store.notifications = [cached]
        store.notificationError = URLError(.notConnectedToInternet)
        let model = SharedPlanNotificationInboxModel()

        await model.load(using: store)
        XCTAssertEqual(model.notifications.map(\.id), [cached.id])
        XCTAssertNotNil(model.issueMessage)

        store.notificationError = nil
        store.firstNotifications = [cached]
        store.nextNotifications = [next]
        await model.refresh(using: store)
        XCTAssertTrue(model.canLoadMore)
        await model.loadMore(using: store)
        XCTAssertEqual(Set(model.notifications.map(\.id)), Set([cached.id, next.id]))

        let readAt = cached.createdAt.addingTimeInterval(60)
        store.notificationReadAt = readAt
        await model.open(cached, using: store, now: cached.createdAt.addingTimeInterval(10))
        XCTAssertEqual(model.notifications.first(where: { $0.id == cached.id })?.readAt, readAt)
        XCTAssertEqual(store.markedNotificationIDs, [cached.id])
        XCTAssertEqual(store.drainReadCount, 1)
    }

    func testNotificationPresentationMapsEveryFrozenI18nKeyWithoutServerProse() throws {
        for operationType in SharedPlanOperationType.allCases {
            let notification = makeNotification(
                idCharacter: "c",
                operationType: operationType
            )
            let presentation = try XCTUnwrap(
                SharedPlanNotificationPresentation.make(
                    notification: notification,
                    planName: "買い物リスト"
                )
            )
            XCTAssertEqual(
                presentation.localizationKey.rawValue,
                String(operationType.rawValue.dropLast(".v1".count))
            )
            XCTAssertFalse(presentation.detail.contains(notification.i18nKey))
            XCTAssertFalse(presentation.detail.contains(notification.eventType))
            XCTAssertFalse(presentation.detail.contains("WCID"))
            XCTAssertEqual(presentation.publicCircleID, 9_001)
        }

        let conflict = makeConflictNotification(idCharacter: "d")
        let presentation = try XCTUnwrap(
            SharedPlanNotificationPresentation.make(
                notification: conflict,
                planName: "買い物リスト"
            )
        )
        XCTAssertEqual(presentation.localizationKey, .conflict)
        XCTAssertTrue(presentation.isConflict)
        XCTAssertFalse(presentation.detail.contains("WCID"))
        XCTAssertEqual(presentation.publicCircleID, 9_001)

        let mismatched = SharedPlanNotificationItem(
            id: conflict.id,
            kind: conflict.kind,
            planID: conflict.planID,
            eventType: conflict.eventType,
            i18nKey: SharedPlanNotificationLocalizationKey.circleMemoSplice.rawValue,
            payloadVersion: conflict.payloadVersion,
            payload: conflict.payload,
            createdAt: conflict.createdAt,
            readAt: nil
        )
        XCTAssertNil(SharedPlanNotificationPresentation.make(
            notification: mismatched,
            planName: nil
        ))
    }

    func testSynchronizingAnotherAccountRemovesPriorAccountPresentationState() {
        let firstStore = PhaseAStoreStub(plan: makePlan())
        firstStore.firstMembers = [makeMember(userID: userA, name: "Owner", role: .owner)]
        firstStore.membersByPlanID[planID] = firstStore.firstMembers
        firstStore.notifications = [makeNotification(
            idCharacter: "e",
            operationType: .circlePresence
        )]

        let management = SharedPlanManagementModel(planID: planID)
        let inbox = SharedPlanNotificationInboxModel()
        management.synchronize(from: firstStore)
        inbox.synchronize(from: firstStore)
        XCTAssertFalse(management.members.isEmpty)
        XCTAssertFalse(inbox.notifications.isEmpty)

        let secondStore = PhaseAStoreStub(plan: nil)
        management.synchronize(from: secondStore)
        inbox.synchronize(from: secondStore)
        XCTAssertEqual(management.members, [])
        XCTAssertEqual(management.protectedInvitations, [])
        XCTAssertEqual(inbox.notifications, [])
        XCTAssertEqual(inbox.planNames, [:])
    }
}

@MainActor
private final class PhaseAStoreStub: SharedPlanManagementServicing,
    SharedPlanNotificationServicing
{
    var plans: [SharedPlan]
    var membersByPlanID: [String: [SharedPlanMember]] = [:]
    var memberNextCursorByPlanID: [String: String] = [:]
    var invitationsByPlanID: [String: [SharedPlanInvitation]] = [:]
    var invitationNextCursorByPlanID: [String: String] = [:]
    var createdInvitations: [UUID: SharedPlanCreatedInvitation] = [:]
    var pendingRESTWrites: [SharedPlanRESTWrite] = []
    var quarantinedRESTWrites: [SharedPlanRESTWrite] = []
    var restWriteIssues: [UUID: String] = [:]
    var notifications: [SharedPlanNotificationItem] = []
    var notificationNextCursor: String?
    var pendingNotificationReadIDs: Set<String> = []
    var notificationReadIssues: [String: String] = [:]

    var firstMembers: [SharedPlanMember] = []
    var nextMembers: [SharedPlanMember] = []
    var firstInvitations: [SharedPlanInvitation] = []
    var nextInvitations: [SharedPlanInvitation] = []
    var firstNotifications: [SharedPlanNotificationItem] = []
    var nextNotifications: [SharedPlanNotificationItem] = []
    var memberError: Error?
    var invitationError: Error?
    var notificationError: Error?
    var notificationReadAt: Date?
    var administrativeActions: [String] = []
    var markedNotificationIDs: [String] = []
    var discardedQuarantineIDs: [UUID] = []
    var retryQuarantineCount = 0
    var drainRESTCount = 0
    var drainReadCount = 0
    var memberLoadMoreCount = 0
    var invitationLoadMoreCount = 0
    var notificationRefreshCount = 0
    var notificationLoadMoreCount = 0
    var memberRefreshGate: PhaseATestGate?
    var notificationLoadMoreGate: PhaseATestGate?
    private var queuedInvitation: (UUID, Date)?

    init(plan: SharedPlan?) {
        plans = plan.map { [$0] } ?? []
    }

    func load() async {}

    func refreshMembers(planID: String, limit: Int) async throws {
        if let memberRefreshGate { await memberRefreshGate.wait() }
        if let memberError { throw memberError }
        membersByPlanID[planID] = firstMembers
        memberNextCursorByPlanID[planID] = nextMembers.isEmpty ? nil : "members-next"
    }

    func loadMoreMembers(planID: String, limit: Int) async throws {
        memberLoadMoreCount += 1
        if let memberError { throw memberError }
        membersByPlanID[planID, default: []].append(contentsOf: nextMembers)
        memberNextCursorByPlanID[planID] = nil
    }

    func refreshInvitations(planID: String, limit: Int) async throws {
        if let invitationError { throw invitationError }
        invitationsByPlanID[planID] = firstInvitations
        invitationNextCursorByPlanID[planID] = nextInvitations.isEmpty
            ? nil : "invitations-next"
    }

    func loadMoreInvitations(planID: String, limit: Int) async throws {
        invitationLoadMoreCount += 1
        if let invitationError { throw invitationError }
        invitationsByPlanID[planID, default: []].append(contentsOf: nextInvitations)
        invitationNextCursorByPlanID[planID] = nil
    }

    func revokeMember(
        planID: String,
        userID: String,
        now: Date
    ) async throws -> UUID {
        administrativeActions.append("revoke:\(userID)")
        return enqueue(kind: .revokeMember, targetUserID: userID, now: now)
    }

    func reinstateMember(
        planID: String,
        userID: String,
        now: Date
    ) async throws -> UUID {
        administrativeActions.append("reinstate:\(userID)")
        return enqueue(kind: .reinstateMember, targetUserID: userID, now: now)
    }

    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        now: Date
    ) async throws -> UUID {
        administrativeActions.append("transfer:\(newOwnerUserID)")
        return enqueue(kind: .transferOwnership, targetUserID: newOwnerUserID, now: now)
    }

    func createInvitation(
        planID: String,
        expiresAt: Date,
        now: Date
    ) async throws -> UUID {
        let requestID = enqueue(kind: .createInvitation, expiresAt: expiresAt, now: now)
        queuedInvitation = (requestID, expiresAt)
        return requestID
    }

    func revokeInvitation(
        planID: String,
        invitationID: String,
        now: Date
    ) async throws -> UUID {
        administrativeActions.append("revoke-invitation:\(invitationID)")
        return enqueue(kind: .revokeInvitation, invitationID: invitationID, now: now)
    }

    func discardCreatedInvitation(requestID: UUID) async throws {
        createdInvitations[requestID] = nil
    }

    func retryQuarantinedMetadataChanges(planID: String, now: Date) async throws {
        retryQuarantineCount += 1
    }

    func discardQuarantinedWrite(id: UUID) async throws {
        discardedQuarantineIDs.append(id)
        quarantinedRESTWrites.removeAll { $0.id == id }
    }

    func drainRESTOutbox() async {
        drainRESTCount += 1
        if let (requestID, expiresAt) = queuedInvitation {
            let receipt = SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: 5,
                resultStatus: .active
            )
            createdInvitations[requestID] = SharedPlanCreatedInvitation(
                requestID: requestID,
                planID: SharedPlanPhaseAPresentationTests.planID,
                invitationID: SharedPlanPhaseAPresentationTests.invitationA,
                token: "AQEBAQEBAQEB",
                expiresAt: expiresAt,
                canonicalURL: URL(string: "https://cominavi.net/join/AQEBAQEBAQEB")!,
                fallbackURL: URL(string: "cominavi://join/AQEBAQEBAQEB")!,
                receipt: receipt
            )
            queuedInvitation = nil
        }
        pendingRESTWrites.removeAll()
    }

    func refreshNotifications(limit: Int) async throws {
        notificationRefreshCount += 1
        if let notificationError { throw notificationError }
        notifications = merge(notifications, firstNotifications)
        notificationNextCursor = nextNotifications.isEmpty ? nil : "notifications-next"
    }

    func loadMoreNotifications(limit: Int) async throws {
        notificationLoadMoreCount += 1
        if let notificationLoadMoreGate { await notificationLoadMoreGate.wait() }
        if let notificationError { throw notificationError }
        notifications = merge(notifications, nextNotifications)
        notificationNextCursor = nil
    }

    func markNotificationRead(id: String, now: Date) async throws {
        markedNotificationIDs.append(id)
        pendingNotificationReadIDs.insert(id)
    }

    func drainNotificationReadOutbox() async {
        drainReadCount += 1
        for id in pendingNotificationReadIDs {
            guard let index = notifications.firstIndex(where: { $0.id == id }) else { continue }
            notifications[index].readAt = notificationReadAt ?? Date()
        }
        pendingNotificationReadIDs.removeAll()
    }

    private func enqueue(
        kind: SharedPlanRESTWriteKind,
        targetUserID: String? = nil,
        invitationID: String? = nil,
        expiresAt: Date? = nil,
        now: Date
    ) -> UUID {
        let id = UUID()
        pendingRESTWrites.append(SharedPlanRESTWrite(
            id: id,
            planID: SharedPlanPhaseAPresentationTests.planID,
            kind: kind,
            baseRevision: 4,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            targetUserID: targetUserID,
            invitationID: invitationID,
            expiresAt: expiresAt,
            createdAt: now
        ))
        return id
    }

    private func merge(
        _ existing: [SharedPlanNotificationItem],
        _ incoming: [SharedPlanNotificationItem]
    ) -> [SharedPlanNotificationItem] {
        var values = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for item in incoming { values[item.id] = item }
        return values.values.sorted { $0.id > $1.id }
    }
}

private extension SharedPlanPhaseAPresentationTests {
    static let planID = "11111111-1111-4111-8111-111111111111"
    static let userA = "00000000000000000000000000000001"
    static let userB = "00000000000000000000000000000002"
    static let invitationA = "55555555-5555-4555-8555-555555555555"
    static let invitationB = "55555555-5555-4555-8555-555555555556"

    var planID: String { Self.planID }
    var userA: String { Self.userA }
    var userB: String { Self.userB }
    var invitationA: String { Self.invitationA }
    var invitationB: String { Self.invitationB }

    func makePlan(role: SharedPlanRole = .owner) -> SharedPlan {
        SharedPlan(
            id: planID,
            name: "買い物リスト",
            comiketNo: 108,
            ownership: .owned,
            role: role,
            lifecycle: .active,
            revision: 4,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1_786_276_800),
            updatedAt: Date(timeIntervalSince1970: 1_786_276_800)
        )
    }

    func makeMember(
        userID: String,
        name: String,
        role: SharedPlanRole
    ) -> SharedPlanMember {
        SharedPlanMember(
            userID: userID,
            displayName: name,
            avatarURL: nil,
            role: role,
            membershipStatus: .active,
            joinedAt: Date(timeIntervalSince1970: 1_786_276_800),
            removedAt: nil
        )
    }

    func makeInvitation(
        id: String,
        currentUserCanRevoke: Bool = true,
        expiresAt: Date = Date(timeIntervalSince1970: 1_786_886_400),
        revokedAt: Date? = nil
    ) -> SharedPlanInvitation {
        SharedPlanInvitation(
            invitationID: id,
            createdByUserID: userA,
            currentUserCanRevoke: currentUserCanRevoke,
            expiresAt: expiresAt,
            revokedAt: revokedAt,
            createdAt: Date(timeIntervalSince1970: 1_786_276_800)
        )
    }

    func makeProtectedInvitation(expiresAt: Date) -> SharedPlanCreatedInvitation {
        let requestID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        return SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: invitationA,
            token: "AQEBAQEBAQEB",
            expiresAt: expiresAt,
            canonicalURL: URL(string: "https://cominavi.net/join/AQEBAQEBAQEB")!,
            fallbackURL: URL(string: "cominavi://join/AQEBAQEBAQEB")!,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: 5,
                resultStatus: .active
            )
        )
    }

    func makeAdministrativeWrite(
        id: UUID,
        kind: SharedPlanRESTWriteKind,
        targetUserID: String?,
        quarantineReason: SharedPlanRESTWriteQuarantineReason
    ) -> SharedPlanRESTWrite {
        SharedPlanRESTWrite(
            id: id,
            planID: planID,
            kind: kind,
            baseRevision: 4,
            name: nil,
            comiketNo: nil,
            inviteToken: nil,
            targetUserID: targetUserID,
            createdAt: Date(timeIntervalSince1970: 1_786_276_800),
            quarantineReason: quarantineReason,
            conflictRevision: 5
        )
    }

    func makeNotification(
        idCharacter: Character,
        operationType: SharedPlanOperationType
    ) -> SharedPlanNotificationItem {
        var payload: [String: SharedPlanJSONValue] = [
            "v": .integer(1),
            "wcID": .integer(9001),
            "state": .string("active"),
            "wantedQuantity": .integer(2),
            "quantity": .integer(1),
            "fulfilledQuantity": .integer(1),
        ]
        if operationType == .circleMemoSplice {
            payload["insertedTextPreview"] = .string("メモ")
        }
        let operation = SharedPlanOperationNotificationPayload(
            v: 1,
            planID: planID,
            operationID: "22222222-2222-4222-8222-222222222222",
            operationType: operationType,
            actorUserID: userA,
            payload: payload,
            heads: [String(repeating: "a", count: 64)],
            membershipEpoch: 7
        )
        return SharedPlanNotificationItem(
            id: String(repeating: String(idCharacter), count: 64),
            kind: .sharedPlanEvent,
            planID: planID,
            eventType: operationType.rawValue,
            i18nKey: String(operationType.rawValue.dropLast(".v1".count)),
            payloadVersion: 1,
            payload: .operation(operation),
            createdAt: Date(timeIntervalSince1970: 1_786_320_000),
            readAt: nil
        )
    }

    func makeConflictNotification(idCharacter: Character) -> SharedPlanNotificationItem {
        let payload = SharedPlanConflictNotificationPayload(
            v: 1,
            planID: planID,
            conflictID: String(repeating: "b", count: 64),
            path: ["circles", "9001", "needs", "need", "wantedQuantity"],
            changeHashes: [String(repeating: "c", count: 64), String(repeating: "d", count: 64)],
            heads: [String(repeating: "a", count: 64)],
            membershipEpoch: 7
        )
        return SharedPlanNotificationItem(
            id: String(repeating: String(idCharacter), count: 64),
            kind: .sharedPlanEvent,
            planID: planID,
            eventType: "shared_plan.conflict.v1",
            i18nKey: "shared_plan.conflict",
            payloadVersion: 1,
            payload: .conflict(payload),
            createdAt: Date(timeIntervalSince1970: 1_786_320_000),
            readAt: nil
        )
    }
}

private actor PhaseATestGate {
    private var hasEntered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
