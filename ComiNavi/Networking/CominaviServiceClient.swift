import CominaviAPIClient
import Foundation
import OpenAPIRuntime

enum CominaviServiceError: LocalizedError, Sendable {
    case notLoggedIn
    case authenticationStorageUnavailable
    case logoutPending
    case accountDeletionPending
    case circlemsCredentialTransferPending
    case invalidResponse
    case server(code: String, message: String, status: Int)
    case favoriteMutationRejected(
        code: String,
        message: String,
        invalidPublicCircleIDs: [Int]
    )
    case planOwnerRequired(code: String, message: String)
    case invitationTokenAlreadyReturned(message: String, invitationID: String)
    case revisionConflict(
        code: String,
        message: String,
        currentRevision: Int?,
        currentPlan: SharedPlan?
    )

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            String(localized: "ComiNaviにもう一度ログインしてください。")
        case .authenticationStorageUnavailable:
            String(localized: "ログイン情報を安全に保存できませんでした。もう一度ログインしてください。")
        case .logoutPending:
            String(localized: "Logout is still being completed. Please try again when the network is available.")
        case .accountDeletionPending:
            String(localized: "Account deletion is still being completed and will retry automatically when the network is available.")
        case .circlemsCredentialTransferPending:
            String(localized: "Circle.ms credentials are being transferred securely. Please try again shortly.")
        case .invalidResponse:
            String(localized: "The ComiNavi service returned an invalid response.")
        case .server(_, let message, _):
            message
        case .favoriteMutationRejected(_, let message, _):
            message
        case .planOwnerRequired(_, let message):
            message
        case .invitationTokenAlreadyReturned(let message, _):
            message
        case .revisionConflict(_, let message, _, _):
            message
        }
    }
}

@MainActor
enum CominaviAuthenticationInvalidationCenter {
    static var handler: ((CominaviServiceError?) -> Void)?

    static func invalidate(_ error: CominaviServiceError?) {
        handler?(error)
    }
}

struct CominaviRealtimeUpdate: Codable, Hashable, Sendable {
    struct Post: Codable, Hashable, Sendable {
        struct Author: Codable, Hashable, Sendable {
            let xUserID: String?
            let handle: String
            let name: String?
            let profileImageURL: URL?
        }

        struct Media: Codable, Hashable, Sendable {
            let key: String
            let type: String
            let role: String
            let url: URL
            let previewURL: URL?
        }

        let id: String
        let url: URL?
        let text: String
        let author: Author
        let media: [Media]
    }

    struct Circle: Codable, Hashable, Sendable {
        let eventNumber: Int
        let wcID: Int
        let circleID: Int?
        let circleName: String
        let day: Int?
        let areaName: String?
        let blockName: String?
        let spaceNo: Int?
        let spaceNoSub: Int?
        let location: String?
    }

    let cursor: Int
    let eventKey: String
    let updateKind: String
    let stateKind: String
    let stateValue: String
    let confidence: CatalogConfidence
    let occurredAt: Date
    let sourceRevision: Int
    let post: Post
    let circles: [Circle]
}

protocol CominaviFavoriteSyncing: Sendable {
    func favoriteSnapshot(eventNumber: Int) async throws -> CominaviFavoriteSnapshot
    func replaceFavorites(
        eventNumber: Int,
        baseRevision: Int,
        mutationID: UUID,
        favorites: [CominaviFavorite]
    ) async throws -> CominaviFavoriteSnapshot
}

struct CirclemsFavoriteImportItem: Codable, Equatable, Identifiable, Sendable {
    let wcID: Int
    let updateID: Int
    let circleName: String
    let color: Int
    let memo: String

    var id: Int { wcID }
}

struct CirclemsFavoriteImportPage: Codable, Equatable, Sendable {
    let eventNumber: Int
    let items: [CirclemsFavoriteImportItem]
    let nextCursor: String?
}

protocol CirclemsFavoriteImportServicing: Sendable {
    func circlemsFavoriteImportPage(
        eventNumber: Int,
        cursor: String?
    ) async throws -> CirclemsFavoriteImportPage
}

protocol CominaviRealtimeFetching: Sendable {
    func realtimeUpdates(
        eventNumber: Int,
        after cursor: Int,
        limit: Int
    ) async throws -> (updates: [CominaviRealtimeUpdate], nextCursor: Int, hasMore: Bool)
}

struct CominaviProviderFlowPublicationLease: Equatable, Sendable {
    enum Provider: String, Sendable {
        case circlems
        case google
        // Apple uses the same generation-fenced publication boundary once its
        // reviewed backend flow is activated.
        case apple
    }

    let provider: Provider
    let requestID: UUID
    fileprivate let authenticationGeneration: UInt64
}

struct CirclemsAuthorizationPublication: Sendable {
    let flow: CirclemsAuthorizationFlow
    let lease: CominaviProviderFlowPublicationLease
}

struct GoogleAuthenticationPublication: Sendable {
    let flow: GoogleAuthenticationFlow
    let lease: CominaviProviderFlowPublicationLease
}

struct AppleAuthenticationPublication: Sendable {
    let flow: AppleAuthenticationFlow
    let lease: CominaviProviderFlowPublicationLease
}

