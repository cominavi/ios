import CryptoKit
import Foundation
import Observation

struct CominaviProfileIdentity: Codable, Equatable, Sendable {
    let provider: String
    let environment: String?
    let providerUserID: String?
    let email: String?

    var stableID: String {
        [provider, environment, providerUserID, email]
            .compactMap { $0 }
            .joined(separator: "\u{1f}")
    }

    private enum CodingKeys: String, CodingKey {
        case provider, environment, providerUserID, email
    }

    init(
        provider: String,
        environment: String? = nil,
        providerUserID: String? = nil,
        email: String? = nil
    ) {
        self.provider = provider
        self.environment = environment
        self.providerUserID = providerUserID
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        environment = try values.decodeIfPresent(String.self, forKey: .environment)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        if let string = try? values.decode(String.self, forKey: .providerUserID) {
            providerUserID = string
        } else if let integer = try? values.decode(Int64.self, forKey: .providerUserID) {
            providerUserID = String(integer)
        } else {
            providerUserID = nil
        }
    }
}

struct CominaviUserProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var avatarURL: URL?
    var revision: Int
    var identities: [CominaviProfileIdentity]
    var displayNameExplicitlyEdited: Bool?
    var avatarExplicitlyEdited: Bool?
}

protocol CominaviProfileServicing: Sendable {
    func fetchProfile() async throws -> CominaviUserProfile
    func updateDisplayName(
        _ displayName: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile
    func uploadAvatar(
        _ data: Data,
        contentType: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile
    func deleteAvatar(
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile
}

protocol CominaviAvatarLoading: Sendable {
    func loadAvatarData(from url: URL) async throws -> Data
}

protocol CominaviProfileMutationPersisting: Sendable {
    func load(userID: String) throws -> Data?
    func save(_ data: Data, userID: String) throws
    func clear(userID: String) throws
}

struct FileCominaviProfileMutationStore: CominaviProfileMutationPersisting {
    let directory: URL

    func load(userID: String) throws -> Data? {
        let url = fileURL(userID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data, userID: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = fileURL(userID: userID)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func clear(userID: String) throws {
        let url = fileURL(userID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(userID: String) -> URL {
        let digest = SHA256.hash(data: Data(userID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("profile-mutation-\(digest).json")
    }
}

final class InMemoryCominaviProfileMutationStore: @unchecked Sendable,
    CominaviProfileMutationPersisting
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(userID: String) -> Data? {
        lock.withLock { values[userID] }
    }

    func save(_ data: Data, userID: String) {
        lock.withLock { values[userID] = data }
    }

    func clear(userID: String) {
        lock.withLock { values[userID] = nil }
    }
}

@MainActor
@Observable
final class CominaviProfileStore {
    private struct PendingMutation: Codable, Equatable {
        enum Kind: String, Codable { case displayName, avatarUpload, avatarDelete }

        let kind: Kind
        let requestID: UUID
        let userID: String
        let baseRevision: Int
        let displayName: String?
        let avatarData: Data?
        let contentType: String?
    }

    private(set) var profile: CominaviUserProfile?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isIdentityVerified = false
    private(set) var requiresReauthentication = false
    var issueMessage: String?

    var hasPendingMutation: Bool { pendingMutation != nil }

    var pendingMutationDescription: String? {
        switch pendingMutation?.kind {
        case .displayName: String(localized: "表示名の変更を送信待ちです。")
        case .avatarUpload: String(localized: "アバターの変更を送信待ちです。")
        case .avatarDelete: String(localized: "アバターの削除を送信待ちです。")
        case nil: nil
        }
    }

    @ObservationIgnored private let service: any CominaviProfileServicing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let mutationPersistence: any CominaviProfileMutationPersisting
    private var pendingMutation: PendingMutation?

    init(
        service: any CominaviProfileServicing,
        defaults: UserDefaults = .standard,
        storageKey: String = "cominavi.profile.v1",
        expectedUserID: String? = nil,
        initialRequiresReauthentication: Bool = false,
        mutationPersistence: any CominaviProfileMutationPersisting =
            InMemoryCominaviProfileMutationStore()
    ) {
        self.service = service
        self.defaults = defaults
        self.storageKey = storageKey
        self.mutationPersistence = mutationPersistence
        if let expectedUserID,
           let data = defaults.data(forKey: storageKey),
           let cached = try? JSONDecoder().decode(CominaviUserProfile.self, from: data),
           cached.id == expectedUserID
        {
            profile = cached
            // The cache is safe for offline use only because its public user
            // ID matches the ThisDeviceOnly Keychain account binding.
            isIdentityVerified = !initialRequiresReauthentication
            requiresReauthentication = initialRequiresReauthentication
            if let pendingData = try? mutationPersistence.load(userID: expectedUserID),
               let pending = try? JSONDecoder().decode(PendingMutation.self, from: pendingData),
               pending.userID == expectedUserID
            {
                pendingMutation = pending
            }
        } else {
            // An unbound or differently bound cache is never authoritative
            // enough to open an account-scoped Shared Plan database.
            defaults.removeObject(forKey: storageKey)
        }
        // Remove the short-lived pre-release UserDefaults representation.
        defaults.removeObject(forKey: "\(storageKey).pending-mutation")
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            setProfile(try await service.fetchProfile())
            isIdentityVerified = true
            requiresReauthentication = false
            issueMessage = nil
            do {
                try await drainPendingMutation()
            } catch {
                issueMessage = error.localizedDescription
            }
        } catch CominaviServiceError.notLoggedIn {
            isIdentityVerified = false
            requiresReauthentication = true
            issueMessage = CominaviServiceError.notLoggedIn.localizedDescription
        } catch CominaviServiceError.authenticationStorageUnavailable {
            isIdentityVerified = false
            requiresReauthentication = true
            issueMessage = CominaviServiceError.authenticationStorageUnavailable
                .localizedDescription
        } catch {
            if profile == nil { isIdentityVerified = false }
            if profile == nil { issueMessage = error.localizedDescription }
        }
    }

    func saveDisplayName(_ value: String) async throws {
        guard let profile, isIdentityVerified else { throw SharedPlanError.profileRequired }
        let displayName = try SharedPlanValidation.normalizedProfileDisplayName(value)
        guard pendingMutation != nil || displayName != profile.displayName else { return }
        let pending = try reusableMutation(
            kind: .displayName,
            profile: profile,
            displayName: displayName
        )
        try persist(pending)
        try await drainPendingMutation()
    }

    func saveAvatar(_ data: Data, contentType: String) async throws {
        guard let profile, isIdentityVerified else { throw SharedPlanError.profileRequired }
        let pending = try reusableMutation(
            kind: .avatarUpload,
            profile: profile,
            avatarData: data,
            contentType: contentType
        )
        try persist(pending)
        try await drainPendingMutation()
    }

    func removeAvatar() async throws {
        guard let profile, isIdentityVerified else { throw SharedPlanError.profileRequired }
        let pending = try reusableMutation(kind: .avatarDelete, profile: profile)
        try persist(pending)
        try await drainPendingMutation()
    }

    func drainPendingMutation() async throws {
        guard !isSaving, isIdentityVerified,
              let pending = pendingMutation,
              let profile,
              profile.id == pending.userID
        else { return }

        if pending.kind == .displayName, pending.displayName == profile.displayName {
            try clearPendingMutation(userID: pending.userID)
            issueMessage = nil
            return
        }
        if pending.kind == .avatarDelete, profile.avatarURL == nil {
            try clearPendingMutation(userID: pending.userID)
            issueMessage = nil
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let updated: CominaviUserProfile
            switch pending.kind {
            case .displayName:
                guard let displayName = pending.displayName else {
                    throw CominaviServiceError.invalidResponse
                }
                updated = try await service.updateDisplayName(
                    displayName,
                    baseRevision: pending.baseRevision,
                    requestID: pending.requestID
                )
            case .avatarUpload:
                guard let data = pending.avatarData,
                      let contentType = pending.contentType
                else { throw CominaviServiceError.invalidResponse }
                updated = try await service.uploadAvatar(
                    data,
                    contentType: contentType,
                    baseRevision: pending.baseRevision,
                    requestID: pending.requestID
                )
            case .avatarDelete:
                updated = try await service.deleteAvatar(
                    baseRevision: pending.baseRevision,
                    requestID: pending.requestID
                )
            }
            setProfile(updated)
            try clearPendingMutation(userID: pending.userID)
            issueMessage = nil
        } catch {
            let alreadyApplied = try await reconcileConflict(
                error,
                intendedDisplayName: pending.displayName,
                expectsAvatarRemoved: pending.kind == .avatarDelete
            )
            if alreadyApplied {
                issueMessage = nil
                return
            }
            if isDefinitiveFailure(error) {
                try clearPendingMutation(userID: pending.userID)
            }
            issueMessage = error.localizedDescription
            throw error
        }
    }

    func discardPendingMutation() throws {
        guard let pendingMutation else { return }
        try clearPendingMutation(userID: pendingMutation.userID)
        issueMessage = nil
    }

    func clear() {
        let previousUserID = profile?.id
        profile = nil
        isIdentityVerified = false
        requiresReauthentication = false
        issueMessage = nil
        defaults.removeObject(forKey: storageKey)
        if let previousUserID { try? clearPendingMutation(userID: previousUserID) }
    }

    func invalidateIdentityVerification(issueMessage: String? = nil) {
        isIdentityVerified = false
        requiresReauthentication = true
        if let issueMessage { self.issueMessage = issueMessage }
    }

    private func setProfile(_ profile: CominaviUserProfile) {
        if pendingMutation?.userID != profile.id {
            // Pending mutations are user-scoped durable records. An explicit
            // account transition detaches the prior account's record without
            // deleting it and loads only the newly authenticated user's work.
            pendingMutation = nil
            if let pendingData = try? mutationPersistence.load(userID: profile.id),
               let pending = try? JSONDecoder().decode(PendingMutation.self, from: pendingData),
               pending.userID == profile.id
            {
                pendingMutation = pending
            }
        }
        self.profile = profile
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func reusableMutation(
        kind: PendingMutation.Kind,
        profile: CominaviUserProfile,
        displayName: String? = nil,
        avatarData: Data? = nil,
        contentType: String? = nil
    ) throws -> PendingMutation {
        if let pendingMutation,
           pendingMutation.kind == kind,
           pendingMutation.userID == profile.id,
           pendingMutation.displayName == displayName,
           pendingMutation.avatarData == avatarData,
           pendingMutation.contentType == contentType
        {
            return pendingMutation
        }
        guard pendingMutation == nil else {
            throw SharedPlanError.profileMutationPending
        }
        return PendingMutation(
            kind: kind,
            requestID: UUID(),
            userID: profile.id,
            baseRevision: profile.revision,
            displayName: displayName,
            avatarData: avatarData,
            contentType: contentType
        )
    }

    private func persist(_ mutation: PendingMutation) throws {
        let data = try JSONEncoder().encode(mutation)
        try mutationPersistence.save(data, userID: mutation.userID)
        pendingMutation = mutation
    }

    private func clearPendingMutation(userID: String) throws {
        try mutationPersistence.clear(userID: userID)
        pendingMutation = nil
    }

    private func reconcileConflict(
        _ error: Error,
        intendedDisplayName: String? = nil,
        expectsAvatarRemoved: Bool = false
    ) async throws -> Bool {
        guard case CominaviServiceError.revisionConflict = error else { return false }
        let authoritative = try await service.fetchProfile()
        setProfile(authoritative)
        isIdentityVerified = true
        let alreadyApplied = intendedDisplayName == authoritative.displayName
            || (expectsAvatarRemoved && authoritative.avatarURL == nil)
        try clearPendingMutation(userID: authoritative.id)
        return alreadyApplied
    }

    private func isDefinitiveFailure(_ error: Error) -> Bool {
        if case CominaviServiceError.revisionConflict = error { return true }
        if case CominaviServiceError.server(_, _, let status) = error {
            return (400..<500).contains(status) && status != 408 && status != 429
        }
        return false
    }
}
