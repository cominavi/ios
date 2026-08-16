//
//  AppDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/1/24.
//

import Foundation
import Observation
import PostHog
import Security
import Sentry

@MainActor
enum AppData {
    private static var serviceAuthenticationSessionStore:
        KeychainCominaviAuthenticationSessionStore
    {
        KeychainCominaviAuthenticationSessionStore(
            account: AppEnvironment.current.storageNamespace
        )
    }
    private static let serviceAuthenticationState =
        serviceAuthenticationSessionStore.loadState()
    static let catalogLibrary = CatalogLibrary()
    static let favoriteColorLabelStore = FavoriteColorLabelStore()
    static let sharedLocationInbox = SharedLocationInbox()
    static let sharedLocationClipboardImporter = SharedLocationClipboardImporter()
    static let sharedPlanInvitationInbox = SharedPlanInvitationInbox(
        storage: KeychainSharedPlanInvitationSecretStore(
            account: "route.\(AppEnvironment.current.storageNamespace)"
        )
    )
    static let profileStore: CominaviProfileStore = {
        let store = CominaviProfileStore(
            service: CominaviServiceClient.shared,
            storageKey: "cominavi.profile.v1.\(AppEnvironment.current.storageNamespace)",
            expectedUserID: serviceAuthenticationState.isAvailable
                && !serviceAuthenticationState.isLoggedOut
                ? serviceAuthenticationState.boundUserID
                : nil,
            initialRequiresReauthentication: serviceAuthenticationState.isAvailable
                && serviceAuthenticationState.requiresExplicitAuthentication
                && !serviceAuthenticationState.isLoggedOut,
            mutationPersistence: FileCominaviProfileMutationStore(
                directory: DirectoryManager.shared.environmentApplicationSupportDirectory
                    .appendingPathComponent("ProfileMutations", isDirectory: true)
            )
        )
        CominaviAuthenticationInvalidationCenter.handler = { [weak store] error in
            store?.invalidateIdentityVerification(issueMessage: error?.localizedDescription)
        }
        return store
    }()
    private static let unauthenticatedSharedPlanStore = SharedPlanStore(
        persistence: InMemorySharedPlanPersistence(),
        actorUserID: { nil }
    )
    private static var scopedSharedPlanStore: SharedPlanStore?
    private static var scopedSharedPlanUserID: String?

    static var sharedPlanStore: SharedPlanStore {
        guard profileStore.isIdentityVerified,
              let userID = profileStore.profile?.id
        else {
            return unauthenticatedSharedPlanStore
        }
        return sharedPlanStore(for: userID)
    }

    static func sharedPlanStore(for userID: String) -> SharedPlanStore {
        guard !userID.isEmpty,
              profileStore.isIdentityVerified,
              profileStore.profile?.id == userID
        else { return unauthenticatedSharedPlanStore }
        if scopedSharedPlanUserID == userID, let scopedSharedPlanStore {
            return scopedSharedPlanStore
        }
        let store = SharedPlanStore.live(
            userID: userID,
            remote: CominaviServiceClient.shared,
            syncRequestAuthorizer: CominaviServiceClient.shared
        ) {
            profileStore.isIdentityVerified && profileStore.profile?.id == userID
                ? userID
                : nil
        }
        scopedSharedPlanUserID = userID
        scopedSharedPlanStore = store
        return store
    }

    static func clearSharedPlanUserData() async {
        if let scopedSharedPlanStore {
            await scopedSharedPlanStore.clearUserData()
        }
        scopedSharedPlanStore = nil
        scopedSharedPlanUserID = nil
    }

    static var isAccountDeletionPending: Bool {
        let state = serviceAuthenticationSessionStore.loadState()
        return state.isAvailable
            && (state.pendingAccountDeletion != nil
                || state.pendingAccountDeletionCleanup != nil)
    }

    /// Completes the local half of an acknowledged account deletion. The
    /// protected cleanup receipt is intentionally cleared last by the service
    /// actor, so process death at any earlier await simply repeats this
    /// idempotent, public-user-scoped cleanup on the next launch.
    @discardableResult
    static func finishAccountDeletionLocalCleanupIfNeeded() async throws -> Bool {
        guard let receipt = await CominaviServiceClient.shared
            .accountDeletionCleanupReceipt(),
              let requestID = receipt.requestID
        else { return false }
        try await clearDeletedAccountUserData(publicUserID: receipt.publicUserID)
        try await CominaviServiceClient.shared.acknowledgeAccountDeletionLocalCleanup(
            requestID: requestID
        )
        return true
    }

