import Foundation
import Observation
import Security

enum SharedPlanInvitationLink {
    static func token(from url: URL) -> String? {
        guard url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil
        else { return nil }

        let token: String?
        switch url.scheme?.lowercased() {
        case "https" where url.host?.lowercased() == "cominavi.net":
            let components = url.pathComponents.filter { $0 != "/" }
            token = components.count == 2 && components[0] == "join"
                ? components[1]
                : nil
        case "cominavi" where url.host?.lowercased() == "join":
            let components = url.pathComponents.filter { $0 != "/" }
            token = components.count == 1 ? components[0] : nil
        default:
            token = nil
        }
        guard let token, isValid(token: token) else { return nil }
        return token
    }

    static func isValid(token: String) -> Bool {
        token.utf8.count == 12 && token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    static func canonicalURL(token: String) -> URL? {
        guard isValid(token: token) else { return nil }
        return URL(string: "https://cominavi.net/join/\(token)")
    }

    static func fallbackURL(token: String) -> URL? {
        guard isValid(token: token) else { return nil }
        return URL(string: "cominavi://join/\(token)")
    }
}

enum SharedPlanInvitationExpiration {
    /// The backend stores invitation expiry as integer Unix seconds. Freeze
    /// that exact value before assigning a durable request ID so a 201 result
    /// can be compared and replayed without subsecond payload drift.
    static func canonical(_ value: Date) -> Date {
        Date(timeIntervalSince1970: floor(value.timeIntervalSince1970))
    }
}

enum SharedPlanInvitationFailurePolicy {
    /// Capability URLs that the server has definitively rejected must not
    /// survive another launch. Authentication and transient failures retain
    /// the protected token so the intended recipient can continue later.
    static func consumesRouteCapability(after error: Error) -> Bool {
        if case CominaviServiceError.server(_, _, let status) = error {
            return [400, 403, 404, 409, 410, 422].contains(status)
        }
        if let error = error as? SharedPlanError {
            return [.invalidInvite, .removedMember, .membershipRevoked].contains(error)
        }
        return false
    }
}

@MainActor
@Observable
final class SharedPlanInvitationInbox {
    struct Pending: Codable, Equatable, Identifiable, Sendable {
        var id: String { token }
        let token: String
        let receivedAt: Date
    }

    private(set) var pending: Pending?
    var issue: SharedPlanError?

    @ObservationIgnored private let storage: any SharedPlanInvitationSecretStoring

    init(
        storage: any SharedPlanInvitationSecretStoring = KeychainSharedPlanInvitationSecretStore(
            account: "default-route"
        )
    ) {
        self.storage = storage
        if let data = try? storage.load(),
           let decoded = try? JSONDecoder().decode(Pending.self, from: data),
           SharedPlanInvitationLink.isValid(token: decoded.token)
        {
            pending = decoded
        } else {
            try? storage.clear()
        }
    }

    @discardableResult
    func receive(url: URL, now: Date = Date()) -> Bool {
        guard let token = SharedPlanInvitationLink.token(from: url) else { return false }
        if pending?.token == token { return true }
        let request = Pending(token: token, receivedAt: now)
        guard let data = try? JSONEncoder().encode(request) else {
            issue = .persistenceFailed
            return true
        }
        do {
            try storage.save(data)
        } catch {
            issue = .persistenceFailed
            return true
        }
        pending = request
        issue = nil
        return true
    }

    func consume(token: String) {
        guard pending?.token == token else { return }
        pending = nil
        do {
            try storage.clear()
        } catch {
            issue = .persistenceFailed
        }
    }

    /// A definitive server rejection must not survive relaunch, but the
    /// current presentation still needs the token long enough to show the
    /// user why the invitation cannot be used. Keep the in-memory route until
    /// the sheet is explicitly dismissed while deleting its protected copy.
    func removePersistedCapability(token: String) {
        guard pending?.token == token else { return }
        do {
            try storage.clear()
        } catch {
            issue = .persistenceFailed
        }
    }

    func clear() {
        pending = nil
        issue = nil
        do {
            try storage.clear()
        } catch {
            issue = .persistenceFailed
        }
    }

    /// Invite context makes the Google option eligible, but it is not proof of
    /// authorization. The backend must still mint a nonce-bound entryGrant.
    var isGoogleEntryEligible: Bool { pending != nil }
}

protocol SharedPlanInvitationSecretStoring {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

struct KeychainSharedPlanInvitationSecretStore: SharedPlanInvitationSecretStoring, Sendable {
    private static let service = "net.cominavi.shared-plan-invitation"
    let account: String

    func load() throws -> Data? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { throw SharedPlanError.persistenceFailed }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SharedPlanError.persistenceFailed
        }
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SharedPlanError.persistenceFailed }
        var newItem = itemQuery
        attributes.forEach { newItem[$0.key] = $0.value }
        let added = SecItemAdd(newItem as CFDictionary, nil)
        guard added == errSecSuccess else { throw SharedPlanError.persistenceFailed }
    }

    func clear() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedPlanError.persistenceFailed
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemorySharedPlanInvitationSecretStore: SharedPlanInvitationSecretStoring {
    private var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func clear() throws { data = nil }
}

