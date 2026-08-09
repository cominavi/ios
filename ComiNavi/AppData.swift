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
    static let catalogLibrary = CatalogLibrary()
    static let sharedLocationInbox = SharedLocationInbox()
    static let sharedLocationClipboardImporter = SharedLocationClipboardImporter()

    /// Transitional access for catalog consumers that have not yet adopted
    /// explicit data-source injection.
    public static var circlems: CirclemsDataSource! {
        catalogLibrary.dataSource
    }

    private static var circlemsSessionStore: CirclemsSessionStore {
        CirclemsSessionStore(account: AppEnvironment.current.storageNamespace)
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

    #if DEBUG
    /// Changes the Circle.ms service used by this Debug build and reloads all
    /// environment-scoped state without carrying credentials across services.
    @discardableResult
    static func selectCirclemsEnvironment(
        _ environment: CirclemsServiceEnvironment
    ) -> Bool {
        guard AppEnvironment.current.build == .debug,
              environment != AppEnvironment.current.circlems
        else {
            return false
        }

        AppEnvironment.setDebugCirclemsEnvironment(environment)
        catalogLibrary.reset()
        if catalogLibrary.mode != .circlems {
            catalogLibrary.selectMode(.circlems)
        }
        userState.reloadFromSelectedEnvironment()
        return true
    }
    #endif

    public static func getUserToken() async -> String {
        let storageNamespace = AppEnvironment.current.storageNamespace
        guard let user = userState.user,
              let expiresAt = user.accessTokenExpiresAt
        else {
            return ""
        }
        if expiresAt < Date() {
            guard let refreshToken = user.refreshToken,
                  let newTokenResponse = try? await CominaviAPI.oauthCirclemsRefreshToken(
                      refreshToken: refreshToken
                  ),
                  storageNamespace == AppEnvironment.current.storageNamespace,
                  userState.user?.refreshToken == refreshToken
            else {
                return ""
            }
            userState.user = User(
                accessToken: newTokenResponse.accessToken,
                accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(newTokenResponse.expiresIn.int ?? 86400)),
                refreshToken: newTokenResponse.refreshToken,
                userId: user.userId,
                nickname: user.nickname,
                preferenceR18Enabled: user.preferenceR18Enabled
            )
            return newTokenResponse.accessToken
        }

        return user.accessToken ?? ""
    }
}

struct User: Codable, Sendable {
    var accessToken: String?
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
    var userId: Int?
    var nickname: String?
    var preferenceR18Enabled: Bool?
}

private struct CirclemsSessionStore {
    private static let service = "net.cominavi.circlems-session"

    let account: String

    func load() -> User? {
        var query = itemQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                reportFailure(operation: "read", status: errSecDecode)
                return nil
            }

            do {
                return try JSONDecoder().decode(User.self, from: data)
            } catch {
                reportFailure(operation: "decode", status: errSecDecode)
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            reportFailure(operation: "read", status: status)
            return nil
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

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
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
    var user = AppData.user {
        didSet {
            AppData.user = user

            AppTrack.user(user)
        }
    }

    var isLoggedIn: Bool {
        return user?.accessToken != nil
    }

    func reloadFromSelectedEnvironment() {
        user = AppData.user
    }
}