    private static func clearDeletedAccountUserData(publicUserID: String) async throws {
        _ = try DirectoryManager.accountDirectoryName(publicUserID: publicUserID)
        try await clearPendingAuthenticationFlowsForLogout()
        guard circlemsSessionStore.save(nil) else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        userState.installPersistedUser(nil)
        await clearSharedPlanUserData()
        profileStore.clear()
        catalogLibrary.reset()
        sharedPlanInvitationInbox.clear()

        let baseDirectory = DirectoryManager.shared.environmentApplicationSupportDirectory
        try await clearDeletedAccountSharedPlanInvitationSecrets(
            publicUserID: publicUserID,
            baseDirectory: baseDirectory
        )
        try await Task.detached(priority: .utility) {
            try DirectoryManager.shared.removeApplicationSupportData(
                publicUserID: publicUserID,
                in: baseDirectory
            )
        }.value
        await GoogleSignInIDTokenProvider.disconnect()
    }

    static func clearDeletedAccountSharedPlanInvitationSecrets(
        publicUserID: String,
        baseDirectory: URL = DirectoryManager.shared.environmentApplicationSupportDirectory
    ) async throws {
        _ = try DirectoryManager.accountDirectoryName(publicUserID: publicUserID)
        let databaseURL = SharedPlanStore.databaseURL(
            baseDirectory: baseDirectory,
            userID: publicUserID
        )
        let account = "\(AppEnvironment.current.storageNamespace).\(databaseURL.lastPathComponent)"
        let inviteVault = KeychainSharedPlanInviteCapabilityVault(
            account: account
        )
        let createdInvitationVault = KeychainSharedPlanCreatedInvitationVault(
            account: account
        )
        try await inviteVault.removeAll()
        try await createdInvitationVault.removeAll()
    }

    /// Transitional access for catalog consumers that have not yet adopted
    /// explicit data-source injection.
    public static var circlems: CirclemsDataSource! {
        catalogLibrary.dataSource
    }

    private static var circlemsSessionStore: CirclemsSessionStore {
        CirclemsSessionStore(account: AppEnvironment.current.storageNamespace)
    }

    private static var circlemsAuthorizationFlowStore: KeychainCirclemsAuthorizationFlowStore {
        KeychainCirclemsAuthorizationFlowStore(
            account: AppEnvironment.current.storageNamespace
        )
    }

    private static var circlemsClientInstanceIDStore: KeychainCirclemsClientInstanceIDStore {
        KeychainCirclemsClientInstanceIDStore(
            account: AppEnvironment.current.storageNamespace
        )
    }

    private static var googleAuthenticationFlowStore: KeychainGoogleAuthenticationFlowStore {
        KeychainGoogleAuthenticationFlowStore(
            account: AppEnvironment.current.storageNamespace
        )
    }

    private static var appleAuthenticationFlowStore: KeychainAppleAuthenticationFlowStore {
        KeychainAppleAuthenticationFlowStore(
            account: AppEnvironment.current.storageNamespace
        )
    }

