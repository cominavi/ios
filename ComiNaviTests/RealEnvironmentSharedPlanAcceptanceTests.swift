import Foundation
import XCTest

@testable import ComiNavi

/// Opt-in production acceptance that uses the preserved Simulator Keychain
/// session. Normal test runs do not touch production.
final class RealEnvironmentSharedPlanAcceptanceTests: XCTestCase {
    private static let acceptancePlanName = "[E2E] Shared Plan Lifecycle v1"
    private static let acceptancePlanRequestID = UUID(
        uuidString: "ca108000-0000-4000-8000-000000000006"
    )!
    private static let twoMemberPlanName = "[E2E] Shared Plan Two Member Sync v1"
    private static let twoMemberPlanRequestID = UUID(
        uuidString: "ca108000-0000-4000-8000-000000000008"
    )!

    func testProductionCreateListArchiveReopenLifecycleWhenExplicitlyRequired() async throws {
        guard ProcessInfo.processInfo.environment[
            "COMINAVI_E2E_SHARED_PLAN_LIFECYCLE_REQUIRED"
        ] == "1" else { return }

        let client = CominaviServiceClient.shared
        let expectedName = Self.acceptancePlanName
        let createRequestID = Self.acceptancePlanRequestID
        let created = try await client.createPlan(
            requestID: createRequestID,
            name: expectedName,
            comiketNo: 108
        )
        XCTAssertEqual(created.plan.name, expectedName)
        XCTAssertEqual(created.plan.comiketNo, 108)
        XCTAssertEqual(created.plan.role, .owner)
        XCTAssertNotNil(created.syncBootstrap)

        let planID = created.plan.id
        var current = try await Self.listedPlan(
            id: planID,
            using: client
        )
        XCTAssertEqual(current.name, expectedName)
        XCTAssertEqual(current.comiketNo, 108)

        if current.lifecycle == .archived {
            current = try await client.reopenPlan(
                id: planID,
                requestID: UUID(),
                baseRevision: current.revision
            ).plan
        }
        XCTAssertEqual(current.lifecycle, .active)

        let archived = try await client.archivePlan(
            id: planID,
            requestID: UUID(),
            baseRevision: current.revision
        ).plan
        XCTAssertEqual(archived.lifecycle, .archived)
        let listedArchived = try await Self.listedPlan(id: planID, using: client)
        XCTAssertEqual(listedArchived.lifecycle, .archived)

        let reopened = try await client.reopenPlan(
            id: planID,
            requestID: UUID(),
            baseRevision: archived.revision
        ).plan
        XCTAssertEqual(reopened.lifecycle, .active)
        let listedReopened = try await Self.listedPlan(id: planID, using: client)
        XCTAssertEqual(listedReopened.lifecycle, .active)

        // Keep repeatable production acceptance data outside the active-plan
        // quota while retaining the server-authoritative lifecycle evidence.
        let cleaned = try await client.archivePlan(
            id: planID,
            requestID: UUID(),
            baseRevision: reopened.revision
        ).plan
        XCTAssertEqual(cleaned.lifecycle, .archived)
        let listedCleaned = try await Self.listedPlan(id: planID, using: client)
        XCTAssertEqual(listedCleaned.lifecycle, .archived)
    }