actor CominaviServiceClient: CominaviFavoriteSyncing, CirclemsFavoriteImportServicing,
    CominaviRealtimeFetching,
    CominaviProfileServicing, CominaviAvatarLoading, SharedPlanRemoteServicing,
    CominaviCatalogServicing, CominaviCatalogRequestAuthorizing,
    SharedPlanSyncRequestAuthorizing
{
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias CirclemsEnvironmentProvider = @Sendable () -> CirclemsServiceEnvironment
    typealias AuthenticationInvalidationHandler = @Sendable (
        _ error: CominaviServiceError?
    ) async -> Void
    typealias AuthenticationFlowCanceller = @Sendable () async throws -> Void
    typealias LogoutRequestIDProvider = @Sendable () -> UUID

    static let shared = CominaviServiceClient(
        sessionStore: KeychainCominaviAuthenticationSessionStore(
            account: AppEnvironment.current.storageNamespace
        ),
        circlemsAuthorizationFlowStorage: KeychainCirclemsAuthorizationFlowStore(
            account: AppEnvironment.current.storageNamespace
        ),
        googleAuthenticationFlowStorage: KeychainGoogleAuthenticationFlowStore(
            account: AppEnvironment.current.storageNamespace
        ),
        appleAuthenticationFlowStorage: KeychainAppleAuthenticationFlowStore(
            account: AppEnvironment.current.storageNamespace
        ),
        authenticationInvalidationHandler: { error in
            await CominaviAuthenticationInvalidationCenter.invalidate(error)
        }
    )

    private struct APIErrorResponse: Decodable {
        struct Details: Decodable {
            let currentRevision: Int?
            let currentPlan: PlanWireResource?
            let wcIDs: [Int]?
            let invitationID: String?
        }

        let error: String
        let message: String
        let details: Details?
        let nextAllowedAt: Date?
    }

    private struct PlanWireResource: Decodable {
        @CanonicalLowercaseUUIDString var id: String
        let name: String
        let comiketNo: Int
        let status: String
        let role: String
        let revision: Int
        let createdAt: Date
        let updatedAt: Date

        var domain: SharedPlan? {
            guard let lifecycle = SharedPlanLifecycle(rawValue: status),
                  let role = SharedPlanRole(rawValue: role),
                  role == .owner || role == .editor
            else { return nil }
            return SharedPlan(
                id: id,
                name: name,
                comiketNo: comiketNo,
                ownership: role == .owner ? .owned : .joined,
                role: role,
                lifecycle: lifecycle,
                revision: revision,
                circleKeys: [],
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private struct PlanPage: Decodable {
        let items: [PlanWireResource]
        let nextCursor: String?
    }

    private struct PlanMemberWireResource: Decodable {
        let userID: String
        let displayName: String
        let avatarURL: URL?
        let role: String
        let membershipStatus: String
        let joinedAt: Date
        let removedAt: Date?

        var domain: SharedPlanMember? {
            guard Self.isLowercaseHex(userID, count: 32),
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let role = SharedPlanRole(rawValue: role),
                  role == .owner || role == .editor,
                  let membershipStatus = SharedPlanMembershipStatus(
                      rawValue: membershipStatus
                  ),
                  (membershipStatus == .removed) == (removedAt != nil),
                  removedAt.map({ $0 >= joinedAt }) ?? true,
                  avatarURL.map({ Self.isControlledAvatarURL($0, userID: userID) }) ?? true
            else { return nil }
            return SharedPlanMember(
                userID: userID,
                displayName: displayName,
                avatarURL: avatarURL,
                role: role,
                membershipStatus: membershipStatus,
                joinedAt: joinedAt,
                removedAt: removedAt
            )
        }

        private static func isControlledAvatarURL(_ url: URL, userID: String) -> Bool {
            url.scheme == nil
                && url.host == nil
                && url.query == nil
                && url.fragment == nil
                && url.path == "/api/v2/users/\(userID)/avatar"
        }

        private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
            value.count == count
                && value == value.lowercased()
                && value.allSatisfy(\.isHexDigit)
        }
    }

    private struct PlanMemberPageWire: Decodable {
        let items: [PlanMemberWireResource]
        let nextCursor: String?
    }

    private struct PlanInvitationWireResource: Decodable {
        let invitationID: String
        let createdByUserID: String
        let currentUserCanRevoke: Bool
        let expiresAt: Date
        let revokedAt: Date?
        let createdAt: Date

        var domain: SharedPlanInvitation? {
            guard Self.isCanonicalUUID(invitationID),
                  Self.isLowercaseHex(createdByUserID, count: 32),
                  expiresAt > createdAt,
                  revokedAt.map({ $0 >= createdAt }) ?? true
            else { return nil }
            return SharedPlanInvitation(
                invitationID: invitationID,
                createdByUserID: createdByUserID,
                currentUserCanRevoke: currentUserCanRevoke,
                expiresAt: expiresAt,
                revokedAt: revokedAt,
                createdAt: createdAt
            )
        }

        private static func isCanonicalUUID(_ value: String) -> Bool {
            guard let uuid = UUID(uuidString: value) else { return false }
            return value == uuid.uuidString.lowercased()
        }

        private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
            value.count == count
                && value == value.lowercased()
                && value.allSatisfy(\.isHexDigit)
        }
    }

    private struct PlanInvitationPageWire: Decodable {
        let items: [PlanInvitationWireResource]
        let nextCursor: String?
    }

    private struct PlanMutationEnvelope: Decodable {
        let plan: PlanWireResource
        let receipt: MutationReceipt
        let syncBootstrap: SharedPlanSyncBootstrap?
    }

    private struct MutationReceipt: Decodable {
        @CanonicalLowercaseUUID var requestId: UUID
        let replayed: Bool
        let resultRevision: Int
        let resultStatus: String

        var domain: SharedPlanMutationReceipt? {
            guard resultRevision >= 0,
                  let status = SharedPlanLifecycle(rawValue: resultStatus)
            else { return nil }
            return SharedPlanMutationReceipt(
                requestID: requestId,
                replayed: replayed,
                resultRevision: resultRevision,
                resultStatus: status
            )
        }
    }

    private struct InvitationCreationEnvelope: Decodable {
        @CanonicalLowercaseUUIDString var invitationID: String
        let token: String
        let expiresAt: Date
        let canonicalURL: URL
        let fallbackURL: URL
        let receipt: MutationReceipt
    }

    private struct NotificationPageWire: Decodable {
        let items: [NotificationWireResource]
        let nextCursor: String?
    }

    private struct NotificationWireResource: Decodable {
        let id: String
        let kind: SharedPlanNotificationKind
        @CanonicalLowercaseUUIDString var planID: String
        let eventType: String
        let i18nKey: String
        let payloadVersion: Int
        let payload: SharedPlanNotificationPayload
        let createdAt: Date
        let readAt: Date?

        var domain: SharedPlanNotificationItem? {
            guard Self.isLowercaseHex(id, count: 64),
                  payloadVersion == 1,
                  !i18nKey.isEmpty,
                  readAt.map({ $0 >= createdAt }) ?? true
            else { return nil }
            switch payload {
            case .operation(let operation):
                guard operation.v == payloadVersion,
                      operation.planID == planID,
                      operation.operationType.rawValue == eventType,
                      i18nKey == String(eventType.dropLast(".v1".count)),
                      Self.isCanonicalUUID(operation.operationID),
                      Self.isLowercaseHex(operation.actorUserID, count: 32),
                      Self.areCanonicalHashes(operation.heads),
                      operation.payload["v"] == .integer(Int64(payloadVersion)),
                      operation.membershipEpoch > 0
                else { return nil }
            case .conflict(let conflict):
                guard conflict.v == payloadVersion,
                      conflict.planID == planID,
                      eventType == "shared_plan.conflict.v1",
                      i18nKey == "shared_plan.conflict",
                      Self.isLowercaseHex(conflict.conflictID, count: 64),
                      !conflict.path.isEmpty,
                      conflict.path.allSatisfy({ !$0.isEmpty }),
                      conflict.changeHashes.count >= 2,
                      Self.areCanonicalHashes(conflict.changeHashes),
                      Self.areCanonicalHashes(conflict.heads),
                      conflict.membershipEpoch > 0
                else { return nil }
            }
            return SharedPlanNotificationItem(
                id: id,
                kind: kind,
                planID: planID,
                eventType: eventType,
                i18nKey: i18nKey,
                payloadVersion: payloadVersion,
                payload: payload,
                createdAt: createdAt,
                readAt: readAt
            )
        }

        private static func isCanonicalUUID(_ value: String) -> Bool {
            guard let uuid = UUID(uuidString: value) else { return false }
            return value == uuid.uuidString.lowercased()
        }

        private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
            value.count == count
                && value == value.lowercased()
                && value.allSatisfy(\.isHexDigit)
        }

        private static func areCanonicalHashes(_ values: [String]) -> Bool {
            !values.isEmpty
                && Set(values).count == values.count
                && values.allSatisfy { isLowercaseHex($0, count: 64) }
        }
    }

    private struct NotificationReadEnvelope: Decodable {
        let id: String
        let readAt: Date
    }

    private struct AccountDeletionMutation: Encodable {
        let requestId: String
        let confirmation: String
    }

    private struct CirclemsCredentialReceiptWire: Decodable {
        @CanonicalLowercaseUUID var requestId: UUID
        let clientInstanceID: String?
        let provider: String
        let environment: String
        let subject: String
        let credentialRevision: Int

        private enum CodingKeys: String, CodingKey {
            case requestId, clientInstanceID, provider, environment, subject
            case credentialRevision
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            _requestId = try values.decode(CanonicalLowercaseUUID.self, forKey: .requestId)
            clientInstanceID = try values.decodeIfPresent(String.self, forKey: .clientInstanceID)
            if let clientInstanceID {
                guard let uuid = UUID(uuidString: clientInstanceID),
                      clientInstanceID == uuid.uuidString.lowercased()
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .clientInstanceID,
                        in: values,
                        debugDescription: "clientInstanceID is not a canonical lowercase UUID"
                    )
                }
            }
            provider = try values.decode(String.self, forKey: .provider)
            environment = try values.decode(String.self, forKey: .environment)
            subject = try values.decode(String.self, forKey: .subject)
            credentialRevision = try values.decode(Int.self, forKey: .credentialRevision)
        }

        var domain: CirclemsCredentialReceipt {
            CirclemsCredentialReceipt(
                requestID: requestId,
                clientInstanceID: clientInstanceID.flatMap(UUID.init(uuidString:)),
                provider: provider,
                environment: environment,
                subject: subject,
                credentialRevision: credentialRevision
            )
        }
    }

    private struct CirclemsLinkEnvelope: Decodable {
        let user: CominaviUserProfile
        let credentialReceipt: CirclemsCredentialReceiptWire
    }

    private struct GeneratedAPIErrorResponse: Decodable {
        struct Details: Decodable {
            let currentRevision: Int?
            let wcIDs: [Int]?
        }

        let error: String
        let message: String
        let details: Details?
        let nextAllowedAt: Date?
    }

    private struct RealtimePage: Decodable {
        let eventNumber: Int
        let updates: [CominaviRealtimeUpdate]
        let nextCursor: Int
        let hasMore: Bool
    }

    private let baseURL: URL
    private let transport: Transport
    private let circlemsEnvironmentProvider: CirclemsEnvironmentProvider
    private let sessionStore: any CominaviAuthenticationSessionPersisting
    private let circlemsAuthorizationFlowStorage:
        (any CirclemsAuthorizationFlowPersisting)?
    private let googleAuthenticationFlowStorage:
        (any GoogleAuthenticationFlowStoring)?
    private let appleAuthenticationFlowStorage:
        (any AppleAuthenticationFlowStoring)?
    private let authenticationInvalidationHandler: AuthenticationInvalidationHandler
    private let authenticationFlowCanceller: AuthenticationFlowCanceller
    private let makeLogoutRequestID: LogoutRequestIDProvider
    private let makeAccountDeletionRequestID: LogoutRequestIDProvider
    private var session: CominaviAuthenticationSession?
    private var pendingLogout: CominaviLogoutTransaction?
    private var pendingAccountDeletion: CominaviAccountDeletionTransaction?
    private var pendingAccountDeletionCleanup: CominaviAccountDeletionCleanupReceipt?
    /// Retained when refresh credentials fail so a later request cannot
    /// silently exchange an unrelated Circle.ms credential into this account.
    private var boundPublicUserID: String?
    private var authenticationStorageUnavailable = false
    private var requiresExplicitAuthentication = false
    /// Actor-local epoch fencing every async authentication response. Explicit
    /// identity transitions and local authority invalidations advance it before
    /// yielding, so an older provider/refresh/profile response can never
    /// restore credentials after logout or a newer transition.
    private var authenticationGeneration: UInt64 = 0
    private var refreshTask: Task<CominaviAuthenticationSession, Error>?
    private var refreshTaskToken: String?
    private var avatarDataCache: [String: Data] = [:]

    init(
        baseURL: URL = URL(string: "https://cominavi.net")!,
        transport: @escaping Transport = { request in
            try await URLSession.shared.data(for: request)
        },
        circlemsEnvironmentProvider: @escaping CirclemsEnvironmentProvider = {
            AppEnvironment.current.circlems
        },
        sessionStore: any CominaviAuthenticationSessionPersisting =
            EphemeralCominaviAuthenticationSessionStore(),
        circlemsAuthorizationFlowStorage:
            (any CirclemsAuthorizationFlowPersisting)? = nil,
        googleAuthenticationFlowStorage:
            (any GoogleAuthenticationFlowStoring)? = nil,
        appleAuthenticationFlowStorage:
            (any AppleAuthenticationFlowStoring)? = nil,
        authenticationInvalidationHandler: @escaping AuthenticationInvalidationHandler = { _ in },
        authenticationFlowCanceller: @escaping AuthenticationFlowCanceller = {
            try await AppData.clearPendingAuthenticationFlowsForLogout()
        },
        makeLogoutRequestID: @escaping LogoutRequestIDProvider = UUID.init,
        makeAccountDeletionRequestID: @escaping LogoutRequestIDProvider = UUID.init
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.circlemsEnvironmentProvider = circlemsEnvironmentProvider
        self.sessionStore = sessionStore
        self.circlemsAuthorizationFlowStorage = circlemsAuthorizationFlowStorage
        self.googleAuthenticationFlowStorage = googleAuthenticationFlowStorage
        self.appleAuthenticationFlowStorage = appleAuthenticationFlowStorage
        self.authenticationInvalidationHandler = authenticationInvalidationHandler
        self.authenticationFlowCanceller = authenticationFlowCanceller
        self.makeLogoutRequestID = makeLogoutRequestID
        self.makeAccountDeletionRequestID = makeAccountDeletionRequestID
        let storedState = sessionStore.loadState()
        let loadedSession = storedState.requiresExplicitAuthentication
            ? nil
            : storedState.session
        let storedBinding = storedState.boundUserID
        authenticationStorageUnavailable = !storedState.isAvailable
        requiresExplicitAuthentication = storedState.requiresExplicitAuthentication
        pendingLogout = storedState.pendingLogout
        pendingAccountDeletion = storedState.pendingAccountDeletion
        pendingAccountDeletionCleanup = storedState.pendingAccountDeletionCleanup
        if let storedBinding,
           let loadedUserID = loadedSession?.user?.id,
           storedBinding != loadedUserID
        {
            // A partial/corrupt auth write must fail closed rather than select
            // either identity and risk opening the wrong user-scoped cache.
            session = nil
            boundPublicUserID = storedBinding
            _ = sessionStore.save(nil)
        } else {
            session = loadedSession
            boundPublicUserID = storedBinding ?? loadedSession?.user?.id
            if storedBinding == nil, let loadedUserID = loadedSession?.user?.id {
                _ = sessionStore.saveBoundUserID(loadedUserID)
            }
        }
    }

    func favoriteSnapshot(eventNumber: Int) async throws -> CominaviFavoriteSnapshot {
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.getFavoriteSnapshot(.init(
                    path: .init(eventNumber: eventNumber)
                ))
            },
            isUnauthorized: { output in
                if case .unauthorized = output { true } else { false }
            }
        )
        switch output {
        case .ok(let response):
            let snapshot = try response.body.json
            return try validatedFavoriteSnapshot(
                eventNumber: snapshot.eventNumber,
                revision: snapshot.revision,
                favorites: snapshot.favorites.map {
                    ($0.wcID, $0.color, $0.notificationsEnabled)
                }
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw CominaviServiceError.server(
                code: "undocumented_response",
                message: "The ComiNavi service returned an undocumented response.",
                status: statusCode
            )
        }
    }

    func replaceFavorites(
        eventNumber: Int,
        baseRevision: Int,
        mutationID: UUID,
        favorites: [CominaviFavorite]
    ) async throws -> CominaviFavoriteSnapshot {
        let payload = Operations.ReplaceFavoriteSnapshot.Input.Body.JsonPayload(
            baseRevision: baseRevision,
            mutationID: mutationID.uuidString.lowercased(),
            favorites: favorites.map {
                Operations.ReplaceFavoriteSnapshot.Input.Body.JsonPayload
                    .FavoritesPayloadPayload(
                    wcID: $0.publicCircleID,
                    color: $0.color.rawValue,
                    notificationsEnabled: $0.notificationsEnabled
                )
            }.sorted { $0.wcID < $1.wcID }
        )
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.replaceFavoriteSnapshot(.init(
                    path: .init(eventNumber: eventNumber),
                    body: .json(payload)
                ))
            },
            isUnauthorized: { output in
                if case .unauthorized = output { true } else { false }
            }
        )
        switch output {
        case .ok(let response):
            let snapshot = try response.body.json
            return try validatedFavoriteSnapshot(
                eventNumber: snapshot.eventNumber,
                revision: snapshot.revision,
                favorites: snapshot.favorites.map {
                    ($0.wcID, $0.color, $0.notificationsEnabled)
                }
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw CominaviServiceError.server(
                code: "undocumented_response",
                message: "The ComiNavi service returned an undocumented response.",
                status: statusCode
            )
        }
    }

    func circlemsFavoriteImportPage(
        eventNumber: Int,
        cursor: String? = nil
    ) async throws -> CirclemsFavoriteImportPage {
        guard eventNumber > 0, cursor?.isEmpty != true else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.listCirclemsFavoriteImport(.init(
                    path: .init(eventNumber: eventNumber),
                    query: .init(cursor: cursor)
                ))
            },
            isUnauthorized: { output in
                if case .unauthorized = output { true } else { false }
            }
        )
        let payload: Operations.ListCirclemsFavoriteImport.Output.Ok.Body.JsonPayload
        switch output {
        case .ok(let response):
            payload = try response.body.json
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw CominaviServiceError.server(
                code: "undocumented_response",
                message: "The ComiNavi service returned an undocumented response.",
                status: statusCode
            )
        }
        let page = CirclemsFavoriteImportPage(
            eventNumber: payload.eventNumber,
            items: payload.items.map {
                CirclemsFavoriteImportItem(
                    wcID: $0.wcID,
                    updateID: $0.updateID,
                    circleName: $0.circleName,
                    color: $0.color,
                    memo: $0.memo
                )
            },
            nextCursor: payload.nextCursor
        )
        guard page.eventNumber == eventNumber,
              page.nextCursor?.isEmpty != true,
              Set(page.items.map(\.wcID)).count == page.items.count,
              page.items.allSatisfy({ item in
                  item.wcID > 0 && item.updateID > 0
                      && (0...9).contains(item.color)
                      && item.circleName.count <= 200
                      && item.memo.count <= 65_536
              })
        else { throw CominaviServiceError.invalidResponse }
        return page
    }

    func importXFollowings(userName: String) async throws -> FollowingImportPayload {
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.importXFollowings(.init(
                    body: .json(.init(userName: userName))
                ))
            },
            isUnauthorized: { output in
                if case .unauthorized = output { true } else { false }
            }
        )
        switch output {
        case .ok(let response):
            return try generatedDomainValue(
                FollowingImportPayload.self,
                from: response.body.json
            )
        case .badRequest(let response):
            throw generatedFollowingImportError(try response.body.json, status: 400)
        case .unauthorized:
            throw FollowingImportAPIError.notLoggedIn
        case .forbidden(let response):
            throw generatedFollowingImportError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedFollowingImportError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedFollowingImportError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedFollowingImportError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedFollowingImportError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedFollowingImportError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedFollowingImportError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedFollowingImportError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedFollowingImportError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedFollowingImportError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedFollowingImportError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedFollowingImportError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedFollowingImportError(try response.body.json, status: 503)
        case .undocumented:
            throw FollowingImportAPIError.invalidResponse
        }
    }

    func catalogs() async throws -> [CominaviCatalog] {
        let output = try await generatedAuthorizedRequest(
            operation: { try await $0.listCatalogs(.init()) },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        switch output {
        case .ok(let response):
            let catalogs = try response.body.json.items.map {
                try generatedDomainValue(CominaviCatalog.self, from: $0)
            }
            return try catalogs.map { try $0.validated() }
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func catalog(comiketNo: Int) async throws -> CominaviCatalog {
        guard comiketNo > 0 else { throw CominaviCatalogError.invalidManifest }
        let output = try await generatedAuthorizedRequest(
            operation: {
                try await $0.getCatalogManifest(.init(path: .init(comiketNo: comiketNo)))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        switch output {
        case .ok(let response):
            return try generatedDomainValue(
                CominaviCatalog.self,
                from: response.body.json
            ).validated()
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func authorizedCatalogRequest(
        method: String,
        path: String,
        headers: [String: String],
        invalidatedAccessToken: String?
    ) async throws -> CominaviCatalogAuthorizedRequest {
        guard method == "GET" || method == "HEAD",
              path.range(
                of: "^/api/v2/catalogs/[1-9][0-9]*/versions/[A-Za-z0-9._-]+/artifact$",
                options: .regularExpression
              ) != nil,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port
        else { throw CominaviCatalogError.invalidManifest }
        let authentication = try await serviceSession(
            forceRefresh: invalidatedAccessToken != nil,
            invalidatedAccessToken: invalidatedAccessToken
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.setValue(
            "Bearer \(authentication.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return CominaviCatalogAuthorizedRequest(
            request: request,
            accessToken: authentication.accessToken
        )
    }

    func registerPushToken(_ token: Data) async throws {
        guard !token.isEmpty, let bundleID = Bundle.main.bundleIdentifier else {
            throw CominaviServiceError.invalidResponse
        }
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        guard (64...256).contains(tokenString.count) else {
            throw CominaviServiceError.invalidResponse
        }
        let environment: Operations.RegisterPushDevice.Input.Body.JsonPayload.ApnsEnvironmentPayload =
            Self.apnsEnvironment == "sandbox" ? .sandbox : .production
        let installationID = Self.installationID
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.registerPushDevice(.init(
                    path: .init(installationID: installationID),
                    body: .json(.init(
                        token: tokenString,
                        apnsEnvironment: environment,
                        bundleID: bundleID,
                        locale: Locale.current.identifier,
                        timeZone: TimeZone.current.identifier,
                        enabled: true
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        switch output {
        case .ok(let response):
            let registered = try response.body.json
            guard registered.installationID == installationID, registered.enabled else {
                throw CominaviServiceError.invalidResponse
            }
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func disablePushDevice() async throws {
        let installationID = Self.installationID
        let output = try await generatedAuthorizedRequest(
            operation: {
                try await $0.disablePushDevice(.init(
                    path: .init(installationID: installationID)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        switch output {
        case .ok(let response):
            let disabled = try response.body.json
            guard disabled.installationID == installationID, !disabled.enabled else {
                throw CominaviServiceError.invalidResponse
            }
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func revokeSession() async throws {
        if accountDeletionIsPending {
            await applyPendingAccountDeletionLocally()
            if pendingAccountDeletionCleanup == nil {
                _ = try? await submitPendingAccountDeletion()
            }
            return
        }
        if pendingLogout != nil {
            await applyPendingLogoutLocally()
            try? await submitPendingLogout()
            return
        }
        let storedState = sessionStore.loadState()
        guard storedState.isAvailable else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        // An explicit provider transition deliberately clears the runtime
        // session before its network request, but leaves the predecessor in
        // protected storage until the replacement commits. Logout must revoke
        // that predecessor instead of degrading to a local-only tombstone.
        let protectedPredecessor = storedState.isLoggedOut ? nil : storedState.session
        let current = session ?? protectedPredecessor
        let protectedUserID = boundPublicUserID
            ?? storedState.boundUserID
            ?? current?.user?.id
        if let sessionUserID = current?.user?.id,
           let protectedUserID,
           sessionUserID != protectedUserID
        {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        guard let current,
              current.authVersion > 0,
              let refreshToken = current.refreshToken,
              !refreshToken.isEmpty,
              let publicUserID = protectedUserID,
              !publicUserID.isEmpty
        else {
            // A credential-less legacy or already-invalidated session has no
            // server refresh family to revoke. It still logs out locally and
            // clears staged provider authorization.
            try await clearAuthenticationState()
            do {
                try await authenticationFlowCanceller()
            } catch {
                throw CominaviServiceError.authenticationStorageUnavailable
            }
            return
        }
        let requestID = makeLogoutRequestID()
        let logoutPayload = Operations.LogoutAuthenticationSession.Input.Body.JsonPayload(
            requestId: requestID.uuidString.lowercased(),
            refreshToken: refreshToken
        )
        let payload = try canonicalCredentialJSON(logoutPayload)
        let transaction = CominaviLogoutTransaction(
            requestID: requestID,
            publicUserID: publicUserID,
            authVersion: current.authVersion,
            predecessorAccessToken: current.accessToken,
            predecessorRefreshToken: refreshToken,
            payload: payload
        )
        guard sessionStore.savePendingLogout(transaction) else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingLogout = transaction
        await applyPendingLogoutLocally()

        // Network/server failure cannot undo an explicit local logout. The
        // protected immutable command is retried on relaunch, reachability,
        // and scene activation until its receipt is acknowledged.
        try? await submitPendingLogout()
    }

    func hasPendingLogout() -> Bool { pendingLogout != nil }

    func resumePendingLogout() async throws {
        guard pendingLogout != nil else { return }
        await applyPendingLogoutLocally()
        try await submitPendingLogout()
    }

    @discardableResult
    func requestAccountDeletion() async throws -> CominaviAccountDeletionResult {
        if pendingAccountDeletionCleanup != nil {
            await applyPendingAccountDeletionLocally()
            throw CominaviServiceError.accountDeletionPending
        }
        if pendingAccountDeletion != nil {
            await applyPendingAccountDeletionLocally()
            return try await submitPendingAccountDeletion()
        }
        try requireNoPendingTermination()
        let storedState = sessionStore.loadState()
        guard storedState.isAvailable else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let protectedPredecessor = storedState.isLoggedOut ? nil : storedState.session
        let current = session ?? protectedPredecessor
        let publicUserID = boundPublicUserID
            ?? storedState.boundUserID
            ?? current?.user?.id
        guard let current,
              current.authVersion > 0,
              !current.accessToken.isEmpty,
              let publicUserID,
              !publicUserID.isEmpty,
              current.user?.id == nil || current.user?.id == publicUserID
        else { throw CominaviServiceError.notLoggedIn }

        let requestID = makeAccountDeletionRequestID()
        let payload = try canonicalCredentialJSON(AccountDeletionMutation(
            requestId: requestID.uuidString.lowercased(),
            confirmation: "DELETE"
        ))
        let transaction = CominaviAccountDeletionTransaction(
            requestID: requestID,
            publicUserID: publicUserID,
            authVersion: current.authVersion,
            predecessorAccessToken: current.accessToken,
            payload: payload
        )
        guard sessionStore.savePendingAccountDeletion(transaction) else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingAccountDeletion = transaction
        await applyPendingAccountDeletionLocally()
        return try await submitPendingAccountDeletion()
    }

    @discardableResult
    func resumePendingAccountDeletion() async throws -> CominaviAccountDeletionResult? {
        if pendingAccountDeletionCleanup != nil {
            await applyPendingAccountDeletionLocally()
            return nil
        }
        guard pendingAccountDeletion != nil else { return nil }
        await applyPendingAccountDeletionLocally()
        return try await submitPendingAccountDeletion()
    }

    func hasPendingAccountDeletion() -> Bool { accountDeletionIsPending }

    func accountDeletionCleanupReceipt() -> CominaviAccountDeletionCleanupReceipt? {
        pendingAccountDeletionCleanup
    }

    /// Called only after every public-user-scoped local artifact has been
    /// erased. Repeating the preconditions is intentional: if an earlier
    /// Keychain cleanup partially failed, the protected receipt remains the
    /// last durable pointer needed to finish on the next launch.
    func acknowledgeAccountDeletionLocalCleanup(requestID: UUID) async throws {
        guard let receipt = pendingAccountDeletionCleanup,
              receipt.requestID == requestID
        else { throw CominaviServiceError.invalidResponse }
        guard sessionStore.save(nil),
              sessionStore.saveLogoutTombstone(true),
              sessionStore.saveReauthenticationTombstone(false),
              sessionStore.savePendingAccountDeletion(nil),
              sessionStore.saveBoundUserID(nil)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingAccountDeletion = nil
        boundPublicUserID = nil
        guard sessionStore.savePendingAccountDeletionCleanup(nil) else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingAccountDeletionCleanup = nil
        authenticationStorageUnavailable = false
        requiresExplicitAuthentication = true
    }

    func realtimeUpdates(
        eventNumber: Int,
        after cursor: Int,
        limit: Int = 500
    ) async throws -> (updates: [CominaviRealtimeUpdate], nextCursor: Int, hasMore: Bool) {
        guard (1...10_000).contains(eventNumber),
              cursor >= 0,
              (1...500).contains(limit)
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: {
                try await $0.listRealtimeUpdates(.init(
                    path: .init(eventNumber: eventNumber),
                    query: .init(after: cursor, limit: limit)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let page: RealtimePage
        switch output {
        case .ok(let response):
            page = try generatedDomainValue(RealtimePage.self, from: response.body.json)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard page.eventNumber == eventNumber,
              page.updates.count <= limit,
              page.nextCursor >= cursor,
              page.updates.allSatisfy({ update in
                  update.cursor > cursor
                      && update.cursor <= page.nextCursor
                      && update.sourceRevision > 0
                      && !update.eventKey.isEmpty
                      && !update.updateKind.isEmpty
                      && !update.stateValue.isEmpty
                      && update.circles.count <= 20
                      && update.circles.allSatisfy {
                          $0.eventNumber == eventNumber && $0.wcID > 0
                      }
              })
        else { throw CominaviServiceError.invalidResponse }
        return (page.updates, page.nextCursor, page.hasMore)
    }

    func invalidateSession() async throws {
        try await clearAuthenticationState()
    }

    func storedUserProfile() -> CominaviUserProfile? { session?.user }

    func storedCirclemsAuthorizationCompletion()
        -> CirclemsPersistedAuthorizationCompletion?
    {
        guard pendingLogout == nil, !accountDeletionIsPending else { return nil }
        guard let marker = session?.circlemsAuthorizationCompletion,
              let profile = session?.user
        else { return nil }
        return CirclemsPersistedAuthorizationCompletion(marker: marker, profile: profile)
    }

    func clearCirclemsAuthorizationCompletion(flowRequestID: UUID) async throws {
        try requireNoPendingTermination()
        guard let current = session else { throw CominaviServiceError.notLoggedIn }
        guard let marker = current.circlemsAuthorizationCompletion else { return }
        guard marker.flowRequestID == flowRequestID else {
            throw CominaviServiceError.invalidResponse
        }
        try await persist(CominaviAuthenticationSession(
            tokenType: current.tokenType,
            accessToken: current.accessToken,
            expiresAt: current.expiresAt,
            authVersion: current.authVersion,
            refreshToken: current.refreshToken,
            refreshExpiresAt: current.refreshExpiresAt,
            user: current.user,
            circlemsAuthorizationCompletion: nil,
            googleAuthenticationCompletion: current.googleAuthenticationCompletion
        ), expectedAuthenticationGeneration: authenticationGeneration,
           preservingCirclemsAuthorizationCompletion: false)
    }

    func storedGoogleAuthenticationCompletion()
        -> GoogleAuthenticationCompletionMarker?
    {
        guard pendingLogout == nil, !accountDeletionIsPending else { return nil }
        return session?.googleAuthenticationCompletion
    }

    func clearGoogleAuthenticationCompletion(flowRequestID: UUID) async throws {
        try requireNoPendingTermination()
        guard let current = session else { throw CominaviServiceError.notLoggedIn }
        guard let marker = current.googleAuthenticationCompletion else { return }
        guard marker.flowRequestID == flowRequestID else {
            throw CominaviServiceError.invalidResponse
        }
        try await persist(CominaviAuthenticationSession(
            tokenType: current.tokenType,
            accessToken: current.accessToken,
            expiresAt: current.expiresAt,
            authVersion: current.authVersion,
            refreshToken: current.refreshToken,
            refreshExpiresAt: current.refreshExpiresAt,
            user: current.user,
            circlemsAuthorizationCompletion: current.circlemsAuthorizationCompletion,
            googleAuthenticationCompletion: nil
        ), expectedAuthenticationGeneration: authenticationGeneration,
           preservingGoogleAuthenticationCompletion: false)
    }

    func storedAppleAuthenticationCompletion()
        -> AppleAuthenticationCompletionMarker?
    {
        guard pendingLogout == nil, !accountDeletionIsPending else { return nil }
        return session?.appleAuthenticationCompletion
    }

    func clearAppleAuthenticationCompletion(flowRequestID: UUID) async throws {
        try requireNoPendingTermination()
        guard let current = session else { throw CominaviServiceError.notLoggedIn }
        guard let marker = current.appleAuthenticationCompletion else { return }
        guard marker.flowRequestID == flowRequestID else {
            throw CominaviServiceError.invalidResponse
        }
        try await persist(CominaviAuthenticationSession(
            tokenType: current.tokenType,
            accessToken: current.accessToken,
            expiresAt: current.expiresAt,
            authVersion: current.authVersion,
            refreshToken: current.refreshToken,
            refreshExpiresAt: current.refreshExpiresAt,
            user: current.user,
            circlemsAuthorizationCompletion: current.circlemsAuthorizationCompletion,
            googleAuthenticationCompletion: current.googleAuthenticationCompletion,
            appleAuthenticationCompletion: nil
        ), expectedAuthenticationGeneration: authenticationGeneration,
           preservingAppleAuthenticationCompletion: false)
    }

    /// Begins the production Circle.ms login. The browser talks to the
    /// ComiNavi backend, so provider access and refresh tokens never enter the
    /// app callback or this request.
    func startCirclemsAuthentication(
        _ flow: CirclemsAuthorizationFlow
    ) async throws -> CirclemsAuthorizationPublication {
        guard flow.purpose == .authenticate,
              flow.environment == circlemsEnvironmentProvider(),
              flow.authorizationURL == nil,
              flow.completionCode == nil
        else { throw CominaviServiceError.invalidResponse }
        let generation = try await beginExplicitIdentityTransition()
        let environment: Operations.StartCirclemsAuthentication.Input.Body.JsonPayload
            .EnvironmentPayload = flow.environment == .production ? .production : .sandbox
        let payload = Operations.StartCirclemsAuthentication.Input.Body.JsonPayload(
            requestId: flow.requestID.uuidString.lowercased(),
            clientInstanceID: flow.clientInstanceID.uuidString.lowercased(),
            environment: environment,
            codeChallenge: flow.codeChallenge
        )
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).startCirclemsAuthentication(.init(body: .json(payload)))
        }
        let start: CirclemsAuthorizationStart
        switch output {
        case .ok(let response):
            let payload = try response.body.json
            guard let authorizationURL = URL(string: payload.authorizationURL) else {
                throw CominaviServiceError.invalidResponse
            }
            start = CirclemsAuthorizationStart(
                authorizationURL: authorizationURL,
                expiresAt: payload.expiresAt
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(generation)
        guard flow.environment == circlemsEnvironmentProvider(),
              let circlemsAuthorizationFlowStorage
        else { throw CominaviServiceError.authenticationStorageUnavailable }
        // No await is permitted between the actor generation check and the
        // protected publication. Logout therefore either precedes this write
        // (and invalidates it) or follows it (and cancels the stored flow).
        let published = try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStorage
        ).recordStart(start, for: flow)
        return CirclemsAuthorizationPublication(
            flow: published,
            lease: providerFlowLease(
                provider: .circlems,
                requestID: published.requestID,
                generation: generation
            )
        )
    }

    func circlemsAuthorizationPublication(
        for flow: CirclemsAuthorizationFlow
    ) throws -> CirclemsAuthorizationPublication {
        try requireNoPendingTermination()
        guard let circlemsAuthorizationFlowStorage,
              try CirclemsAuthorizationFlowCoordinator(
                  storage: circlemsAuthorizationFlowStorage
              ).load() == flow
        else { throw CirclemsAuthorizationFlowError.expired }
        return CirclemsAuthorizationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .circlems,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
    }

    func recordCirclemsAuthorizationCallback(
        _ callbackURL: URL,
        callbackScheme: String,
        publication: CirclemsAuthorizationPublication
    ) throws -> CirclemsAuthorizationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .circlems,
            requestID: publication.flow.requestID
        )
        guard let circlemsAuthorizationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStorage
        ).recordCallback(
            callbackURL,
            callbackScheme: callbackScheme,
            for: publication.flow
        )
        return CirclemsAuthorizationPublication(flow: updated, lease: publication.lease)
    }

    func recordCirclemsAuthorizationSubmission(
        for publication: CirclemsAuthorizationPublication
    ) throws -> CirclemsAuthorizationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .circlems,
            requestID: publication.flow.requestID
        )
        guard let circlemsAuthorizationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStorage
        ).recordSubmissionAttempt(for: publication.flow)
        return CirclemsAuthorizationPublication(flow: updated, lease: publication.lease)
    }

    func recordPendingCirclemsAuthorizationCallback(
        _ callbackURL: URL,
        callbackScheme: String
    ) throws {
        try requireNoPendingTermination()
        guard let circlemsAuthorizationFlowStorage,
              let flow = try CirclemsAuthorizationFlowCoordinator(
                  storage: circlemsAuthorizationFlowStorage
              ).load()
        else { throw CirclemsAuthorizationFlowError.expired }
        let publication = CirclemsAuthorizationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .circlems,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
        _ = try recordCirclemsAuthorizationCallback(
            callbackURL,
            callbackScheme: callbackScheme,
            publication: publication
        )
    }

    func completeCirclemsAuthentication(
        _ flow: CirclemsAuthorizationFlow
    ) async throws -> CirclemsAuthenticationCompletion {
        try requireNoPendingTermination()
        guard flow.purpose == .authenticate,
              flow.environment == circlemsEnvironmentProvider(),
              let completionCode = flow.completionCode,
              flow.submissionAttemptedAt != nil
        else { throw CirclemsAuthorizationFlowError.expired }
        let generation = authenticationGeneration
        let payload = Operations.CompleteCirclemsAuthentication.Input.Body.JsonPayload(
            requestId: flow.requestID.uuidString.lowercased(),
            clientInstanceID: flow.clientInstanceID.uuidString.lowercased(),
            completionCode: completionCode,
            codeVerifier: flow.codeVerifier
        )
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).completeCirclemsAuthentication(.init(body: .json(payload)))
        }
        let authentication: CominaviAuthenticationSession
        let credentialReceipt: CirclemsCredentialReceipt
        switch output {
        case .ok(let response):
            let payload = try response.body.json
            let tokenType = try generatedDomainValue(
                String.self,
                from: payload.tokenType
            )
            let receiptProvider = try generatedDomainValue(
                String.self,
                from: payload.credentialReceipt.provider
            )
            guard let receiptRequestID = UUID(
                uuidString: payload.credentialReceipt.requestId
            ),
            payload.credentialReceipt.requestId
                == receiptRequestID.uuidString.lowercased(),
            let receiptClientInstanceID = UUID(
                uuidString: payload.credentialReceipt.clientInstanceID
            ),
            payload.credentialReceipt.clientInstanceID
                == receiptClientInstanceID.uuidString.lowercased()
            else { throw CominaviServiceError.invalidResponse }
            let profile = CominaviUserProfile(
                id: payload.user.id,
                displayName: payload.user.displayName,
                avatarURL: payload.user.avatarURL.flatMap(URL.init(string:)),
                revision: payload.user.revision,
                identities: payload.user.identities.map { identity in
                    CominaviProfileIdentity(
                        provider: identity.provider.rawValue,
                        environment: identity.environment?.rawValue,
                        providerUserID: identity.providerUserID.map(String.init),
                        email: identity.email
                    )
                }
            )
            authentication = CominaviAuthenticationSession(
                tokenType: tokenType,
                accessToken: payload.accessToken,
                expiresAt: payload.expiresAt,
                authVersion: payload.authVersion,
                refreshToken: payload.refreshToken,
                refreshExpiresAt: payload.refreshExpiresAt,
                user: profile
            )
            credentialReceipt = CirclemsCredentialReceipt(
                requestID: receiptRequestID,
                clientInstanceID: receiptClientInstanceID,
                provider: receiptProvider,
                environment: payload.credentialReceipt.environment.rawValue,
                subject: payload.credentialReceipt.subject,
                credentialRevision: payload.credentialReceipt.credentialRevision
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        let validatedAuthentication = try validatedProductionAuthentication(authentication)
        let receipt = try validatedCredentialReceipt(
            credentialReceipt,
            flow: flow,
            profile: validatedAuthentication.user
        )
        let markedAuthentication = CominaviAuthenticationSession(
            tokenType: validatedAuthentication.tokenType,
            accessToken: validatedAuthentication.accessToken,
            expiresAt: validatedAuthentication.expiresAt,
            authVersion: validatedAuthentication.authVersion,
            refreshToken: validatedAuthentication.refreshToken,
            refreshExpiresAt: validatedAuthentication.refreshExpiresAt,
            user: validatedAuthentication.user,
            circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker(
                flowRequestID: flow.requestID,
                credentialReceipt: receipt
            )
        )
        // Session + validated completion receipt share one protected Keychain
        // blob. A crash after this boundary can finish local scrubbing without
        // replaying an already-rotated provider credential.
        try await persist(
            markedAuthentication,
            expectedAuthenticationGeneration: generation,
            allowingIdentityTransition: true
        )
        return CirclemsAuthenticationCompletion(
            session: markedAuthentication,
            credentialReceipt: receipt
        )
    }

    func startCirclemsLink(
        _ flow: CirclemsAuthorizationFlow
    ) async throws -> CirclemsAuthorizationPublication {
        guard flow.purpose == .link,
              flow.environment == circlemsEnvironmentProvider(),
              let expectedUserID = flow.expectedPublicUserID,
              flow.authorizationURL == nil,
              flow.completionCode == nil
        else { throw CominaviServiceError.invalidResponse }
        guard boundPublicUserID == expectedUserID,
              !requiresExplicitAuthentication
        else { throw CominaviServiceError.notLoggedIn }
        let generation = authenticationGeneration
        let current = try await serviceSession()
        guard current.user?.id == expectedUserID else {
            throw CominaviServiceError.notLoggedIn
        }
        let environment: Operations.StartCirclemsIdentityLink.Input.Body.JsonPayload.EnvironmentPayload =
            switch flow.environment {
            case .production: .production
            case .testing: .sandbox
            }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.startCirclemsIdentityLink(.init(body: .json(.init(
                    requestId: flow.requestID.uuidString.lowercased(),
                    clientInstanceID: flow.clientInstanceID.uuidString.lowercased(),
                    environment: environment,
                    codeChallenge: flow.codeChallenge
                ))))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let start: CirclemsAuthorizationStart
        switch output {
        case .ok(let response):
            start = try generatedDomainValue(
                CirclemsAuthorizationStart.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(generation)
        guard flow.environment == circlemsEnvironmentProvider(),
              let circlemsAuthorizationFlowStorage
        else { throw CominaviServiceError.authenticationStorageUnavailable }
        let published = try CirclemsAuthorizationFlowCoordinator(
            storage: circlemsAuthorizationFlowStorage
        ).recordStart(start, for: flow)
        return CirclemsAuthorizationPublication(
            flow: published,
            lease: providerFlowLease(
                provider: .circlems,
                requestID: published.requestID,
                generation: generation
            )
        )
    }

    func completeCirclemsLink(
        _ flow: CirclemsAuthorizationFlow
    ) async throws -> CirclemsLinkCompletion {
        guard flow.purpose == .link,
              flow.environment == circlemsEnvironmentProvider(),
              let expectedUserID = flow.expectedPublicUserID,
              let completionCode = flow.completionCode,
              flow.submissionAttemptedAt != nil
        else { throw CirclemsAuthorizationFlowError.expired }
        guard boundPublicUserID == expectedUserID,
              !requiresExplicitAuthentication
        else { throw CominaviServiceError.notLoggedIn }
        let generation = authenticationGeneration
        let current = try await serviceSession()
        guard current.user?.id == expectedUserID else {
            throw CominaviServiceError.notLoggedIn
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.completeCirclemsIdentityLink(.init(body: .json(.init(
                    requestId: flow.requestID.uuidString.lowercased(),
                    clientInstanceID: flow.clientInstanceID.uuidString.lowercased(),
                    completionCode: completionCode,
                    codeVerifier: flow.codeVerifier
                ))))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: CirclemsLinkEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                CirclemsLinkEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        let receipt = try validatedCredentialReceipt(
            envelope.credentialReceipt.domain,
            flow: flow,
            profile: envelope.user
        )
        try await persist(
            profile: envelope.user,
            circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker(
                flowRequestID: flow.requestID,
                credentialReceipt: receipt
            ),
            expectedAuthenticationGeneration: generation
        )
        return CirclemsLinkCompletion(
            profile: envelope.user,
            credentialReceipt: receipt
        )
    }

    func googleEntryGrant(
        for flow: GoogleAuthenticationFlow,
        invitationToken: String
    ) async throws -> GoogleAuthenticationPublication {
        try flow.validate()
        guard GoogleAuthenticationFlow.isCanonicalNonce(flow.nonce),
              SharedPlanInvitationLink.isValid(token: invitationToken)
        else { throw CominaviServiceError.invalidResponse }
        let generation = authenticationGeneration
        let payload = Operations.IssueGoogleAuthenticationEntryGrant.Input.Body
            .JsonPayload(nonce: flow.nonce, inviteToken: invitationToken)
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).issueGoogleAuthenticationEntryGrant(.init(body: .json(payload)))
        }
        let grant: CominaviGoogleEntryGrant
        switch output {
        case .ok(let response):
            let payload = try response.body.json
            grant = CominaviGoogleEntryGrant(
                entryGrant: payload.entryGrant,
                expiresAt: payload.expiresAt
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        guard grant.entryGrant.utf8.count == 43,
              grant.expiresAt > Date()
        else { throw CominaviServiceError.invalidResponse }
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(generation)
        guard let googleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let published = try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStorage
        ).recordEntryGrant(
            grant.entryGrant,
            expiresAt: grant.expiresAt,
            for: flow
        )
        return GoogleAuthenticationPublication(
            flow: published,
            lease: providerFlowLease(
                provider: .google,
                requestID: published.requestID,
                generation: generation
            )
        )
    }

    func googleAuthenticationPublication(
        for flow: GoogleAuthenticationFlow
    ) throws -> GoogleAuthenticationPublication {
        try requireNoPendingTermination()
        guard let googleAuthenticationFlowStorage,
              try GoogleAuthenticationFlowCoordinator(
                  storage: googleAuthenticationFlowStorage
              ).load() == flow
        else { throw GoogleAuthenticationFlowError.expired }
        return GoogleAuthenticationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .google,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
    }

    func recordGoogleEntryGrantCallback(
        _ callbackURL: URL,
        publication: GoogleAuthenticationPublication
    ) throws -> GoogleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .google,
            requestID: publication.flow.requestID
        )
        guard publication.flow.entryContext == .special,
              let googleAuthenticationFlowStorage
        else { throw GoogleAuthenticationFlowError.unavailable }
        let grant = try GoogleEntryGrantCallbackParser.parse(
            callbackURL,
            expectedNonce: publication.flow.nonce
        )
        let updated = try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStorage
        ).recordEntryGrant(
            grant.entryGrant,
            expiresAt: grant.expiresAt,
            for: publication.flow
        )
        return GoogleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    func recordPendingGoogleEntryGrantCallback(_ callbackURL: URL) throws {
        try requireNoPendingTermination()
        guard let googleAuthenticationFlowStorage,
              let flow = try GoogleAuthenticationFlowCoordinator(
                  storage: googleAuthenticationFlowStorage
              ).load(),
              flow.entryContext == .special
        else { throw GoogleAuthenticationFlowError.unavailable }
        let publication = GoogleAuthenticationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .google,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
        _ = try recordGoogleEntryGrantCallback(callbackURL, publication: publication)
    }

    func recordGoogleIDToken(
        _ idToken: String,
        publication: GoogleAuthenticationPublication
    ) throws -> GoogleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .google,
            requestID: publication.flow.requestID
        )
        guard let googleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStorage
        ).recordIDToken(idToken, for: publication.flow)
        return GoogleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    func recordGoogleAuthenticationSubmission(
        for publication: GoogleAuthenticationPublication
    ) throws -> GoogleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .google,
            requestID: publication.flow.requestID
        )
        guard let googleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try GoogleAuthenticationFlowCoordinator(
            storage: googleAuthenticationFlowStorage
        ).recordSubmissionAttempt(for: publication.flow)
        return GoogleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    @discardableResult
    func authenticateWithGoogle(
        _ flow: GoogleAuthenticationFlow
    ) async throws -> CominaviAuthenticationSession {
        try flow.validate()
        guard let idToken = flow.idToken,
              let entryGrant = flow.entryGrant,
              flow.isReadyToAuthenticate
        else {
            throw CominaviServiceError.invalidResponse
        }
        let generation = try await beginExplicitIdentityTransition()
        let payload = Operations.AuthenticateWithGoogle.Input.Body.JsonPayload(
            requestId: flow.requestID.uuidString.lowercased(),
            idToken: idToken,
            entryGrant: entryGrant,
            nonce: flow.nonce
        )
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).authenticateWithGoogle(.init(body: .json(payload)))
        }
        let authentication: CominaviAuthenticationSession
        switch output {
        case .ok(let response):
            authentication = try generatedDomainValue(
                CominaviAuthenticationSession.self,
                from: response.body.json
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        let validated = try validatedProductionAuthentication(authentication)
        guard let profile = validated.user,
              profile.identities.contains(where: { $0.provider == "google" })
        else { throw CominaviServiceError.invalidResponse }
        let marked = CominaviAuthenticationSession(
            tokenType: validated.tokenType,
            accessToken: validated.accessToken,
            expiresAt: validated.expiresAt,
            authVersion: validated.authVersion,
            refreshToken: validated.refreshToken,
            refreshExpiresAt: validated.refreshExpiresAt,
            user: profile,
            googleAuthenticationCompletion: GoogleAuthenticationCompletionMarker(
                flowRequestID: flow.requestID,
                publicUserID: profile.id
            )
        )
        // The usable service session and non-secret completion marker share a
        // single protected blob. Once this succeeds, relaunch finalization must
        // clear the local ID token/grant instead of sending them again.
        try await persist(
            marked,
            expectedAuthenticationGeneration: generation,
            allowingIdentityTransition: true
        )
        return marked
    }

    func appleEntryGrant(
        for flow: AppleAuthenticationFlow,
        invitationToken: String
    ) async throws -> AppleAuthenticationPublication {
        try flow.validate()
        guard AppleAuthenticationFlow.isCanonicalNonce(flow.nonce),
              SharedPlanInvitationLink.isValid(token: invitationToken)
        else { throw CominaviServiceError.invalidResponse }
        let generation = authenticationGeneration
        let payload = Operations.IssueAppleAuthenticationEntryGrant.Input.Body
            .JsonPayload(nonce: flow.nonce, inviteToken: invitationToken)
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).issueAppleAuthenticationEntryGrant(.init(body: .json(payload)))
        }
        let grant: CominaviAppleEntryGrant
        switch output {
        case .ok(let response):
            let payload = try response.body.json
            grant = CominaviAppleEntryGrant(
                entryGrant: payload.entryGrant,
                expiresAt: payload.expiresAt
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(generation)
        guard let appleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let published = try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStorage
        ).recordEntryGrant(
            grant.entryGrant,
            expiresAt: grant.expiresAt,
            for: flow
        )
        return AppleAuthenticationPublication(
            flow: published,
            lease: providerFlowLease(
                provider: .apple,
                requestID: published.requestID,
                generation: generation
            )
        )
    }

    func appleAuthenticationPublication(
        for flow: AppleAuthenticationFlow
    ) throws -> AppleAuthenticationPublication {
        try requireNoPendingTermination()
        guard let appleAuthenticationFlowStorage,
              try AppleAuthenticationFlowCoordinator(
                  storage: appleAuthenticationFlowStorage
              ).load() == flow
        else { throw AppleAuthenticationFlowError.expired }
        return AppleAuthenticationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .apple,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
    }

    func recordAppleEntryGrantCallback(
        _ callbackURL: URL,
        publication: AppleAuthenticationPublication
    ) throws -> AppleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .apple,
            requestID: publication.flow.requestID
        )
        guard publication.flow.entryContext == .special,
              let appleAuthenticationFlowStorage
        else { throw AppleAuthenticationFlowError.unavailable }
        let grant = try AppleEntryGrantCallbackParser.parse(
            callbackURL,
            expectedNonce: publication.flow.nonce
        )
        let updated = try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStorage
        ).recordEntryGrant(
            grant.entryGrant,
            expiresAt: grant.expiresAt,
            for: publication.flow
        )
        return AppleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    func recordPendingAppleEntryGrantCallback(_ callbackURL: URL) throws {
        try requireNoPendingTermination()
        guard let appleAuthenticationFlowStorage,
              let flow = try AppleAuthenticationFlowCoordinator(
                  storage: appleAuthenticationFlowStorage
              ).load(),
              flow.entryContext == .special
        else { throw AppleAuthenticationFlowError.unavailable }
        let publication = AppleAuthenticationPublication(
            flow: flow,
            lease: providerFlowLease(
                provider: .apple,
                requestID: flow.requestID,
                generation: authenticationGeneration
            )
        )
        _ = try recordAppleEntryGrantCallback(callbackURL, publication: publication)
    }

    func recordAppleCredential(
        _ credential: AppleAuthorizationCredential,
        publication: AppleAuthenticationPublication
    ) throws -> AppleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .apple,
            requestID: publication.flow.requestID
        )
        guard let appleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStorage
        ).recordCredential(credential, for: publication.flow)
        return AppleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    func recordAppleAuthenticationSubmission(
        for publication: AppleAuthenticationPublication
    ) throws -> AppleAuthenticationPublication {
        try requireProviderFlowLease(
            publication.lease,
            provider: .apple,
            requestID: publication.flow.requestID
        )
        guard let appleAuthenticationFlowStorage else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        let updated = try AppleAuthenticationFlowCoordinator(
            storage: appleAuthenticationFlowStorage
        ).recordSubmissionAttempt(for: publication.flow)
        return AppleAuthenticationPublication(flow: updated, lease: publication.lease)
    }

    @discardableResult
    func authenticateWithApple(
        _ flow: AppleAuthenticationFlow
    ) async throws -> CominaviAuthenticationSession {
        try flow.validate()
        guard let identityToken = flow.identityToken,
              let authorizationCode = flow.authorizationCode,
              let entryGrant = flow.entryGrant,
              flow.isReadyToAuthenticate
        else { throw CominaviServiceError.invalidResponse }
        let generation = try await beginExplicitIdentityTransition()
        let payload = Operations.AuthenticateWithApple.Input.Body.JsonPayload(
            requestId: flow.requestID.uuidString.lowercased(),
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            entryGrant: entryGrant,
            nonce: flow.nonce,
            displayName: flow.displayName
        )
        let output = try await performGeneratedOperation {
            try await generatedClient(
                exactRequestBody: canonicalCredentialJSON(payload)
            ).authenticateWithApple(.init(body: .json(payload)))
        }
        let authentication: CominaviAuthenticationSession
        switch output {
        case .ok(let response):
            authentication = try generatedDomainValue(
                CominaviAuthenticationSession.self,
                from: response.body.json
            )
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        let validated = try validatedProductionAuthentication(authentication)
        guard let profile = validated.user,
              profile.identities.contains(where: { $0.provider == "apple" })
        else { throw CominaviServiceError.invalidResponse }
        let marked = CominaviAuthenticationSession(
            tokenType: validated.tokenType,
            accessToken: validated.accessToken,
            expiresAt: validated.expiresAt,
            authVersion: validated.authVersion,
            refreshToken: validated.refreshToken,
            refreshExpiresAt: validated.refreshExpiresAt,
            user: profile,
            appleAuthenticationCompletion: AppleAuthenticationCompletionMarker(
                flowRequestID: flow.requestID,
                publicUserID: profile.id
            )
        )
        try await persist(
            marked,
            expectedAuthenticationGeneration: generation,
            allowingIdentityTransition: true
        )
        return marked
    }

    func fetchProfile() async throws -> CominaviUserProfile {
        let generation = authenticationGeneration
        let output = try await generatedAuthorizedRequest(
            operation: { try await $0.getCurrentUserProfile(.init()) },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let profile: CominaviUserProfile
        switch output {
        case .ok(let response):
            profile = try generatedDomainValue(
                CominaviUserProfile.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        try await persist(
            profile: profile,
            expectedAuthenticationGeneration: generation
        )
        return profile
    }

    func updateDisplayName(
        _ displayName: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        let generation = authenticationGeneration
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.updateCurrentUserProfile(.init(body: .json(.init(
                    requestId: requestID.uuidString.lowercased(),
                    baseRevision: baseRevision,
                    displayName: displayName
                ))))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let profile: CominaviUserProfile
        switch output {
        case .ok(let response):
            profile = try generatedDomainValue(
                CominaviUserProfile.self,
                from: response.body.json.user
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        try await persist(
            profile: profile,
            expectedAuthenticationGeneration: generation
        )
        return profile
    }

    func uploadAvatar(
        _ data: Data,
        contentType: String,
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        let generation = authenticationGeneration
        guard !data.isEmpty,
              ["image/jpeg", "image/png", "image/webp"].contains(contentType)
        else { throw CominaviServiceError.invalidResponse }
        let body: Operations.ReplaceCurrentUserAvatar.Input.Body = switch contentType {
        case "image/jpeg": .jpeg(HTTPBody(data))
        case "image/png": .png(HTTPBody(data))
        case "image/webp": .imageWebp(HTTPBody(data))
        default: throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.replaceCurrentUserAvatar(.init(
                    headers: .init(
                        ifMatch: "\"profile:\(baseRevision)\"",
                        idempotencyKey: requestID.uuidString.lowercased(),
                        contentLength: String(data.count)
                    ),
                    body: body
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let profile: CominaviUserProfile
        switch output {
        case .ok(let response):
            profile = try generatedDomainValue(
                CominaviUserProfile.self,
                from: response.body.json.user
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        try await persist(
            profile: profile,
            expectedAuthenticationGeneration: generation
        )
        avatarDataCache.removeAll()
        return profile
    }

    func deleteAvatar(
        baseRevision: Int,
        requestID: UUID
    ) async throws -> CominaviUserProfile {
        let generation = authenticationGeneration
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.removeCurrentUserAvatar(.init(headers: .init(
                    ifMatch: "\"profile:\(baseRevision)\"",
                    idempotencyKey: requestID.uuidString.lowercased()
                )))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let profile: CominaviUserProfile
        switch output {
        case .ok(let response):
            profile = try generatedDomainValue(
                CominaviUserProfile.self,
                from: response.body.json.user
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        try await persist(
            profile: profile,
            expectedAuthenticationGeneration: generation
        )
        avatarDataCache.removeAll()
        return profile
    }

    func loadAvatarData(from url: URL) async throws -> Data {
        let (path, userID) = try authenticatedAvatarPath(for: url)
        if let cached = avatarDataCache[path] { return cached }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.getUserAvatar(.init(path: .init(userID: userID)))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let data: Data
        switch output {
        case .ok(let response):
            guard let contentLength = Int(response.headers.contentLength),
                  (1...10_000_000).contains(contentLength)
            else { throw CominaviServiceError.invalidResponse }
            let body = switch response.body {
            case .jpeg(let body), .png(let body), .imageWebp(let body): body
            }
            data = try await Data(collecting: body, upTo: contentLength)
            guard data.count == contentLength else {
                throw CominaviServiceError.invalidResponse
            }
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        avatarDataCache[path] = data
        return data
    }

    func fetchPlans() async throws -> [SharedPlan] {
        var result: [SharedPlan] = []
        var cursor: String?
        repeat {
            let requestCursor = cursor
            let output = try await generatedAuthorizedRequest(
                operation: { client in
                    try await client.listSharedPlans(.init(query: .init(
                        limit: 100,
                        cursor: requestCursor
                    )))
                },
                isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
                validatesErrorResponses: true
            )
            let page: PlanPage
            switch output {
            case .ok(let response):
                page = try generatedDomainValue(PlanPage.self, from: response.body.json)
            case .unauthorized(let response):
                throw generatedServiceError(try response.body.json, status: 401)
            default:
                throw CominaviServiceError.invalidResponse
            }
            let plans = page.items.compactMap(\.domain)
            guard page.items.count <= 100,
                  plans.count == page.items.count,
                  page.nextCursor?.isEmpty != true
            else {
                throw CominaviServiceError.invalidResponse
            }
            result.append(contentsOf: plans)
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    func fetchPlan(id: String) async throws -> SharedPlan {
        guard Self.isCanonicalUUIDString(id) else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.getSharedPlan(.init(path: .init(planID: id)))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let wire: PlanWireResource
        switch output {
        case .ok(let response):
            wire = try generatedDomainValue(
                PlanWireResource.self,
                from: response.body.json.plan
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard wire.id == id, let plan = wire.domain else {
            throw CominaviServiceError.invalidResponse
        }
        return plan
    }

    func fetchSyncBootstrap(planID: String) async throws -> SharedPlanSyncBootstrap {
        guard Self.isCanonicalUUIDString(planID) else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.getSharedPlanSyncSnapshot(.init(
                    path: .init(planID: planID)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        switch output {
        case .ok(let response):
            return try generatedDomainValue(
                SharedPlanSyncBootstrap.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func sharedPlanSyncWebSocketRequest(planID: String) async throws -> URLRequest {
        guard let planUUID = UUID(uuidString: planID),
              planID == planUUID.uuidString.lowercased(),
              var components = URLComponents(
                  url: baseURL.appendingPathComponent(
                      "/api/v2/plans/\(planID)/sync"
                  ),
                  resolvingAgainstBaseURL: false
              )
        else { throw SharedPlanError.syncProtocolViolation }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw SharedPlanError.syncProtocolViolation
        }
        guard let url = components.url else {
            throw SharedPlanError.syncProtocolViolation
        }
        let currentSession = try await serviceSession()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue(
            "Bearer \(currentSession.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    func createPlan(
        requestID: UUID,
        name: String,
        comiketNo: Int
    ) async throws -> SharedPlanMutationResult {
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.createSharedPlan(.init(body: .json(.init(
                    requestId: requestID.uuidString.lowercased(),
                    name: name,
                    comiketNo: comiketNo
                ))))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .created(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultStatus == .active
        else { throw CominaviServiceError.invalidResponse }
        guard let syncBootstrap = envelope.syncBootstrap else {
            throw CominaviServiceError.invalidResponse
        }
        return SharedPlanMutationResult(
            plan: plan,
            receipt: receipt,
            syncBootstrap: syncBootstrap
        )
    }

    func renamePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int,
        name: String
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(id), baseRevision >= 0 else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.updateSharedPlan(.init(
                    path: .init(planID: id),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision,
                        name: name
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              envelope.plan.id == id,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultRevision == baseRevision + 1,
              receipt.resultStatus == .active,
              plan.revision >= receipt.resultRevision
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanMutationResult(plan: plan, receipt: receipt)
    }

    func archivePlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(id), baseRevision >= 0 else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.archiveSharedPlan(.init(
                    path: .init(planID: id),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              envelope.plan.id == id,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultRevision == baseRevision + 1,
              receipt.resultStatus == .archived,
              plan.revision >= receipt.resultRevision
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanMutationResult(plan: plan, receipt: receipt)
    }

    func reopenPlan(
        id: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(id), baseRevision >= 0 else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.updateSharedPlan(.init(
                    path: .init(planID: id),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision,
                        archived: false
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              envelope.plan.id == id,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultRevision == baseRevision + 1,
              receipt.resultStatus == .active,
              plan.revision >= receipt.resultRevision
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanMutationResult(plan: plan, receipt: receipt)
    }

    func previewInvitation(token: String) async throws -> SharedPlanInvitationPreview {
        guard SharedPlanInvitationLink.isValid(token: token) else {
            throw SharedPlanError.invalidInvite
        }
        let output = try await performGeneratedOperation {
            try await generatedClient(validatesErrorResponses: true)
                .previewSharedPlanInvitation(.init(path: .init(token: token)))
        }
        switch output {
        case .ok(let response):
            return try generatedDomainValue(
                SharedPlanInvitationPreview.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
    }

    func acceptInvitation(
        token: String,
        requestID: UUID
    ) async throws -> SharedPlanMutationResult {
        guard SharedPlanInvitationLink.isValid(token: token) else {
            throw SharedPlanError.invalidInvite
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.acceptSharedPlanInvitation(.init(
                    path: .init(token: token),
                    body: .json(.init(requestId: requestID.uuidString.lowercased()))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultStatus == .active
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanMutationResult(plan: plan, receipt: receipt)
    }

    func fetchMembers(
        planID: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> SharedPlanMemberPage {
        guard Self.isCanonicalUUIDString(planID) else {
            throw CominaviServiceError.invalidResponse
        }
        guard (1...100).contains(limit), cursor?.isEmpty != true else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.listSharedPlanMembers(.init(
                    path: .init(planID: planID),
                    query: .init(limit: limit, cursor: cursor)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let page: PlanMemberPageWire
        switch output {
        case .ok(let response):
            page = try generatedDomainValue(
                PlanMemberPageWire.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        let items = page.items.compactMap(\.domain)
        guard page.items.count <= limit,
              items.count == page.items.count,
              Set(items.map(\.userID)).count == items.count,
              page.nextCursor?.isEmpty != true
        else {
            throw CominaviServiceError.invalidResponse
        }
        return SharedPlanMemberPage(items: items, nextCursor: page.nextCursor)
    }

    func revokeMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(planID),
              Self.isLowercaseHex(userID, count: 32),
              baseRevision >= 0
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.revokeSharedPlanMember(.init(
                    path: .init(planID: planID, userID: userID),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        return try validatedPlanMutation(
            envelope,
            planID: planID,
            requestID: requestID,
            baseRevision: baseRevision
        )
    }

    func reinstateMember(
        planID: String,
        userID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(planID),
              Self.isLowercaseHex(userID, count: 32),
              baseRevision >= 0
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.reinstateSharedPlanMember(.init(
                    path: .init(planID: planID, userID: userID),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        return try validatedPlanMutation(
            envelope,
            planID: planID,
            requestID: requestID,
            baseRevision: baseRevision
        )
    }

    func transferOwnership(
        planID: String,
        newOwnerUserID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(planID),
              Self.isLowercaseHex(newOwnerUserID, count: 32),
              baseRevision >= 0
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.transferSharedPlanOwnership(.init(
                    path: .init(planID: planID),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision,
                        newOwnerUserID: newOwnerUserID
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        return try validatedPlanMutation(
            envelope,
            planID: planID,
            requestID: requestID,
            baseRevision: baseRevision
        )
    }

    func fetchInvitations(
        planID: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> SharedPlanInvitationPage {
        guard Self.isCanonicalUUIDString(planID) else {
            throw CominaviServiceError.invalidResponse
        }
        guard (1...100).contains(limit), cursor?.isEmpty != true else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.listSharedPlanInvitations(.init(
                    path: .init(planID: planID),
                    query: .init(limit: limit, cursor: cursor)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let page: PlanInvitationPageWire
        switch output {
        case .ok(let response):
            page = try generatedDomainValue(
                PlanInvitationPageWire.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        let items = page.items.compactMap(\.domain)
        guard page.items.count <= limit,
              items.count == page.items.count,
              Set(items.map(\.invitationID)).count == items.count,
              page.nextCursor?.isEmpty != true
        else {
            throw CominaviServiceError.invalidResponse
        }
        return SharedPlanInvitationPage(items: items, nextCursor: page.nextCursor)
    }

    func createInvitation(
        planID: String,
        requestID: UUID,
        baseRevision: Int,
        expiresAt: Date
    ) async throws -> SharedPlanCreatedInvitation {
        let expiresAt = SharedPlanInvitationExpiration.canonical(expiresAt)
        guard Self.isCanonicalUUIDString(planID),
              baseRevision >= 0,
              expiresAt > Date.distantPast
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.createSharedPlanInvitation(.init(
                    path: .init(planID: planID),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision,
                        expiresAt: expiresAt
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: InvitationCreationEnvelope
        switch output {
        case .created(let response):
            envelope = try generatedDomainValue(
                InvitationCreationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.receipt.requestId == requestID,
              let receipt = envelope.receipt.domain,
              receipt.resultRevision == baseRevision + 1,
              receipt.resultStatus == .active,
              envelope.expiresAt == expiresAt,
              SharedPlanInvitationLink.isValid(token: envelope.token),
              envelope.canonicalURL == SharedPlanInvitationLink.canonicalURL(
                  token: envelope.token
              ),
              envelope.fallbackURL == SharedPlanInvitationLink.fallbackURL(
                  token: envelope.token
              )
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: envelope.invitationID,
            token: envelope.token,
            expiresAt: envelope.expiresAt,
            canonicalURL: envelope.canonicalURL,
            fallbackURL: envelope.fallbackURL,
            receipt: receipt
        )
    }

    func revokeInvitation(
        planID: String,
        invitationID: String,
        requestID: UUID,
        baseRevision: Int
    ) async throws -> SharedPlanMutationResult {
        guard Self.isCanonicalUUIDString(planID),
              Self.isCanonicalUUIDString(invitationID),
              baseRevision >= 0
        else { throw CominaviServiceError.invalidResponse }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.revokeSharedPlanInvitation(.init(
                    path: .init(planID: planID, invitationID: invitationID),
                    body: .json(.init(
                        requestId: requestID.uuidString.lowercased(),
                        baseRevision: baseRevision
                    ))
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: PlanMutationEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                PlanMutationEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        return try validatedPlanMutation(
            envelope,
            planID: planID,
            requestID: requestID,
            baseRevision: baseRevision
        )
    }

    func fetchNotifications(
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> SharedPlanNotificationPage {
        guard (1...100).contains(limit), cursor?.isEmpty != true else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.listNotifications(.init(query: .init(
                    limit: limit,
                    cursor: cursor
                )))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let page: NotificationPageWire
        switch output {
        case .ok(let response):
            page = try generatedDomainValue(
                NotificationPageWire.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        let items = page.items.compactMap(\.domain)
        guard page.items.count <= limit,
              items.count == page.items.count,
              Set(items.map(\.id)).count == items.count,
              page.nextCursor?.isEmpty != true
        else {
            throw CominaviServiceError.invalidResponse
        }
        return SharedPlanNotificationPage(items: items, nextCursor: page.nextCursor)
    }

    func markNotificationRead(id: String) async throws -> SharedPlanNotificationReadReceipt {
        guard Self.isLowercaseHex(id, count: 64) else {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await generatedAuthorizedRequest(
            operation: { client in
                try await client.markNotificationRead(.init(
                    path: .init(eventID: id)
                ))
            },
            isUnauthorized: { if case .unauthorized = $0 { true } else { false } },
            validatesErrorResponses: true
        )
        let envelope: NotificationReadEnvelope
        switch output {
        case .ok(let response):
            envelope = try generatedDomainValue(
                NotificationReadEnvelope.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard envelope.id == id else { throw CominaviServiceError.invalidResponse }
        return SharedPlanNotificationReadReceipt(id: envelope.id, readAt: envelope.readAt)
    }

    private func validatedPlanMutation(
        _ envelope: PlanMutationEnvelope,
        planID: String,
        requestID: UUID,
        baseRevision: Int
    ) throws -> SharedPlanMutationResult {
        guard envelope.receipt.requestId == requestID,
              envelope.plan.id == planID,
              let plan = envelope.plan.domain,
              let receipt = envelope.receipt.domain,
              receipt.resultRevision == baseRevision + 1,
              plan.revision >= receipt.resultRevision
        else { throw CominaviServiceError.invalidResponse }
        return SharedPlanMutationResult(plan: plan, receipt: receipt)
    }

    private static func paginatedPath(
        base: String,
        limit: Int,
        cursor: String?
    ) throws -> String {
        guard (1...100).contains(limit), cursor?.isEmpty != true else {
            throw CominaviServiceError.invalidResponse
        }
        var components = URLComponents()
        components.path = base
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let path = components.string else {
            throw CominaviServiceError.invalidResponse
        }
        return path
    }

    private static func canonicalRFC3339(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private static func isCanonicalUUIDString(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private func generatedAuthorizedRequest<Output: Sendable>(
        operation: @escaping @Sendable (Client) async throws -> Output,
        isUnauthorized: @escaping @Sendable (Output) -> Bool,
        validatesErrorResponses: Bool = false
    ) async throws -> Output {
        var currentSession = try await serviceSession()
        var output = try await performGeneratedOperation {
            try await operation(generatedClient(
                accessToken: currentSession.accessToken,
                validatesErrorResponses: validatesErrorResponses
            ))
        }
        if isUnauthorized(output) {
            currentSession = try await serviceSession(
                forceRefresh: true,
                invalidatedAccessToken: currentSession.accessToken
            )
            output = try await performGeneratedOperation {
                try await operation(generatedClient(
                    accessToken: currentSession.accessToken,
                    validatesErrorResponses: validatesErrorResponses
                ))
            }
        }
        return output
    }

    private func generatedClient(
        accessToken: String? = nil,
        exactRequestBody: Data? = nil,
        validatesErrorResponses: Bool = false
    ) -> Client {
        let requestTransport = transport
        return CominaviAPIClientFactory.makeClient(
            serverURL: baseURL,
            transport: { request in
                var request = request
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 30
                if let exactRequestBody {
                    request.httpBody = exactRequestBody
                }
                if request.httpBody == nil,
                   request.value(forHTTPHeaderField: "Content-Type") == nil,
                   ["POST", "PUT", "PATCH", "DELETE"].contains(
                       request.httpMethod?.uppercased() ?? ""
                   )
                {
                    // Astro rejects unsafe native-app requests that resemble
                    // cross-site form submissions. Preserve the handwritten
                    // client's JSON marker without inventing an empty body.
                    request.setValue(
                        "application/json",
                        forHTTPHeaderField: "Content-Type"
                    )
                }
                let result = try await requestTransport(request)
                if validatesErrorResponses,
                   let response = result.1 as? HTTPURLResponse,
                   response.statusCode != 401
                {
                    try self.validate(response, data: result.0)
                }
                return result
            },
            accessToken: { accessToken }
        )
    }

    private nonisolated func generatedDomainValue<Value: Decodable, Payload: Encodable>(
        _ type: Value.Type,
        from payload: Payload
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(payload))
        } catch {
            throw CominaviServiceError.invalidResponse
        }
    }

    private func performGeneratedOperation<Output>(
        _ operation: () async throws -> Output
    ) async throws -> Output {
        do {
            return try await operation()
        } catch let error as ClientError {
            if error.response == nil {
                throw error.underlyingError
            }
            throw CominaviServiceError.invalidResponse
        }
    }

    private nonisolated func undocumentedGeneratedServiceError(
        status: Int
    ) -> CominaviServiceError {
        .server(
            code: "undocumented_response",
            message: "The ComiNavi service returned an undocumented response.",
            status: status
        )
    }

    private func validatedFavoriteSnapshot(
        eventNumber: Int,
        revision: Int,
        favorites: [(wcID: Int, color: Int, notificationsEnabled: Bool)]
    ) throws -> CominaviFavoriteSnapshot {
        guard eventNumber > 0, revision >= 0 else {
            throw CominaviServiceError.invalidResponse
        }
        return CominaviFavoriteSnapshot(
            eventNumber: eventNumber,
            revision: revision,
            favorites: try favorites.map { favorite in
                guard favorite.wcID > 0,
                      let color = BookmarkColor(rawValue: favorite.color)
                else { throw CominaviServiceError.invalidResponse }
                return CominaviFavorite(
                    publicCircleID: favorite.wcID,
                    color: color,
                    notificationsEnabled: favorite.notificationsEnabled
                )
            }
        )
    }

    private nonisolated func generatedServiceError<Payload: Encodable>(
        _ payload: Payload,
        status: Int
    ) -> CominaviServiceError {
        guard let data = try? JSONEncoder().encode(payload),
              let response = try? JSONDecoder().decode(
                  GeneratedAPIErrorResponse.self,
                  from: data
              )
        else { return .invalidResponse }
        if status == 409,
           response.error.localizedCaseInsensitiveContains("revision_conflict")
        {
            return .revisionConflict(
                code: response.error,
                message: response.message,
                currentRevision: response.details?.currentRevision,
                currentPlan: nil
            )
        }
        if status == 422, response.error == "unknown_circle" {
            return .favoriteMutationRejected(
                code: response.error,
                message: response.message,
                invalidPublicCircleIDs: response.details?.wcIDs ?? []
            )
        }
        return .server(
            code: response.error,
            message: response.message,
            status: status
        )
    }

    private nonisolated func generatedFollowingImportError<Payload: Encodable>(
        _ payload: Payload,
        status _: Int
    ) -> FollowingImportAPIError {
        guard let data = try? JSONEncoder().encode(payload),
              let response = try? JSONDecoder().decode(
                  GeneratedAPIErrorResponse.self,
                  from: data
              )
        else { return .invalidResponse }
        return .server(
            code: response.error,
            message: response.message,
            nextAllowedAt: response.nextAllowedAt
        )
    }

    private func serviceSession(
        forceRefresh: Bool = false,
        invalidatedAccessToken: String? = nil
    ) async throws -> CominaviAuthenticationSession {
        try requireNoPendingTermination()
        guard !authenticationStorageUnavailable else {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        if forceRefresh,
           let invalidatedAccessToken,
           let session,
           session.accessToken != invalidatedAccessToken,
           session.expiresAt.timeIntervalSinceNow > 60
        {
            return session
        }
        if !forceRefresh, let session, session.expiresAt.timeIntervalSinceNow > 60 {
            return session
        }
        if let current = session {
            guard let refreshToken = current.refreshToken,
                  (current.refreshExpiresAt?.timeIntervalSinceNow ?? 1) > 0
            else {
                try await requireExplicitAuthentication()
                throw CominaviServiceError.notLoggedIn
            }
            do {
                return try await refreshSession(
                    singleFlightToken: refreshToken,
                    expectedUserID: boundPublicUserID ?? current.user?.id
                )
            } catch CominaviServiceError.server(_, _, let status) where status == 401 {
                if session?.refreshToken == refreshToken {
                    try await requireExplicitAuthentication()
                }
                throw CominaviServiceError.notLoggedIn
            }
        }
        throw CominaviServiceError.notLoggedIn
    }

    private func refreshSession(
        singleFlightToken refreshToken: String,
        expectedUserID: String?
    ) async throws -> CominaviAuthenticationSession {
        if refreshTaskToken == refreshToken, let refreshTask {
            return try await refreshTask.value
        }
        let generation = authenticationGeneration
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let payload = Operations.RefreshAuthenticationSession.Input.Body.JsonPayload(
                refreshToken: refreshToken
            )
            let output = try await self.performGeneratedOperation {
                try await self.generatedClient(
                    exactRequestBody: self.canonicalCredentialJSON(payload)
                ).refreshAuthenticationSession(.init(body: .json(payload)))
            }
            let refreshed: CominaviAuthenticationSession
            switch output {
            case .ok(let response):
                refreshed = try self.generatedDomainValue(
                    CominaviAuthenticationSession.self,
                    from: response.body.json
                )
            case .badRequest(let response):
                throw self.generatedServiceError(try response.body.json, status: 400)
            case .unauthorized(let response):
                throw self.generatedServiceError(try response.body.json, status: 401)
            case .forbidden(let response):
                throw self.generatedServiceError(try response.body.json, status: 403)
            case .notFound(let response):
                throw self.generatedServiceError(try response.body.json, status: 404)
            case .conflict(let response):
                throw self.generatedServiceError(try response.body.json, status: 409)
            case .gone(let response):
                throw self.generatedServiceError(try response.body.json, status: 410)
            case .preconditionFailed(let response):
                throw self.generatedServiceError(try response.body.json, status: 412)
            case .contentTooLarge(let response):
                throw self.generatedServiceError(try response.body.json, status: 413)
            case .unsupportedMediaType(let response):
                throw self.generatedServiceError(try response.body.json, status: 415)
            case .unprocessableContent(let response):
                throw self.generatedServiceError(try response.body.json, status: 422)
            case .preconditionRequired(let response):
                throw self.generatedServiceError(try response.body.json, status: 428)
            case .tooManyRequests(let response):
                throw self.generatedServiceError(try response.body.json, status: 429)
            case .internalServerError(let response):
                throw self.generatedServiceError(try response.body.json, status: 500)
            case .badGateway(let response):
                throw self.generatedServiceError(try response.body.json, status: 502)
            case .serviceUnavailable(let response):
                throw self.generatedServiceError(try response.body.json, status: 503)
            case .undocumented(let statusCode, _):
                throw self.undocumentedGeneratedServiceError(status: statusCode)
            }
            guard expectedUserID == nil || refreshed.user?.id == expectedUserID else {
                throw CominaviServiceError.invalidResponse
            }
            try await self.persist(
                refreshed,
                expectedAuthenticationGeneration: generation
            )
            return refreshed
        }
        refreshTaskToken = refreshToken
        refreshTask = task
        do {
            let refreshed = try await task.value
            if refreshTaskToken == refreshToken {
                refreshTaskToken = nil
                refreshTask = nil
            }
            return refreshed
        } catch {
            if refreshTaskToken == refreshToken {
                refreshTaskToken = nil
                refreshTask = nil
            }
            throw error
        }
    }

    private func validatedProductionAuthentication(
        _ authentication: CominaviAuthenticationSession,
        now: Date = Date()
    ) throws -> CominaviAuthenticationSession {
        guard authentication.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              !authentication.accessToken.isEmpty,
              authentication.authVersion > 0,
              authentication.expiresAt > now,
              let refreshToken = authentication.refreshToken,
              !refreshToken.isEmpty,
              let refreshExpiresAt = authentication.refreshExpiresAt,
              refreshExpiresAt > authentication.expiresAt,
              let profile = authentication.user,
              !profile.id.isEmpty,
              !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CominaviServiceError.invalidResponse }
        return authentication
    }

    private func validatedCredentialReceipt(
        _ receipt: CirclemsCredentialReceipt,
        flow: CirclemsAuthorizationFlow,
        profile: CominaviUserProfile?
    ) throws -> CirclemsCredentialReceipt {
        guard receipt.requestID == flow.requestID,
              receipt.clientInstanceID == flow.clientInstanceID,
              receipt.provider == "circlems",
              receipt.environment == flow.environment.apiValue,
              receipt.credentialRevision > 0,
              let profile,
              flow.expectedPublicUserID == nil || profile.id == flow.expectedPublicUserID,
              profile.identities.contains(where: {
                  $0.provider == "circlems"
                      && $0.environment == receipt.environment
                      && $0.providerUserID == receipt.subject
              })
        else { throw CominaviServiceError.invalidResponse }
        return receipt
    }

    /// Provider-credential requests are payload-bound and retried verbatim.
    /// Sorting keys avoids Foundation's otherwise unspecified dictionary-key
    /// order from changing the exact bytes after a crash or response loss.
    private nonisolated func canonicalCredentialJSON<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func persist(
        _ incomingAuthentication: CominaviAuthenticationSession,
        expectedAuthenticationGeneration: UInt64,
        allowingIdentityTransition: Bool = false,
        preservingCirclemsAuthorizationCompletion: Bool = true,
        preservingGoogleAuthenticationCompletion: Bool = true,
        preservingAppleAuthenticationCompletion: Bool = true
    ) async throws {
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(expectedAuthenticationGeneration)
        var authentication = incomingAuthentication
        if preservingCirclemsAuthorizationCompletion,
           incomingAuthentication.circlemsAuthorizationCompletion == nil,
           let existingMarker = session?.circlemsAuthorizationCompletion
        {
            authentication = CominaviAuthenticationSession(
                tokenType: incomingAuthentication.tokenType,
                accessToken: incomingAuthentication.accessToken,
                expiresAt: incomingAuthentication.expiresAt,
                authVersion: incomingAuthentication.authVersion,
                refreshToken: incomingAuthentication.refreshToken,
                refreshExpiresAt: incomingAuthentication.refreshExpiresAt,
                user: incomingAuthentication.user,
                circlemsAuthorizationCompletion: existingMarker,
                googleAuthenticationCompletion:
                    incomingAuthentication.googleAuthenticationCompletion
            )
        }
        if preservingGoogleAuthenticationCompletion,
           authentication.googleAuthenticationCompletion == nil,
           let existingMarker = session?.googleAuthenticationCompletion
        {
            authentication = CominaviAuthenticationSession(
                tokenType: authentication.tokenType,
                accessToken: authentication.accessToken,
                expiresAt: authentication.expiresAt,
                authVersion: authentication.authVersion,
                refreshToken: authentication.refreshToken,
                refreshExpiresAt: authentication.refreshExpiresAt,
                user: authentication.user,
                circlemsAuthorizationCompletion: authentication.circlemsAuthorizationCompletion,
                googleAuthenticationCompletion: existingMarker
            )
        }
        if preservingAppleAuthenticationCompletion,
           authentication.appleAuthenticationCompletion == nil,
           let existingMarker = session?.appleAuthenticationCompletion
        {
            authentication = CominaviAuthenticationSession(
                tokenType: authentication.tokenType,
                accessToken: authentication.accessToken,
                expiresAt: authentication.expiresAt,
                authVersion: authentication.authVersion,
                refreshToken: authentication.refreshToken,
                refreshExpiresAt: authentication.refreshExpiresAt,
                user: authentication.user,
                circlemsAuthorizationCompletion: authentication.circlemsAuthorizationCompletion,
                googleAuthenticationCompletion: authentication.googleAuthenticationCompletion,
                appleAuthenticationCompletion: existingMarker
            )
        }
        let incomingUserID = authentication.user?.id
        if let boundPublicUserID,
           let incomingUserID,
           boundPublicUserID != incomingUserID,
           !allowingIdentityTransition
        {
            throw CominaviServiceError.invalidResponse
        }
        if allowingIdentityTransition, boundPublicUserID != nil, incomingUserID == nil {
            throw CominaviServiceError.invalidResponse
        }
        let resultingBinding = incomingUserID ?? boundPublicUserID
        guard authentication.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              !authentication.accessToken.isEmpty
        else { throw CominaviServiceError.invalidResponse }

        // Keychain has no multi-item transaction. A durable marker is written
        // first and cleared last, so every crash or partial write is interpreted
        // as "reauthentication required" instead of selecting either account.
        guard sessionStore.saveReauthenticationTombstone(true),
              sessionStore.saveBoundUserID(resultingBinding),
              sessionStore.save(authentication),
              sessionStore.saveLogoutTombstone(false),
              sessionStore.saveReauthenticationTombstone(false)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        session = authentication
        boundPublicUserID = resultingBinding
        authenticationStorageUnavailable = false
        requiresExplicitAuthentication = false
    }

    private func persist(
        profile: CominaviUserProfile,
        circlemsAuthorizationCompletion: CirclemsAuthorizationCompletionMarker? = nil,
        expectedAuthenticationGeneration: UInt64
    ) async throws {
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(expectedAuthenticationGeneration)
        guard let current = session else { throw CominaviServiceError.notLoggedIn }
        if let boundPublicUserID, boundPublicUserID != profile.id {
            throw CominaviServiceError.invalidResponse
        }
        if let authenticatedUserID = current.user?.id, authenticatedUserID != profile.id {
            throw CominaviServiceError.invalidResponse
        }
        let updated = CominaviAuthenticationSession(
            tokenType: current.tokenType,
            accessToken: current.accessToken,
            expiresAt: current.expiresAt,
            authVersion: current.authVersion,
            refreshToken: current.refreshToken,
            refreshExpiresAt: current.refreshExpiresAt,
            user: profile,
            circlemsAuthorizationCompletion:
                circlemsAuthorizationCompletion ?? current.circlemsAuthorizationCompletion,
            googleAuthenticationCompletion: current.googleAuthenticationCompletion,
            appleAuthenticationCompletion: current.appleAuthenticationCompletion
        )
        guard sessionStore.saveReauthenticationTombstone(true),
              sessionStore.saveBoundUserID(profile.id),
              sessionStore.save(updated),
              sessionStore.saveReauthenticationTombstone(false)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        boundPublicUserID = profile.id
        session = updated
    }

    @discardableResult
    private func invalidateRuntimeAuthentication() -> UInt64 {
        authenticationGeneration += 1
        session = nil
        requiresExplicitAuthentication = true
        avatarDataCache.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        return authenticationGeneration
    }

    private func requireAuthenticationGeneration(_ expected: UInt64) throws {
        guard authenticationGeneration == expected else {
            if accountDeletionIsPending {
                throw CominaviServiceError.accountDeletionPending
            }
            if pendingLogout != nil {
                throw CominaviServiceError.logoutPending
            }
            throw CominaviServiceError.notLoggedIn
        }
    }

    private func requireNoPendingTermination() throws {
        if accountDeletionIsPending {
            throw CominaviServiceError.accountDeletionPending
        }
        if pendingLogout != nil {
            throw CominaviServiceError.logoutPending
        }
    }

    private var accountDeletionIsPending: Bool {
        pendingAccountDeletion != nil || pendingAccountDeletionCleanup != nil
    }

    private func providerFlowLease(
        provider: CominaviProviderFlowPublicationLease.Provider,
        requestID: UUID,
        generation: UInt64
    ) -> CominaviProviderFlowPublicationLease {
        CominaviProviderFlowPublicationLease(
            provider: provider,
            requestID: requestID,
            authenticationGeneration: generation
        )
    }

    private func requireProviderFlowLease(
        _ lease: CominaviProviderFlowPublicationLease,
        provider: CominaviProviderFlowPublicationLease.Provider,
        requestID: UUID
    ) throws {
        try requireNoPendingTermination()
        try requireAuthenticationGeneration(lease.authenticationGeneration)
        guard lease.provider == provider, lease.requestID == requestID else {
            throw CominaviServiceError.invalidResponse
        }
    }

    private func beginExplicitIdentityTransition() async throws -> UInt64 {
        try requireNoPendingTermination()
        let generation = invalidateRuntimeAuthentication()
        await authenticationInvalidationHandler(nil)
        try requireAuthenticationGeneration(generation)
        guard sessionStore.saveReauthenticationTombstone(true) else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        authenticationStorageUnavailable = false
        return generation
    }

    private func requireExplicitAuthentication() async throws {
        // Definitive credential invalidation revokes local editing first. A
        // Keychain failure must never be misclassified as transient/offline.
        invalidateRuntimeAuthentication()
        await authenticationInvalidationHandler(.notLoggedIn)
        let marked = sessionStore.saveReauthenticationTombstone(true)
        let removedSession = sessionStore.save(nil)
        guard marked, removedSession else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
    }

    private func failClosedAfterCredentialStorageFailure() async {
        invalidateRuntimeAuthentication()
        authenticationStorageUnavailable = true
        // A second protected marker gives relaunch a fail-closed signal if the
        // preferred reauthentication marker was the individual write that
        // failed. Existing account data remains inaccessible until explicit auth.
        if !sessionStore.saveReauthenticationTombstone(true), pendingLogout == nil {
            _ = sessionStore.saveLogoutTombstone(true)
        }
        await authenticationInvalidationHandler(.authenticationStorageUnavailable)
    }

    private func applyPendingLogoutLocally() async {
        invalidateRuntimeAuthentication()
        requiresExplicitAuthentication = true
        await authenticationInvalidationHandler(nil)
        _ = sessionStore.saveReauthenticationTombstone(false)
        // The durable logout transaction itself is the fail-closed tombstone,
        // so a failed session deletion cannot restore authority on relaunch.
        _ = sessionStore.save(nil)
        try? await authenticationFlowCanceller()
    }

    private func applyPendingAccountDeletionLocally() async {
        invalidateRuntimeAuthentication()
        requiresExplicitAuthentication = true
        await authenticationInvalidationHandler(.accountDeletionPending)
        _ = sessionStore.saveReauthenticationTombstone(false)
        // The protected deletion transaction is the fail-closed authority
        // marker. Keep the public-user binding for exact cache cleanup after
        // the 202 receipt, but remove all live service and provider authority.
        _ = sessionStore.save(nil)
        try? await authenticationFlowCanceller()
    }

    private func submitPendingLogout() async throws {
        guard let transaction = pendingLogout,
              transaction.isValid,
              let requestID = transaction.requestID
        else { throw CominaviServiceError.invalidResponse }
        let output = try await performGeneratedOperation {
            try await generatedClient(
                accessToken: transaction.predecessorAccessToken,
                exactRequestBody: transaction.payload
            ).logoutAuthenticationSession(.init(
                body: .json(.init(
                    requestId: requestID.uuidString.lowercased(),
                    refreshToken: transaction.predecessorRefreshToken
                ))
            ))
        }
        let receipt: Operations.LogoutAuthenticationSession.Output.Ok.Body.JsonPayload
            .ReceiptPayload
        switch output {
        case .ok(let response):
            receipt = try response.body.json.receipt
        case .badRequest(let response):
            throw generatedServiceError(try response.body.json, status: 400)
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        case .forbidden(let response):
            throw generatedServiceError(try response.body.json, status: 403)
        case .notFound(let response):
            throw generatedServiceError(try response.body.json, status: 404)
        case .conflict(let response):
            throw generatedServiceError(try response.body.json, status: 409)
        case .gone(let response):
            throw generatedServiceError(try response.body.json, status: 410)
        case .preconditionFailed(let response):
            throw generatedServiceError(try response.body.json, status: 412)
        case .contentTooLarge(let response):
            throw generatedServiceError(try response.body.json, status: 413)
        case .unsupportedMediaType(let response):
            throw generatedServiceError(try response.body.json, status: 415)
        case .unprocessableContent(let response):
            throw generatedServiceError(try response.body.json, status: 422)
        case .preconditionRequired(let response):
            throw generatedServiceError(try response.body.json, status: 428)
        case .tooManyRequests(let response):
            throw generatedServiceError(try response.body.json, status: 429)
        case .internalServerError(let response):
            throw generatedServiceError(try response.body.json, status: 500)
        case .badGateway(let response):
            throw generatedServiceError(try response.body.json, status: 502)
        case .serviceUnavailable(let response):
            throw generatedServiceError(try response.body.json, status: 503)
        case .undocumented(let statusCode, _):
            throw undocumentedGeneratedServiceError(status: statusCode)
        }
        guard let receiptRequestID = UUID(uuidString: receipt.requestId),
              receipt.requestId == receiptRequestID.uuidString.lowercased(),
              receiptRequestID == requestID,
              receipt.authVersion == transaction.authVersion + 1
        else { throw CominaviServiceError.invalidResponse }

        // A server acknowledgement is not enough to clear the tombstone if a
        // protected provider flow could not yet be deleted. Replaying the same
        // command is safe and lets cleanup resume without restoring a session.
        do {
            try await authenticationFlowCanceller()
        } catch {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        guard sessionStore.save(nil),
              sessionStore.saveBoundUserID(nil),
              sessionStore.saveReauthenticationTombstone(false),
              sessionStore.savePendingLogout(nil)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingLogout = nil
        boundPublicUserID = nil
        authenticationStorageUnavailable = false
        requiresExplicitAuthentication = true
    }

    private func submitPendingAccountDeletion() async throws
        -> CominaviAccountDeletionResult
    {
        guard let transaction = pendingAccountDeletion,
              transaction.isValid,
              let requestID = transaction.requestID
        else { throw CominaviServiceError.invalidResponse }
        let payload: Operations.DeleteCurrentUserAccount.Input.Body.JsonPayload
        do {
            payload = try JSONDecoder().decode(
                Operations.DeleteCurrentUserAccount.Input.Body.JsonPayload.self,
                from: transaction.payload
            )
        } catch {
            throw CominaviServiceError.invalidResponse
        }
        let output = try await performGeneratedOperation {
            try await generatedClient(
                accessToken: transaction.predecessorAccessToken,
                exactRequestBody: transaction.payload,
                validatesErrorResponses: true
            ).deleteCurrentUserAccount(.init(body: .json(payload)))
        }
        let result: CominaviAccountDeletionResult
        switch output {
        case .accepted(let response):
            result = try generatedDomainValue(
                CominaviAccountDeletionResult.self,
                from: response.body.json
            )
        case .unauthorized(let response):
            throw generatedServiceError(try response.body.json, status: 401)
        default:
            throw CominaviServiceError.invalidResponse
        }
        guard result.status == "deletion_pending",
              result.requestId == requestID.uuidString.lowercased(),
              result.deletedOwnedPlanIDs.allSatisfy({ value in
                  guard let id = UUID(uuidString: value) else { return false }
                  return value == id.uuidString.lowercased()
              })
        else { throw CominaviServiceError.invalidResponse }

        let cleanupReceipt = CominaviAccountDeletionCleanupReceipt(
            requestID: requestID,
            publicUserID: transaction.publicUserID,
            deletedOwnedPlanIDs: result.deletedOwnedPlanIDs
        )
        guard cleanupReceipt.isValid,
              sessionStore.savePendingAccountDeletionCleanup(cleanupReceipt)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingAccountDeletionCleanup = cleanupReceipt

        do {
            try await authenticationFlowCanceller()
        } catch {
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        // Clear account-scoped authority only after the immutable cleanup
        // receipt is durable. The receipt itself remains the final fail-closed
        // marker and public-user pointer until filesystem cleanup succeeds.
        guard sessionStore.save(nil),
              sessionStore.saveLogoutTombstone(true),
              sessionStore.saveReauthenticationTombstone(false),
              sessionStore.savePendingAccountDeletion(nil),
              sessionStore.saveBoundUserID(nil)
        else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        pendingAccountDeletion = nil
        boundPublicUserID = nil
        authenticationStorageUnavailable = false
        requiresExplicitAuthentication = true
        return result
    }

    private func clearAuthenticationState() async throws {
        if accountDeletionIsPending {
            await applyPendingAccountDeletionLocally()
            return
        }
        if pendingLogout != nil {
            await applyPendingLogoutLocally()
            return
        }
        // The rendered account and every retained user-scoped store lose edit
        // authority before any fallible Keychain operation.
        invalidateRuntimeAuthentication()
        await authenticationInvalidationHandler(nil)
        guard sessionStore.saveLogoutTombstone(true) else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        _ = sessionStore.saveReauthenticationTombstone(false)
        let removedSession = sessionStore.save(nil)
        let removedBinding = sessionStore.saveBoundUserID(nil)
        requiresExplicitAuthentication = true
        guard removedSession, removedBinding else {
            await failClosedAfterCredentialStorageFailure()
            throw CominaviServiceError.authenticationStorageUnavailable
        }
        boundPublicUserID = nil
    }

    private func authenticatedAvatarPath(for avatarURL: URL) throws -> (String, String) {
        let path: String
        if avatarURL.scheme == nil, avatarURL.host == nil {
            path = avatarURL.relativeString
        } else {
            guard avatarURL.scheme?.lowercased() == baseURL.scheme?.lowercased(),
                  avatarURL.host?.lowercased() == baseURL.host?.lowercased(),
                  avatarURL.port == baseURL.port,
                  avatarURL.query == nil,
                  avatarURL.fragment == nil
            else { throw CominaviServiceError.invalidResponse }
            path = avatarURL.path
        }
        guard path.range(
            of: "^/api/v2/users/[A-Za-z0-9_-]+/avatar$",
            options: .regularExpression
        ) != nil else { throw CominaviServiceError.invalidResponse }
        let components = path.split(separator: "/")
        guard components.count == 5 else {
            throw CominaviServiceError.invalidResponse
        }
        return (path, String(components[3]))
    }

    private nonisolated func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let error = try? decoder.decode(APIErrorResponse.self, from: data) {
                if response.statusCode == 403,
                   error.error == "plan_owner_required"
                {
                    throw CominaviServiceError.planOwnerRequired(
                        code: error.error,
                        message: error.message
                    )
                }
                if response.statusCode == 409,
                   error.error.localizedCaseInsensitiveContains("revision_conflict")
                {
                    throw CominaviServiceError.revisionConflict(
                        code: error.error,
                        message: error.message,
                        currentRevision: error.details?.currentRevision,
                        currentPlan: error.details?.currentPlan?.domain
                    )
                }
                if response.statusCode == 409,
                   error.error == "invitation_token_already_returned",
                   let invitationID = error.details?.invitationID,
                   Self.isCanonicalUUIDString(invitationID)
                {
                    throw CominaviServiceError.invitationTokenAlreadyReturned(
                        message: error.message,
                        invitationID: invitationID
                    )
                }
                if response.statusCode == 422, error.error == "unknown_circle" {
                    throw CominaviServiceError.favoriteMutationRejected(
                        code: error.error,
                        message: error.message,
                        invalidPublicCircleIDs: error.details?.wcIDs ?? []
                    )
                }
                throw CominaviServiceError.server(
                    code: error.error,
                    message: error.message,
                    status: response.statusCode
                )
            }
            throw CominaviServiceError.invalidResponse
        }
    }

    private static var installationID: String {
        let key = "cominavi.service.installation-id.\(AppEnvironment.current.storageNamespace)"
        if let stored = UserDefaults.standard.string(forKey: key),
           UUID(uuidString: stored) != nil
        {
            return stored.lowercased()
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static var apnsEnvironment: String {
        #if DEBUG || COMINAVI_STAGING
        "sandbox"
        #else
        "production"
        #endif
    }
}