protocol SharedPlanInviteCapabilityVault: Sendable {
    func save(token: String, requestID: UUID) async throws
    func token(requestID: UUID) async throws -> String?
    func remove(requestID: UUID) async throws
    func retainOnly(requestIDs: Set<UUID>) async throws
    func removeAll() async throws
}

actor KeychainSharedPlanInviteCapabilityVault: SharedPlanInviteCapabilityVault {
    private let storage: KeychainSharedPlanInvitationSecretStore

    init(account: String) {
        storage = KeychainSharedPlanInvitationSecretStore(account: "outbox.\(account)")
    }

    func save(token: String, requestID: UUID) throws {
        guard SharedPlanInvitationLink.isValid(token: token) else {
            throw SharedPlanError.invalidInvite
        }
        var values = try loadValues()
        values[requestID.uuidString.lowercased()] = token
        try saveValues(values)
    }

    func token(requestID: UUID) throws -> String? {
        try loadValues()[requestID.uuidString.lowercased()]
    }

    func remove(requestID: UUID) throws {
        var values = try loadValues()
        values[requestID.uuidString.lowercased()] = nil
        try saveValues(values)
    }

    func retainOnly(requestIDs: Set<UUID>) throws {
        let retained = Set(requestIDs.map { $0.uuidString.lowercased() })
        let values = try loadValues().filter { retained.contains($0.key) }
        try saveValues(values)
    }

    func removeAll() throws {
        try storage.clear()
    }

    private func loadValues() throws -> [String: String] {
        guard let data = try storage.load() else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func saveValues(_ values: [String: String]) throws {
        if values.isEmpty {
            try storage.clear()
        } else {
            try storage.save(JSONEncoder().encode(values))
        }
    }
}

actor InMemorySharedPlanInviteCapabilityVault: SharedPlanInviteCapabilityVault {
    private var values: [UUID: String] = [:]

    func save(token: String, requestID: UUID) throws {
        guard SharedPlanInvitationLink.isValid(token: token) else {
            throw SharedPlanError.invalidInvite
        }
        values[requestID] = token
    }

    func token(requestID: UUID) -> String? { values[requestID] }
    func remove(requestID: UUID) { values[requestID] = nil }
    func retainOnly(requestIDs: Set<UUID>) {
        values = values.filter { requestIDs.contains($0.key) }
    }
    func removeAll() { values.removeAll() }
}

protocol SharedPlanCreatedInvitationVault: Sendable {
    func loadAll() async throws -> [UUID: SharedPlanCreatedInvitation]
    func save(_ invitation: SharedPlanCreatedInvitation) async throws
    func remove(requestID: UUID) async throws
    func removeAll() async throws
}

actor KeychainSharedPlanCreatedInvitationVault: SharedPlanCreatedInvitationVault {
    private let storage: KeychainSharedPlanInvitationSecretStore

    init(account: String) {
        storage = KeychainSharedPlanInvitationSecretStore(account: "created.\(account)")
    }

    func loadAll() throws -> [UUID: SharedPlanCreatedInvitation] {
        guard let data = try storage.load() else { return [:] }
        let values = try JSONDecoder().decode(
            [String: SharedPlanCreatedInvitation].self,
            from: data
        )
        var result: [UUID: SharedPlanCreatedInvitation] = [:]
        for (key, value) in values {
            guard let requestID = UUID(uuidString: key),
                  key == requestID.uuidString.lowercased(),
                  value.requestID == requestID,
                  SharedPlanInvitationLink.isValid(token: value.token),
                  value.canonicalURL == SharedPlanInvitationLink.canonicalURL(
                      token: value.token
                  ),
                  value.fallbackURL == SharedPlanInvitationLink.fallbackURL(
                      token: value.token
                  )
            else { throw SharedPlanError.persistenceFailed }
            result[requestID] = value
        }
        return result
    }

    func save(_ invitation: SharedPlanCreatedInvitation) throws {
        var values = try loadValues()
        values[invitation.requestID.uuidString.lowercased()] = invitation
        try storage.save(JSONEncoder().encode(values))
    }

    func remove(requestID: UUID) throws {
        var values = try loadValues()
        values[requestID.uuidString.lowercased()] = nil
        if values.isEmpty {
            try storage.clear()
        } else {
            try storage.save(JSONEncoder().encode(values))
        }
    }

    func removeAll() throws {
        try storage.clear()
    }

    private func loadValues() throws -> [String: SharedPlanCreatedInvitation] {
        guard let data = try storage.load() else { return [:] }
        return try JSONDecoder().decode(
            [String: SharedPlanCreatedInvitation].self,
            from: data
        )
    }
}

actor InMemorySharedPlanCreatedInvitationVault: SharedPlanCreatedInvitationVault {
    private var values: [UUID: SharedPlanCreatedInvitation] = [:]

    func loadAll() -> [UUID: SharedPlanCreatedInvitation] { values }
    func save(_ invitation: SharedPlanCreatedInvitation) {
        values[invitation.requestID] = invitation
    }
    func remove(requestID: UUID) { values[requestID] = nil }
    func removeAll() { values.removeAll() }
}