    static func prepareGoogleAuthenticationFlow(
        entryContext: GoogleAuthenticationFlow.EntryContext
    ) throws -> GoogleAuthenticationFlow {
        try requireNoPendingTermination()
        return try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStore
        ).prepare(entryContext: entryContext)
    }

    static func pendingGoogleAuthenticationFlow() throws -> GoogleAuthenticationFlow? {
        try requireNoPendingTermination()
        return try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStore
        ).load()
    }

    static func clearGoogleAuthenticationFlow() throws {
        try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStore
        ).clear()
    }

    static func prepareAppleAuthenticationFlow(
        entryContext: AppleAuthenticationFlow.EntryContext
    ) throws -> AppleAuthenticationFlow {
        try requireNoPendingTermination()
        return try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStore
        ).prepare(entryContext: entryContext)
    }

    static func pendingAppleAuthenticationFlow() throws -> AppleAuthenticationFlow? {
        try requireNoPendingTermination()
        return try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStore
        ).load()
    }

    static func clearAppleAuthenticationFlow() throws {
        try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStore
        ).clear()
    }

    /// Explicit logout/deletion cancels every protected provider-auth
    /// capability before its durable tombstone can be acknowledged.
    static func clearPendingAuthenticationFlowsForLogout() async throws {
        try clearCirclemsAuthorizationFlow()
        try clearGoogleAuthenticationFlow()
        try clearAppleAuthenticationFlow()
    }

    private static func requireNoPendingTermination() throws {
        let state = serviceAuthenticationSessionStore.loadState()
        guard state.isAvailable else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        guard state.pendingLogout == nil else {
            throw CominaviServiceError.logoutPending
        }
        guard state.pendingAccountDeletion == nil else {
            throw CominaviServiceError.accountDeletionPending
        }
        guard state.pendingAccountDeletionCleanup == nil else {
            throw CominaviServiceError.accountDeletionPending
        }
    }

    static func prepareCirclemsAuthorizationFlow(
        purpose: CirclemsAuthorizationFlow.Purpose,
        expectedPublicUserID: String? = nil
    ) throws -> CirclemsAuthorizationFlow {
        try requireNoPendingTermination()
        let clientInstanceID = try circlemsClientInstanceIDStore.loadOrCreate()
        return try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStore
        ).prepare(
            purpose: purpose,
            environment: AppEnvironment.current.circlems,
            clientInstanceID: clientInstanceID,
            expectedPublicUserID: expectedPublicUserID
        )
    }

    @discardableResult
    static func receiveCirclemsAuthorizationCallback(_ url: URL) -> Bool {
        guard CirclemsAuthorizationCallbackParser.isCallbackURL(
            url,
            callbackScheme: AppEnvironment.current.oauthCallbackScheme
        ) else { return false }
        let callbackScheme = AppEnvironment.current.oauthCallbackScheme
        Task {
            // The service actor serializes capability publication with logout.
            // Malformed/stale callbacks are still consumed by this route.
            try? await CominaviServiceClient.shared
                .recordPendingCirclemsAuthorizationCallback(
                    url,
                    callbackScheme: callbackScheme
                )
        }
        return true
    }

    static func pendingCirclemsAuthorizationFlow() throws -> CirclemsAuthorizationFlow? {
        try requireNoPendingTermination()
        return try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStore
        ).load()
    }

    static func clearCirclemsAuthorizationFlow() throws {
        try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStore
        ).clear()
    }

    /// Finishes the backend-owned OAuth handoff. No Circle.ms provider token
    /// enters this path: only the non-secret receipt revision is retained, and
    /// any legacy on-device provider credential is scrubbed before the PKCE
    /// verifier/completion capability is deleted.
    static func finalizeCirclemsAuthorizationFlow(
        _ flow: CirclemsAuthorizationFlow,
        receipt: CirclemsCredentialReceipt,
        profile: CominaviUserProfile
    ) throws {
        guard receipt.requestID == flow.requestID,
              receipt.clientInstanceID == flow.clientInstanceID,
              receipt.environment == flow.environment.apiValue,
              flow.expectedPublicUserID == nil || flow.expectedPublicUserID == profile.id
        else { throw CominaviServiceError.invalidResponse }
        try persistCirclemsReceiptAndScrubLegacyCredential(
            receipt,
            profile: profile
        )
        try clearCirclemsAuthorizationFlow()
        userState.installPersistedUser(nil)
    }

    /// Repairs the narrow crash window after the service session/profile was
    /// durably installed but before legacy provider bytes and the one-time
    /// completion flow were cleared. The validated receipt was committed in
    /// the same protected blob as the service session, so relaunch can finish
    /// local scrubbing without touching the backend again.
    @discardableResult
    static func recoverCompletedCirclemsAuthorizationFlow(
        _ persisted: CirclemsPersistedAuthorizationCompletion
    ) throws -> Bool {
        let receipt = persisted.marker.credentialReceipt
        guard receipt.requestID == persisted.marker.flowRequestID,
              receipt.clientInstanceID != nil
        else {
            throw CominaviServiceError.invalidResponse
        }
        try persistCirclemsReceiptAndScrubLegacyCredential(
            receipt,
            profile: persisted.profile
        )
        if let flow = try pendingCirclemsAuthorizationFlow(),
           flow.requestID == persisted.marker.flowRequestID
        {
            try clearCirclemsAuthorizationFlow()
        }
        userState.installPersistedUser(nil)
        return true
    }

    private static func persistCirclemsReceiptAndScrubLegacyCredential(
        _ receipt: CirclemsCredentialReceipt,
        profile: CominaviUserProfile
    ) throws {
        guard receipt.provider == "circlems",
              receipt.credentialRevision > 0,
              profile.identities.contains(where: {
                  $0.provider == "circlems"
                      && $0.environment == receipt.environment
                      && $0.providerUserID == receipt.subject
              })
        else { throw CominaviServiceError.invalidResponse }
        let coordinator = CirclemsCredentialTransferCoordinator(storage: circlemsSessionStore)
        try coordinator.scrubBackendOwnedCredential(receipt)
    }

    // Remove this after existing installs have had enough time to migrate their session.
    private static var legacyUser: User? {
        get {
            UserDefaultsBacked<User?>(legacyUserDefaultsKey).wrappedValue
        }
        set {
            var storage = UserDefaultsBacked<User?>(legacyUserDefaultsKey)
            storage.wrappedValue = newValue
        }
    }

    private static var legacyUserDefaultsKey: String {
        "circlems.user.\(AppEnvironment.current.storageNamespace)"
    }

    static var user: User? {
        get {
            if let user = circlemsSessionStore.load() {
                return user
            }

            guard let legacyUser else {
                return nil
            }

            if circlemsSessionStore.save(legacyUser) {
                self.legacyUser = nil
            }
            return legacyUser
        }
        set {
            if circlemsSessionStore.save(newValue) {
                legacyUser = nil
            }
        }
    }

    static let userState = UserState()

    public static func getUserToken() async -> String {
        availableCirclemsAccessToken(for: userState.user)
    }

    nonisolated static func availableCirclemsAccessToken(
        for user: User?,
        now: Date = Date()
    ) -> String {
        guard let user,
              let expiresAt = user.accessTokenExpiresAt,
              expiresAt > now,
              let accessToken = user.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else { return "" }
        return accessToken
    }
}

