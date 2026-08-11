@testable import ComiNavi
import Foundation
import XCTest

@MainActor
final class SharedPlanCollectionGenerationTests: XCTestCase {
    func testEditorStoreAuthorityCreatesInvitationsAndRevokesOnlyAuthorizedRows() async throws {
        let (store, remote) = try await makeStore(role: .editor)
        let own = makeInvitation(id: invitationA, canRevoke: true)
        let other = makeInvitation(id: invitationB, canRevoke: false)
        await remote.enqueueInvitations(
            cursor: nil,
            page: SharedPlanInvitationPage(items: [own, other], nextCursor: nil)
        )
        try await store.refreshInvitations(planID: planID, limit: 50)

        do {
            _ = try await store.revokeInvitation(
                planID: planID,
                invitationID: invitationB
            )
            XCTFail("An editor must not revoke another member's invitation")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .insufficientRole)
        }
        do {
            _ = try await store.revokeInvitation(
                planID: planID,
                invitationID: "55555555-5555-4555-8555-555555555557"
            )
            XCTFail("A missing row must fail closed")
        } catch {
            XCTAssertEqual(error as? SharedPlanError, .insufficientRole)
        }

        _ = try await store.revokeInvitation(
            planID: planID,
            invitationID: invitationA
        )
        _ = try await store.createInvitation(
            planID: planID,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(
            store.pendingRESTWrites.map(\.kind),
            [.revokeInvitation, .createInvitation]
        )
    }