    func testPrepareProductionInvitationCapabilityWhenExplicitlyRequired() async throws {
        guard ProcessInfo.processInfo.environment[
            "COMINAVI_E2E_SHARED_PLAN_INVITATION_REQUIRED"
        ] == "1" else { return }

        let client = CominaviServiceClient.shared
        let created = try await client.createPlan(
            requestID: Self.acceptancePlanRequestID,
            name: Self.acceptancePlanName,
            comiketNo: 108
        )
        var plan = try await Self.listedPlan(id: created.plan.id, using: client)
        if plan.lifecycle == .archived {
            plan = try await client.reopenPlan(
                id: plan.id,
                requestID: UUID(),
                baseRevision: plan.revision
            ).plan
        }
        XCTAssertEqual(plan.lifecycle, .active)

        // Invalidate older test capabilities before minting the one exported
        // below. This keeps repeat runs bounded without ever logging a token.
        var activeInvitations: [SharedPlanInvitation] = []
        var cursor: String?
        repeat {
            let page = try await client.fetchInvitations(
                planID: plan.id,
                limit: 100,
                cursor: cursor
            )
            activeInvitations.append(contentsOf: page.items.filter { invitation in
                invitation.currentUserCanRevoke
                    && invitation.revokedAt == nil
                    && invitation.expiresAt > Date()
            })
            cursor = page.nextCursor
        } while cursor != nil
        for invitation in activeInvitations {
            plan = try await client.revokeInvitation(
                planID: plan.id,
                invitationID: invitation.invitationID,
                requestID: UUID(),
                baseRevision: plan.revision
            ).plan
        }

        let invitation = try await client.createInvitation(
            planID: plan.id,
            requestID: UUID(),
            baseRevision: plan.revision,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(invitation.planID, plan.id)
        XCTAssertGreaterThan(invitation.expiresAt, Date())

        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let artifactDirectory = applicationSupport
            .appendingPathComponent("ComiNaviE2E", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let artifactURL = artifactDirectory
            .appendingPathComponent("shared-plan-invitation.json")
        let data = try JSONEncoder().encode(invitation)
        try data.write(to: artifactURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.complete,
            ],
            ofItemAtPath: artifactURL.path
        )
    }

    @MainActor
    func testProductionTwoMemberOfflineRelaunchConvergenceWhenExplicitlyRequired() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMINAVI_E2E_TWO_MEMBER_SYNC_REQUIRED"] == "1" else { return }

        let ownerSession = try decodeSession(
            environmentKey: "COMINAVI_E2E_OWNER_SESSION_BASE64"
        )
        let recipientSession = try decodeSession(
            environmentKey: "COMINAVI_E2E_RECIPIENT_SESSION_BASE64"
        )
        let ownerUserID = try XCTUnwrap(ownerSession.user?.id)
        let recipientUserID = try XCTUnwrap(recipientSession.user?.id)
        XCTAssertNotEqual(ownerUserID, recipientUserID)

        let ownerSessionStore = try acceptanceSessionStore(
            session: ownerSession,
            exportNameKey: "COMINAVI_E2E_OWNER_SESSION_EXPORT_NAME"
        )
        let recipientSessionStore = try acceptanceSessionStore(
            session: recipientSession,
            exportNameKey: "COMINAVI_E2E_RECIPIENT_SESSION_EXPORT_NAME"
        )
        let ownerClient = CominaviServiceClient(
            sessionStore: ownerSessionStore,
            authenticationFlowCanceller: {}
        )
        let recipientClient = CominaviServiceClient(
            sessionStore: recipientSessionStore,
            authenticationFlowCanceller: {}
        )

        var plan = try await ownerClient.createPlan(
            requestID: Self.twoMemberPlanRequestID,
            name: Self.twoMemberPlanName,
            comiketNo: 108
        ).plan
        plan = try await Self.listedPlan(id: plan.id, using: ownerClient)
        if plan.lifecycle == .archived {
            plan = try await ownerClient.reopenPlan(
                id: plan.id,
                requestID: UUID(),
                baseRevision: plan.revision
            ).plan
        }

        let recipientAlreadyJoined = try await recipientClient.fetchPlans().contains {
            $0.id == plan.id && $0.lifecycle == .active
        }
        if !recipientAlreadyJoined {
            let invitation = try await ownerClient.createInvitation(
                planID: plan.id,
                requestID: UUID(),
                baseRevision: plan.revision,
                expiresAt: Date().addingTimeInterval(60 * 60)
            )
            let accepted = try await recipientClient.acceptInvitation(
                token: invitation.token,
                requestID: UUID()
            )
            XCTAssertEqual(accepted.plan.id, plan.id)
            plan = try await Self.listedPlan(id: plan.id, using: ownerClient)
        }

        let startedAt = Date().addingTimeInterval(-1)
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cominavi-two-member-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let ownerDatabase = workDirectory.appendingPathComponent("owner.sqlite")
        let recipientDatabase = workDirectory.appendingPathComponent("recipient.sqlite")
        let ownerTransportDiagnostics = AcceptanceTransportDiagnostics(label: "owner")
        let recipientTransportDiagnostics = AcceptanceTransportDiagnostics(label: "recipient")
        let ownerConnector = AcceptanceRecordingConnector(
            diagnostics: ownerTransportDiagnostics
        )
        let recipientConnector = AcceptanceRecordingConnector(
            diagnostics: recipientTransportDiagnostics
        )
        let ownerStore = SharedPlanStore(
            persistence: try SQLiteSharedPlanPersistence(path: ownerDatabase.path),
            remote: ownerClient,
            syncRequestAuthorizer: ownerClient,
            syncConnector: ownerConnector,
            actorUserID: { ownerUserID }
        )
        var recipientStore = SharedPlanStore(
            persistence: try SQLiteSharedPlanPersistence(path: recipientDatabase.path),
            remote: recipientClient,
            syncRequestAuthorizer: recipientClient,
            syncConnector: recipientConnector,
            actorUserID: { recipientUserID }
        )
        await ownerStore.load()
        await recipientStore.load()
        await ownerStore.refresh()
        await recipientStore.refresh()
        XCTAssertTrue(ownerStore.plans.contains { $0.id == plan.id })
        XCTAssertTrue(recipientStore.plans.contains { $0.id == plan.id })
        await ownerStore.startSync(planID: plan.id)
        await recipientStore.startSync(planID: plan.id)
        try await requireEventually(
            "both members did not reach writable sync",
            diagnostics: {
                let ownerIssue = ownerStore.issueMessage ?? "nil"
                let recipientIssue = recipientStore.issueMessage ?? "nil"
                let ownerTransport = await ownerTransportDiagnostics.summary()
                let recipientTransport = await recipientTransportDiagnostics.summary()
                return "ownerStatus=\(String(reflecting: ownerStore.syncStatuses[plan.id])); "
                    + "ownerIssue=\(ownerIssue); "
                    + "ownerTransport=\(ownerTransport); "
                    + "recipientStatus=\(String(reflecting: recipientStore.syncStatuses[plan.id])); "
                    + "recipientIssue=\(recipientIssue); "
                    + "recipientTransport=\(recipientTransport)"
            }
        ) {
            ownerStore.syncStatuses[plan.id]?.permitsContentMutations == true
                && recipientStore.syncStatuses[plan.id]?.permitsContentMutations == true
                && ownerStore.documentSnapshots[plan.id]?.offlineMutationAuthority == true
                && recipientStore.documentSnapshots[plan.id]?.offlineMutationAuthority == true
        }

        await recipientStore.stopSync(planID: plan.id)
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: plan.comiketNo, wcID: 90_108)
        )
        if try await recipientStore.circleContent(circle: circle, planID: plan.id)?.presence
            == .present
        {
            let removedOffline = try await recipientStore.removeCircle(circle, from: plan.id)
            XCTAssertTrue(removedOffline)
        }
        let addedOffline = try await recipientStore.addCircle(circle, to: plan.id)
        XCTAssertTrue(addedOffline)
        let runValue = UUID().uuidString.lowercased()
        let expectedMemo = "offline-relaunch-共同編集-\(runValue)"
        let updatedMemoOffline = try await recipientStore.updateMemo(
            expectedMemo,
            circle: circle,
            planID: plan.id
        )
        XCTAssertTrue(updatedMemoOffline)
        XCTAssertGreaterThan(
            recipientStore.documentSnapshots[plan.id]?.pendingOperationIDs.count ?? 0,
            0
        )

        // Reconstruct the Store and SQLite reader to model a process death.
        // The exact replica-bound authority must survive; no test-only
        // unconnected-mutation bypass is injected.
        recipientStore = SharedPlanStore(
            persistence: try SQLiteSharedPlanPersistence(path: recipientDatabase.path),
            remote: recipientClient,
            syncRequestAuthorizer: recipientClient,
            syncConnector: recipientConnector,
            actorUserID: { recipientUserID }
        )
        await recipientStore.load()
        let updatedAfterRelaunch = try await recipientStore.setCommunication(
            .string(runValue),
            field: "acceptance",
            circle: circle,
            planID: plan.id
        )
        XCTAssertTrue(updatedAfterRelaunch)
        await recipientStore.startSync(planID: plan.id)

        try await requireEventually("offline operations did not converge after reconnect") {
            guard recipientStore.syncStatuses[plan.id]?.permitsContentMutations == true,
                  recipientStore.documentSnapshots[plan.id]?.pendingOperationIDs.isEmpty == true,
                  let ownerCircle = try? await ownerStore.circleContent(
                      circle: circle,
                      planID: plan.id
                  )
            else { return false }
            return ownerCircle.memo == expectedMemo
                && ownerCircle.communicationState["acceptance"] == .string(runValue)
        }

        let ownerNotifications = try await ownerClient.fetchNotifications(limit: 100)
        let recipientNotifications = try await recipientClient.fetchNotifications(limit: 100)
        XCTAssertTrue(ownerNotifications.items.contains {
            $0.planID == plan.id && $0.createdAt >= startedAt
        })
        XCTAssertTrue(recipientNotifications.items.contains {
            $0.planID == plan.id && $0.createdAt >= startedAt
        })

        await recipientStore.stopSync(planID: plan.id)
        await ownerStore.stopSync(planID: plan.id)
        let current = try await Self.listedPlan(id: plan.id, using: ownerClient)
        if current.lifecycle == .active {
            let archived = try await ownerClient.archivePlan(
                id: current.id,
                requestID: UUID(),
                baseRevision: current.revision
            ).plan
            XCTAssertEqual(archived.lifecycle, .archived)
        }
    }

    func testPrepareProductionInvitationRevocationAndExpiryWhenExplicitlyRequired() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMINAVI_E2E_INVITATION_TERMINAL_STATES_REQUIRED"] == "1"
        else { return }

        let ownerSession = try decodeSession(
            environmentKey: "COMINAVI_E2E_OWNER_SESSION_BASE64"
        )
        let ownerSessionStore = try acceptanceSessionStore(
            session: ownerSession,
            exportNameKey: "COMINAVI_E2E_OWNER_SESSION_EXPORT_NAME"
        )
        let ownerClient = CominaviServiceClient(
            sessionStore: ownerSessionStore,
            authenticationFlowCanceller: {}
        )
        let invitationData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(
            environment["COMINAVI_E2E_INVITATION_BASE64"]
        )))
        // The protected invitation artifact is emitted above with the default
        // JSONEncoder date representation. Decode that exact local contract;
        // backend wire dates remain ISO-8601 inside CominaviServiceClient.
        let decoder = JSONDecoder()
        let original = try decoder.decode(
            SharedPlanCreatedInvitation.self,
            from: invitationData
        )
        var plan = try await Self.listedPlan(id: original.planID, using: ownerClient)
        if plan.lifecycle == .archived {
            plan = try await ownerClient.reopenPlan(
                id: plan.id,
                requestID: UUID(),
                baseRevision: plan.revision
            ).plan
        }

        var matchingInvitation: SharedPlanInvitation?
        var cursor: String?
        repeat {
            let page = try await ownerClient.fetchInvitations(
                planID: plan.id,
                limit: 100,
                cursor: cursor
            )
            matchingInvitation = matchingInvitation ?? page.items.first {
                $0.invitationID == original.invitationID
            }
            cursor = page.nextCursor
        } while cursor != nil
        if let matchingInvitation,
           matchingInvitation.revokedAt == nil,
           matchingInvitation.expiresAt > Date()
        {
            plan = try await ownerClient.revokeInvitation(
                planID: plan.id,
                invitationID: matchingInvitation.invitationID,
                requestID: UUID(),
                baseRevision: plan.revision
            ).plan
        }

        let expiring = try await ownerClient.createInvitation(
            planID: plan.id,
            requestID: UUID(),
            baseRevision: plan.revision,
            expiresAt: Date().addingTimeInterval(5)
        )
        plan = try await Self.listedPlan(id: plan.id, using: ownerClient)
        let replacement = try await ownerClient.createInvitation(
            planID: plan.id,
            requestID: UUID(),
            baseRevision: plan.revision,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        )
        try await Task.sleep(for: .seconds(6))

        do {
            _ = try await ownerClient.previewInvitation(token: original.token)
            XCTFail("The revoked invitation remained previewable")
        } catch {}
        do {
            _ = try await ownerClient.previewInvitation(token: expiring.token)
            XCTFail("The expired invitation remained previewable")
        } catch {}

        let terminalArtifact = InvitationTerminalStateArtifact(
            planName: plan.name,
            revokedURL: original.canonicalURL,
            expiredURL: expiring.canonicalURL
        )
        try writeProtectedJSON(
            terminalArtifact,
            exportNameKey: "COMINAVI_E2E_INVITATION_TERMINAL_EXPORT_NAME"
        )
        try writeProtectedJSON(
            replacement,
            exportNameKey: "COMINAVI_E2E_INVITATION_REPLACEMENT_EXPORT_NAME"
        )
    }

    private static func listedPlan(
        id: String,
        using client: CominaviServiceClient
    ) async throws -> SharedPlan {
        let plans = try await client.fetchPlans()
        return try XCTUnwrap(plans.first { $0.id == id })
    }

    private func decodeSession(environmentKey: String) throws -> CominaviAuthenticationSession {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment[environmentKey])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CominaviAuthenticationSession.self, from: data)
    }

    private func acceptanceSessionStore(
        session: CominaviAuthenticationSession,
        exportNameKey: String
    ) throws -> AcceptanceSessionStore {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment[exportNameKey])
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              !name.isEmpty
        else { throw SharedPlanError.persistenceFailed }
        let support = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let directory = support.appendingPathComponent(
            "CominaviE2EExports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try AcceptanceSessionStore(
            session: session,
            exportURL: directory.appendingPathComponent(name)
        )
    }

    private func writeProtectedJSON<Value: Encodable>(
        _ value: Value,
        exportNameKey: String
    ) throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment[exportNameKey])
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              !name.isEmpty
        else { throw SharedPlanError.persistenceFailed }
        let support = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let directory = support.appendingPathComponent(
            "CominaviE2EExports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.complete,
            ],
            ofItemAtPath: url.path
        )
    }

    @MainActor
    private func requireEventually(
        _ message: String,
        timeout: Duration = .seconds(30),
        diagnostics: @escaping @MainActor () async -> String = { "" },
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let detail = await diagnostics()
        XCTFail(detail.isEmpty ? message : "\(message): \(detail)")
        throw SharedPlanError.syncProtocolViolation
    }
}