struct User: Codable, Sendable {
    var accessToken: String?
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
    var userId: Int?
    var nickname: String?
    var preferenceR18Enabled: Bool?
    var circlemsCredentialTransfer: CirclemsCredentialTransfer? = nil
    var circlemsCredentialRevision: Int? = nil
}

struct CirclemsCredentialReceipt: Codable, Equatable, Sendable {
    let requestID: UUID
    let clientInstanceID: UUID?
    let provider: String
    let environment: String
    let subject: String
    let credentialRevision: Int

    init(
        requestID: UUID,
        clientInstanceID: UUID? = nil,
        provider: String,
        environment: String,
        subject: String,
        credentialRevision: Int
    ) {
        self.requestID = requestID
        self.clientInstanceID = clientInstanceID
        self.provider = provider
        self.environment = environment
        self.subject = subject
        self.credentialRevision = credentialRevision
    }
}

struct CirclemsCredentialTransfer: Codable, Equatable, Sendable {
    enum Purpose: String, Codable, Sendable {
        case authenticate
        case link
    }

    enum State: String, Codable, Sendable {
        case pending
        case acknowledged
    }

    let requestID: UUID
    let purpose: Purpose
    let environment: CirclemsServiceEnvironment
    let accessToken: String?
    let refreshToken: String?
    let accessExpiresAt: Int?
    let baseCredentialRevision: Int?
    let state: State
    let receipt: CirclemsCredentialReceipt?

    func acknowledged(with receipt: CirclemsCredentialReceipt) -> Self {
        Self(
            requestID: requestID,
            purpose: purpose,
            environment: environment,
            accessToken: nil,
            refreshToken: nil,
            accessExpiresAt: nil,
            baseCredentialRevision: baseCredentialRevision,
            state: .acknowledged,
            receipt: receipt
        )
    }
}

protocol CirclemsUserSessionPersisting: Sendable {
    func loadForCredentialTransfer() throws -> User?
    @discardableResult func save(_ user: User?) -> Bool
    func loadCredentialRevision(environment: String, subject: String) throws -> Int?
    @discardableResult func saveCredentialRevision(
        _ revision: Int,
        environment: String,
        subject: String
    ) -> Bool
}