    func testActiveViewerCanCreateInvitationWithoutMembershipAdministration() async throws {
        let (store, _) = try await makeStore(role: .viewer)

        _ = try await store.createInvitation(
            planID: planID,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(store.pendingRESTWrites.map(\.kind), [.createInvitation])
    }

    func testNotificationE51LoadMoreCannotSkipE61RefreshInEitherCompletionOrder() async throws {
        for refreshCompletesFirst in [true, false] {
            let (store, remote) = try await makeStore()
            let initial = makeNotification(idCharacter: "a", createdAt: 100)
            let staleOlder = makeNotification(idCharacter: "b", createdAt: 50)
            let fresh = makeNotification(idCharacter: "c", createdAt: 110)
            await remote.enqueueNotifications(
                cursor: nil,
                page: SharedPlanNotificationPage(items: [initial], nextCursor: "E51")
            )
            try await store.refreshNotifications(limit: 50)

            let loadMore = Task { @MainActor in
                try await store.loadMoreNotifications(limit: 50)
            }
            await remote.waitForNotificationRequest(cursor: "E51")
            let refresh = Task { @MainActor in
                try await store.refreshNotifications(limit: 50)
            }
            await remote.waitForNotificationRequest(cursor: nil)

            if refreshCompletesFirst {
                await remote.resolveNotification(
                    cursor: nil,
                    page: SharedPlanNotificationPage(items: [fresh], nextCursor: "E61")
                )
                try await refresh.value
                await remote.resolveNotification(
                    cursor: "E51",
                    page: SharedPlanNotificationPage(items: [staleOlder], nextCursor: "E1")
                )
                try await loadMore.value
            } else {
                await remote.resolveNotification(
                    cursor: "E51",
                    page: SharedPlanNotificationPage(items: [staleOlder], nextCursor: "E1")
                )
                try await loadMore.value
                await remote.resolveNotification(
                    cursor: nil,
                    page: SharedPlanNotificationPage(items: [fresh], nextCursor: "E61")
                )
                try await refresh.value
            }

            XCTAssertEqual(store.notificationNextCursor, "E61")
            XCTAssertTrue(store.notifications.contains { $0.id == fresh.id })
            XCTAssertFalse(store.notifications.contains { $0.id == staleOlder.id })
        }
    }

    func testMemberRefreshSupersedesStaleLoadMoreInEitherCompletionOrder() async throws {
        for refreshCompletesFirst in [true, false] {
            let (store, remote) = try await makeStore()
            let initial = makeMember(userID: userA, name: "Initial", status: .active)
            let stale = makeMember(userID: userB, name: "Stale", status: .active)
            let authoritative = makeMember(
                userID: userA,
                name: "Removed authoritatively",
                status: .removed
            )
            await remote.enqueueMembers(
                cursor: nil,
                page: SharedPlanMemberPage(items: [initial], nextCursor: "members-E51")
            )
            try await store.refreshMembers(planID: planID, limit: 50)

            let loadMore = Task { @MainActor in
                try await store.loadMoreMembers(planID: self.planID, limit: 50)
            }
            await remote.waitForMemberRequest(cursor: "members-E51")
            let refresh = Task { @MainActor in
                try await store.refreshMembers(planID: self.planID, limit: 50)
            }
            await remote.waitForMemberRequest(cursor: nil)

            if refreshCompletesFirst {
                await remote.resolveMembers(
                    cursor: nil,
                    page: SharedPlanMemberPage(
                        items: [authoritative],
                        nextCursor: "members-E61"
                    )
                )
                try await refresh.value
                await remote.resolveMembers(
                    cursor: "members-E51",
                    page: SharedPlanMemberPage(items: [stale], nextCursor: "members-E1")
                )
                try await loadMore.value
            } else {
                await remote.resolveMembers(
                    cursor: "members-E51",
                    page: SharedPlanMemberPage(items: [stale], nextCursor: "members-E1")
                )
                try await loadMore.value
                await remote.resolveMembers(
                    cursor: nil,
                    page: SharedPlanMemberPage(
                        items: [authoritative],
                        nextCursor: "members-E61"
                    )
                )
                try await refresh.value
            }

            XCTAssertEqual(store.membersByPlanID[planID], [authoritative])
            XCTAssertEqual(store.memberNextCursorByPlanID[planID], "members-E61")
        }
    }

    func testInvitationRefreshSupersedesStaleLoadMoreInEitherCompletionOrder() async throws {
        for refreshCompletesFirst in [true, false] {
            let (store, remote) = try await makeStore()
            let initial = makeInvitation(id: invitationA, canRevoke: true)
            let stale = makeInvitation(id: invitationB, canRevoke: true)
            let revoked = makeInvitation(
                id: invitationA,
                canRevoke: false,
                revokedAt: Date(timeIntervalSince1970: 200)
            )
            await remote.enqueueInvitations(
                cursor: nil,
                page: SharedPlanInvitationPage(
                    items: [initial],
                    nextCursor: "invitations-E51"
                )
            )
            try await store.refreshInvitations(planID: planID, limit: 50)

            let loadMore = Task { @MainActor in
                try await store.loadMoreInvitations(planID: self.planID, limit: 50)
            }
            await remote.waitForInvitationRequest(cursor: "invitations-E51")
            let refresh = Task { @MainActor in
                try await store.refreshInvitations(planID: self.planID, limit: 50)
            }
            await remote.waitForInvitationRequest(cursor: nil)

            if refreshCompletesFirst {
                await remote.resolveInvitations(
                    cursor: nil,
                    page: SharedPlanInvitationPage(
                        items: [revoked],
                        nextCursor: "invitations-E61"
                    )
                )
                try await refresh.value
                await remote.resolveInvitations(
                    cursor: "invitations-E51",
                    page: SharedPlanInvitationPage(items: [stale], nextCursor: nil)
                )
                try await loadMore.value
            } else {
                await remote.resolveInvitations(
                    cursor: "invitations-E51",
                    page: SharedPlanInvitationPage(items: [stale], nextCursor: nil)
                )
                try await loadMore.value
                await remote.resolveInvitations(
                    cursor: nil,
                    page: SharedPlanInvitationPage(
                        items: [revoked],
                        nextCursor: "invitations-E61"
                    )
                )
                try await refresh.value
            }

            XCTAssertEqual(store.invitationsByPlanID[planID], [revoked])
            XCTAssertEqual(
                store.invitationNextCursorByPlanID[planID],
                "invitations-E61"
            )
        }
    }

    private func makeStore(
        role: SharedPlanRole = .owner
    ) async throws -> (SharedPlanStore, CollectionRaceRemote) {
        let plan = makePlan(role: role)
        let persistence = InMemorySharedPlanPersistence()
        try await persistence.savePlan(plan, write: nil)
        let remote = CollectionRaceRemote(plan: plan)
        let store = SharedPlanStore(
            persistence: persistence,
            remote: remote,
            actorUserID: { Self.userA }
        )
        await store.load()
        return (store, remote)
    }

    private func makePlan(role: SharedPlanRole = .owner) -> SharedPlan {
        SharedPlan(
            id: planID,
            name: "Race plan",
            comiketNo: 108,
            ownership: .owned,
            role: role,
            lifecycle: .active,
            revision: 1,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeMember(
        userID: String,
        name: String,
        status: SharedPlanMembershipStatus
    ) -> SharedPlanMember {
        SharedPlanMember(
            userID: userID,
            displayName: name,
            avatarURL: nil,
            role: userID == Self.userA ? .owner : .editor,
            membershipStatus: status,
            joinedAt: Date(timeIntervalSince1970: 1),
            removedAt: status == .removed ? Date(timeIntervalSince1970: 200) : nil
        )
    }

    private func makeInvitation(
        id: String,
        canRevoke: Bool,
        revokedAt: Date? = nil
    ) -> SharedPlanInvitation {
        SharedPlanInvitation(
            invitationID: id,
            createdByUserID: Self.userA,
            currentUserCanRevoke: canRevoke,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            revokedAt: revokedAt,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeNotification(
        idCharacter: Character,
        createdAt: TimeInterval
    ) -> SharedPlanNotificationItem {
        SharedPlanNotificationItem(
            id: String(repeating: String(idCharacter), count: 64),
            kind: .sharedPlanEvent,
            planID: planID,
            eventType: SharedPlanOperationType.circleMemoSplice.rawValue,
            i18nKey: "shared_plan.circle.memo.splice",
            payloadVersion: 1,
            payload: .operation(SharedPlanOperationNotificationPayload(
                v: 1,
                planID: planID,
                operationID: "22222222-2222-4222-8222-222222222222",
                operationType: .circleMemoSplice,
                actorUserID: Self.userA,
                payload: ["v": .integer(1), "wcID": .integer(1)],
                heads: [String(repeating: "a", count: 64)],
                membershipEpoch: 1
            )),
            createdAt: Date(timeIntervalSince1970: createdAt),
            readAt: nil
        )
    }

    private static let planID = "11111111-1111-4111-8111-111111111111"
    private static let userA = "00000000000000000000000000000001"
    private static let userB = "00000000000000000000000000000002"
    private static let invitationA = "55555555-5555-4555-8555-555555555555"
    private static let invitationB = "55555555-5555-4555-8555-555555555556"

    private var planID: String { Self.planID }
    private var userA: String { Self.userA }
    private var userB: String { Self.userB }
    private var invitationA: String { Self.invitationA }
    private var invitationB: String { Self.invitationB }
}

private actor CollectionRaceRemote: SharedPlanRemoteServicing {
    private let plan: SharedPlan
    private var queuedNotifications: [String: [SharedPlanNotificationPage]] = [:]
    private var queuedMembers: [String: [SharedPlanMemberPage]] = [:]
    private var queuedInvitations: [String: [SharedPlanInvitationPage]] = [:]
    private var notificationRequests:
        [String: CheckedContinuation<SharedPlanNotificationPage, Error>] = [:]
    private var memberRequests:
        [String: CheckedContinuation<SharedPlanMemberPage, Error>] = [:]
    private var invitationRequests:
        [String: CheckedContinuation<SharedPlanInvitationPage, Error>] = [:]
    private var notificationStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var memberStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var invitationStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(plan: SharedPlan) {
        self.plan = plan
    }

    func enqueueNotifications(cursor: String?, page: SharedPlanNotificationPage) {
        queuedNotifications[key(cursor), default: []].append(page)
    }

    func enqueueMembers(cursor: String?, page: SharedPlanMemberPage) {
        queuedMembers[key(cursor), default: []].append(page)
    }

    func enqueueInvitations(cursor: String?, page: SharedPlanInvitationPage) {
        queuedInvitations[key(cursor), default: []].append(page)
    }

    func waitForNotificationRequest(cursor: String?) async {
        let requestKey = key(cursor)
        guard notificationRequests[requestKey] == nil else { return }
        await withCheckedContinuation { continuation in
            notificationStartWaiters[requestKey, default: []].append(continuation)
        }
    }

    func waitForMemberRequest(cursor: String?) async {
        let requestKey = key(cursor)
        guard memberRequests[requestKey] == nil else { return }
        await withCheckedContinuation { continuation in
            memberStartWaiters[requestKey, default: []].append(continuation)
        }
    }

    func waitForInvitationRequest(cursor: String?) async {
        let requestKey = key(cursor)
        guard invitationRequests[requestKey] == nil else { return }
        await withCheckedContinuation { continuation in
            invitationStartWaiters[requestKey, default: []].append(continuation)
        }
    }

    func resolveNotification(cursor: String?, page: SharedPlanNotificationPage) {
        notificationRequests.removeValue(forKey: key(cursor))?.resume(returning: page)
    }

    func resolveMembers(cursor: String?, page: SharedPlanMemberPage) {
        memberRequests.removeValue(forKey: key(cursor))?.resume(returning: page)
    }

    func resolveInvitations(cursor: String?, page: SharedPlanInvitationPage) {
        invitationRequests.removeValue(forKey: key(cursor))?.resume(returning: page)
    }

    func fetchNotifications(
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanNotificationPage {
        let requestKey = key(cursor)
        if var pages = queuedNotifications[requestKey], !pages.isEmpty {
            let page = pages.removeFirst()
            queuedNotifications[requestKey] = pages
            return page
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(notificationRequests[requestKey] == nil)
            notificationRequests[requestKey] = continuation
            notificationStartWaiters.removeValue(forKey: requestKey)?.forEach {
                $0.resume()
            }
        }
    }

    func fetchMembers(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanMemberPage {
        let requestKey = key(cursor)
        if var pages = queuedMembers[requestKey], !pages.isEmpty {
            let page = pages.removeFirst()
            queuedMembers[requestKey] = pages
            return page
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(memberRequests[requestKey] == nil)
            memberRequests[requestKey] = continuation
            memberStartWaiters.removeValue(forKey: requestKey)?.forEach { $0.resume() }
        }
    }

    func fetchInvitations(
        planID: String,
        limit: Int,
        cursor: String?
    ) async throws -> SharedPlanInvitationPage {
        let requestKey = key(cursor)
        if var pages = queuedInvitations[requestKey], !pages.isEmpty {
            let page = pages.removeFirst()
            queuedInvitations[requestKey] = pages
            return page
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(invitationRequests[requestKey] == nil)
            invitationRequests[requestKey] = continuation
            invitationStartWaiters.removeValue(forKey: requestKey)?.forEach {
                $0.resume()
            }
        }
    }

    func fetchPlans() async throws -> [SharedPlan] { [plan] }

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

    private func key(_ cursor: String?) -> String { cursor ?? "<first>" }
}