private struct InvitationTerminalStateArtifact: Codable {
    let planName: String
    let revokedURL: URL
    let expiredURL: URL
}

private actor AcceptanceTransportDiagnostics {
    private let label: String
    private var events: [String] = []

    init(label: String) {
        self.label = label
    }

    func record(_ event: String) {
        guard events.count < 40 else { return }
        events.append(event)
    }

    func summary() -> String {
        "\(label)[\(events.joined(separator: ","))]"
    }
}

private struct AcceptanceRecordingConnector: SharedPlanSyncConnecting {
    private let base = NetworkFrameworkSharedPlanSyncConnector()
    private let diagnostics: AcceptanceTransportDiagnostics

    init(diagnostics: AcceptanceTransportDiagnostics) {
        self.diagnostics = diagnostics
    }

    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket {
        do {
            let socket = try await base.connect(request: request)
            await diagnostics.record("connect")
            return AcceptanceRecordingSocket(base: socket, diagnostics: diagnostics)
        } catch {
            await diagnostics.record("connect-error:\(Self.errorCode(error))")
            throw error
        }
    }

    fileprivate static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        let streamDomain = value.userInfo["_kCFStreamErrorDomainKey"] ?? "nil"
        let streamCode = value.userInfo["_kCFStreamErrorCodeKey"] ?? "nil"
        return "\(value.domain):\(value.code)"
            + "/stream:\(streamDomain):\(streamCode)"
            + "/underlying:\(underlying?.domain ?? "nil"):\(underlying?.code ?? 0)"
    }
}