@MainActor
final class CirclemsCredentialTransferCoordinator {
    private let storage: any CirclemsUserSessionPersisting
    private(set) var user: User?

    init(storage: any CirclemsUserSessionPersisting) {
        self.storage = storage
    }

    func pendingTransfer() throws -> CirclemsCredentialTransfer? {
        try reload()
        guard let transfer = user?.circlemsCredentialTransfer else { return nil }
        if transfer.state == .acknowledged {
            var cleaned = user
            cleaned?.circlemsCredentialTransfer = nil
            try persist(cleaned)
            return nil
        }
        return transfer
    }

    func hasIncompleteTransfer() throws -> Bool {
        try reload()
        return user?.circlemsCredentialTransfer != nil
    }

    func prepare(
        purpose: CirclemsCredentialTransfer.Purpose,
        environment: CirclemsServiceEnvironment
    ) throws -> CirclemsCredentialTransfer {
        try reload()
        if let existing = user?.circlemsCredentialTransfer {
            guard existing.state == .pending,
                  existing.purpose == purpose,
                  existing.environment == environment
            else { throw CominaviServiceError.circlemsCredentialTransferPending }
            return existing
        }
        guard let current = user,
              let accessToken = current.accessToken,
              !accessToken.isEmpty,
              let refreshToken = current.refreshToken,
              !refreshToken.isEmpty
        else { throw CominaviServiceError.notLoggedIn }
        let accessExpiresAt = current.accessTokenExpiresAt.map {
            Int($0.timeIntervalSince1970.rounded(.down))
        }
        let retainedRevision: Int?
        if let providerUserID = current.userId {
            retainedRevision = try storage.loadCredentialRevision(
                environment: environment.apiValue,
                subject: String(providerUserID)
            )
        } else {
            retainedRevision = nil
        }
        let transfer = CirclemsCredentialTransfer(
            requestID: UUID(),
            purpose: purpose,
            environment: environment,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: accessExpiresAt,
            baseCredentialRevision: current.circlemsCredentialRevision ?? retainedRevision,
            state: .pending,
            receipt: nil
        )
        var pending = current
        pending.circlemsCredentialTransfer = transfer
        // This Keychain write is the persist-before-send boundary. Rotation is
        // disabled as soon as it commits, while the exact original credential
        // remains available for a response-loss replay.
        try persist(pending)
        return transfer
    }

    func acknowledge(_ receipt: CirclemsCredentialReceipt) throws {
        try reload()
        guard let current = user,
              let transfer = current.circlemsCredentialTransfer,
              transfer.state == .pending,
              receipt.requestID == transfer.requestID,
              receipt.provider == "circlems",
              receipt.environment == transfer.environment.apiValue,
              receipt.credentialRevision > 0,
              let providerUserID = current.userId,
              String(providerUserID) == receipt.subject
        else { throw CominaviServiceError.invalidResponse }

        guard storage.saveCredentialRevision(
            receipt.credentialRevision,
            environment: receipt.environment,
            subject: receipt.subject
        ) else { throw CominaviServiceError.authenticationStorageUnavailable }

        // First remove the local refresh authority while retaining a
        // non-secret acknowledged marker. If the next Keychain write fails,
        // relaunch cleanup is safe and no provider token can be rotated.
        var acknowledged = current
        acknowledged.refreshToken = nil
        acknowledged.circlemsCredentialRevision = receipt.credentialRevision
        acknowledged.circlemsCredentialTransfer = transfer.acknowledged(with: receipt)
        try persist(acknowledged)

        var cleaned = acknowledged
        cleaned.circlemsCredentialTransfer = nil
        try persist(cleaned)
    }

    /// The opaque completion-code flow has already installed the provider
    /// family on the backend. Delete every local provider credential and
    /// transfer marker; only the non-secret revision ledger survives.
    func scrubBackendOwnedCredential(_ receipt: CirclemsCredentialReceipt) throws {
        guard receipt.provider == "circlems",
              receipt.credentialRevision > 0,
              !receipt.environment.isEmpty,
              !receipt.subject.isEmpty
        else { throw CominaviServiceError.invalidResponse }
        guard storage.saveCredentialRevision(
            receipt.credentialRevision,
            environment: receipt.environment,
            subject: receipt.subject
        ) else { throw CominaviServiceError.authenticationStorageUnavailable }
        try reload()
        try persist(nil)
    }