private actor AcceptanceRecordingSocket: SharedPlanSyncSocket {
    private let base: any SharedPlanSyncSocket
    private let diagnostics: AcceptanceTransportDiagnostics

    init(base: any SharedPlanSyncSocket, diagnostics: AcceptanceTransportDiagnostics) {
        self.base = base
        self.diagnostics = diagnostics
    }

    func send(_ data: Data) async throws {
        do {
            try await base.send(data)
            await diagnostics.record("send:\(Self.messageType(data)):\(data.count)")
        } catch {
            await diagnostics.record(
                "send-error:\(AcceptanceRecordingConnector.errorCode(error))"
            )
            throw error
        }
    }

    func receive() async throws -> Data {
        do {
            let data = try await base.receive()
            await diagnostics.record("receive:\(Self.messageType(data)):\(data.count)")
            return data
        } catch {
            await diagnostics.record(
                "receive-error:\(AcceptanceRecordingConnector.errorCode(error))"
            )
            throw error
        }
    }

    func close() async {
        await diagnostics.record("close")
        await base.close()
    }

    private static func messageType(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return "unknown" }
        return type
    }
}

private final class AcceptanceSessionStore: CominaviAuthenticationSessionPersisting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let exportURL: URL
    private var session: CominaviAuthenticationSession?
    private var boundUserID: String?

    init(session: CominaviAuthenticationSession, exportURL: URL) throws {
        self.session = session
        boundUserID = session.user?.id
        self.exportURL = exportURL
        try persist(session)
    }

    func load() -> CominaviAuthenticationSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    @discardableResult
    func save(_ session: CominaviAuthenticationSession?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try persist(session)
            self.session = session
            return true
        } catch {
            return false
        }
    }

    func loadBoundUserID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return boundUserID
    }

    @discardableResult
    func saveBoundUserID(_ userID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        boundUserID = userID
        return true
    }

    func loadState() -> CominaviAuthenticationStorageState {
        lock.lock()
        defer { lock.unlock() }
        return CominaviAuthenticationStorageState(
            session: session,
            boundUserID: boundUserID,
            pendingLogout: nil,
            pendingAccountDeletion: nil,
            pendingAccountDeletionCleanup: nil,
            requiresExplicitAuthentication: false,
            isLoggedOut: false,
            isAvailable: true
        )
    }

    private func persist(_ session: CominaviAuthenticationSession?) throws {
        guard let session else { throw SharedPlanError.persistenceFailed }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: exportURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.complete,
            ],
            ofItemAtPath: exportURL.path
        )
    }
}