    private func reload() throws {
        user = try storage.loadForCredentialTransfer()
    }

    private func persist(_ value: User?) throws {
        guard storage.save(value) else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        user = value
    }
}

private struct CirclemsSessionStore: CirclemsUserSessionPersisting {
    private static let service = "net.cominavi.circlems-session"
    private static let revisionService = "net.cominavi.circlems-credential-revisions"

    let account: String

    func load() -> User? {
        try? loadForCredentialTransfer()
    }

    func loadForCredentialTransfer() throws -> User? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                reportFailure(operation: "read", status: errSecDecode)
                throw CominaviServiceError.authenticationStorageUnavailable
            }

            do {
                return try JSONDecoder().decode(User.self, from: data)
            } catch {
                reportFailure(operation: "decode", status: errSecDecode)
                throw CominaviServiceError.authenticationStorageUnavailable
            }
        case errSecItemNotFound:
            return nil
        default:
            reportFailure(operation: "read", status: status)
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    @discardableResult
    func save(_ user: User?) -> Bool {
        guard let user else {
            return delete()
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(user)
        } catch {
            reportFailure(operation: "encode", status: errSecParam)
            return false
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            reportFailure(operation: "update", status: updateStatus)
            return false
        }

        var newItem = itemQuery
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return true
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
            if retryStatus == errSecSuccess {
                return true
            }
            reportFailure(operation: "update", status: retryStatus)
            return false
        }

        reportFailure(operation: "add", status: addStatus)
        return false
    }

    func loadCredentialRevision(environment: String, subject: String) throws -> Int? {
        try credentialRevisions()[revisionKey(environment: environment, subject: subject)]
    }

    @discardableResult
    func saveCredentialRevision(
        _ revision: Int,
        environment: String,
        subject: String
    ) -> Bool {
        guard revision > 0 else { return false }
        var revisions: [String: Int]
        do {
            revisions = try credentialRevisions()
        } catch {
            return false
        }
        revisions[revisionKey(environment: environment, subject: subject)] = revision
        guard let data = try? JSONEncoder().encode(revisions) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = revisionItemQuery
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            reportFailure(operation: "update credential revision", status: update)
            return false
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            reportFailure(operation: "add credential revision", status: add)
            return false
        }
        return true
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private var revisionItemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.revisionService,
            kSecAttrAccount as String: account,
        ]
    }

    private func credentialRevisions() throws -> [String: Int] {
        var query = revisionItemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return [:]
        case errSecSuccess:
            guard let data = result as? Data,
                  let revisions = try? JSONDecoder().decode([String: Int].self, from: data)
            else {
                reportFailure(operation: "decode credential revisions", status: errSecDecode)
                throw CominaviServiceError.authenticationStorageUnavailable
            }
            return revisions
        default:
            reportFailure(operation: "read credential revisions", status: status)
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    private func revisionKey(environment: String, subject: String) -> String {
        "\(environment):\(subject)"
    }

    private func delete() -> Bool {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            reportFailure(operation: "delete", status: status)
            return false
        }
        return true
    }

    private func reportFailure(operation: String, status: OSStatus) {
        // Never include the stored value in diagnostics: it contains OAuth credentials.
        SentrySDK.capture(message: "Circle.ms Keychain \(operation) failed with OSStatus \(status)")
        #if DEBUG
        print("Circle.ms Keychain \(operation) failed with OSStatus \(status)")
        #endif
    }
}

@MainActor
@Observable
final class UserState {
    @ObservationIgnored private var isInstallingPersistedUser = false

    var user = AppData.user {
        didSet {
            if !isInstallingPersistedUser {
                AppData.user = user
            }

            AppTrack.user(user)
        }
    }

    var isLoggedIn: Bool {
        return user?.accessToken != nil
    }

    func reloadFromSelectedEnvironment() {
        user = AppData.user
    }

    func installPersistedUser(_ user: User?) {
        isInstallingPersistedUser = true
        self.user = user
        isInstallingPersistedUser = false
    }
}
