import Foundation

enum CominaviServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case server(code: String, message: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            String(localized: "Log in to Circle.ms to use live updates.")
        case .invalidResponse:
            String(localized: "The ComiNavi service returned an invalid response.")
        case .server(_, let message, _):
            message
        }
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
    func synchronizeFavorites(eventNumber: Int, bookmarks: [MapBookmark]) async throws
}

protocol CominaviRealtimeFetching: Sendable {
    func realtimeUpdates(
        eventNumber: Int,
        after cursor: Int,
        limit: Int
    ) async throws -> (updates: [CominaviRealtimeUpdate], nextCursor: Int, hasMore: Bool)
}

actor CominaviServiceClient: CominaviFavoriteSyncing, CominaviRealtimeFetching {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias CirclemsTokenProvider = @Sendable () async -> String
    typealias CirclemsEnvironmentProvider = @Sendable () -> CirclemsServiceEnvironment

    static let shared = CominaviServiceClient()

    private struct AuthenticationResponse: Decodable {
        let accessToken: String
        let expiresAt: Date
    }

    private struct ServiceSession: Sendable {
        let accessToken: String
        let expiresAt: Date
        let circlemsEnvironment: CirclemsServiceEnvironment
    }

    private struct APIErrorResponse: Decodable {
        let error: String
        let message: String
    }

    private struct Favorite: Codable {
        let wcID: Int
        let color: Int
        let notificationsEnabled: Bool
    }

    private struct FavoriteSnapshot: Codable {
        let eventNumber: Int
        let revision: Int
        let favorites: [Favorite]
    }

    private struct FavoriteMutation: Encodable {
        let baseRevision: Int
        let mutationID: String
        let favorites: [Favorite]
    }

    private struct DeviceRegistration: Encodable {
        let token: String
        let apnsEnvironment: String
        let bundleID: String
        let locale: String
        let timeZone: String
        let enabled: Bool
    }

    private struct RealtimePage: Decodable {
        let eventNumber: Int
        let updates: [CominaviRealtimeUpdate]
        let nextCursor: Int
        let hasMore: Bool
    }

    private let baseURL: URL
    private let transport: Transport
    private let circlemsTokenProvider: CirclemsTokenProvider
    private let circlemsEnvironmentProvider: CirclemsEnvironmentProvider
    private var session: ServiceSession?

    init(
        baseURL: URL = URL(string: "https://cominavi.net")!,
        transport: @escaping Transport = { request in
            try await URLSession.shared.data(for: request)
        },
        circlemsTokenProvider: @escaping CirclemsTokenProvider = {
            await AppData.getUserToken()
        },
        circlemsEnvironmentProvider: @escaping CirclemsEnvironmentProvider = {
            AppEnvironment.current.circlems
        }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.circlemsTokenProvider = circlemsTokenProvider
        self.circlemsEnvironmentProvider = circlemsEnvironmentProvider
    }

    func synchronizeFavorites(
        eventNumber: Int,
        bookmarks: [MapBookmark]
    ) async throws {
        let snapshot: FavoriteSnapshot = try await authorizedRequest(
            method: "GET",
            path: "/api/v1/me/favorites/\(eventNumber)"
        )
        let favorites = bookmarks
            .filter { $0.eventNumber == eventNumber && $0.syncState != .pendingDelete }
            .map {
                Favorite(
                    wcID: $0.publicCircleID,
                    color: $0.color.rawValue,
                    notificationsEnabled: true
                )
            }
            .sorted { $0.wcID < $1.wcID }
        let mutation = FavoriteMutation(
            baseRevision: snapshot.revision,
            mutationID: UUID().uuidString.lowercased(),
            favorites: favorites
        )
        let _: FavoriteSnapshot = try await authorizedRequest(
            method: "PUT",
            path: "/api/v1/me/favorites/\(eventNumber)",
            body: try JSONEncoder().encode(mutation)
        )
    }

    func registerPushToken(_ token: Data) async throws {
        guard !token.isEmpty, let bundleID = Bundle.main.bundleIdentifier else {
            throw CominaviServiceError.invalidResponse
        }
        let registration = DeviceRegistration(
            token: token.map { String(format: "%02x", $0) }.joined(),
            apnsEnvironment: Self.apnsEnvironment,
            bundleID: bundleID,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            enabled: true
        )
        let _: DeviceRegistrationResponse = try await authorizedRequest(
            method: "PUT",
            path: "/api/v1/me/devices/\(Self.installationID)",
            body: try JSONEncoder().encode(registration)
        )
    }

    func disablePushDevice() async throws {
        try await authorizedVoidRequest(
            method: "DELETE",
            path: "/api/v1/me/devices/\(Self.installationID)"
        )
    }

    func revokeSession() async throws {
        defer {
            session = nil
        }
        try await authorizedVoidRequest(
            method: "POST",
            path: "/api/v1/auth/logout"
        )
    }

    func realtimeUpdates(
        eventNumber: Int,
        after cursor: Int,
        limit: Int = 500
    ) async throws -> (updates: [CominaviRealtimeUpdate], nextCursor: Int, hasMore: Bool) {
        let page: RealtimePage = try await authorizedRequest(
            method: "GET",
            path: "/api/v1/events/\(eventNumber)/updates?after=\(cursor)&limit=\(limit)"
        )
        guard page.eventNumber == eventNumber else {
            throw CominaviServiceError.invalidResponse
        }
        return (page.updates, page.nextCursor, page.hasMore)
    }

    func invalidateSession() {
        session = nil
    }

    private struct DeviceRegistrationResponse: Decodable {
        let installationID: String
        let enabled: Bool
    }

    private func authorizedRequest<Response: Decodable>(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> Response {
        let (data, response) = try await sendAuthorized(method: method, path: path, body: body)
        return try decode(Response.self, data: data, response: response)
    }

    private func authorizedVoidRequest(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws {
        let (data, response) = try await sendAuthorized(method: method, path: path, body: body)
        guard let http = response as? HTTPURLResponse else {
            throw CominaviServiceError.invalidResponse
        }
        try validate(http, data: data)
    }

    private func sendAuthorized(
        method: String,
        path: String,
        body: Data?
    ) async throws -> (Data, URLResponse) {
        var currentSession = try await serviceSession()
        var result = try await send(
            method: method,
            path: path,
            bearerToken: currentSession.accessToken,
            body: body
        )
        if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            session = nil
            currentSession = try await serviceSession()
            result = try await send(
                method: method,
                path: path,
                bearerToken: currentSession.accessToken,
                body: body
            )
        }
        return result
    }

    private func serviceSession() async throws -> ServiceSession {
        let environment = circlemsEnvironmentProvider()
        if let session,
           session.circlemsEnvironment == environment,
           session.expiresAt.timeIntervalSinceNow > 60
        {
            return session
        }
        let circlemsToken = await circlemsTokenProvider()
        guard !circlemsToken.isEmpty else {
            throw CominaviServiceError.notLoggedIn
        }
        let body = try JSONEncoder().encode([
            "environment": environment == .production ? "production" : "sandbox"
        ])
        let result = try await send(
            method: "POST",
            path: "/api/v1/auth/circlems",
            bearerToken: circlemsToken,
            body: body
        )
        let authentication = try decode(
            AuthenticationResponse.self,
            data: result.0,
            response: result.1
        )
        let session = ServiceSession(
            accessToken: authentication.accessToken,
            expiresAt: authentication.expiresAt,
            circlemsEnvironment: environment
        )
        self.session = session
        return session
    }

    private func send(
        method: String,
        path: String,
        bearerToken: String,
        body: Data?
    ) async throws -> (Data, URLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CominaviServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await transport(request)
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        data: Data,
        response: URLResponse
    ) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw CominaviServiceError.invalidResponse
        }
        try validate(http, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CominaviServiceError.invalidResponse
        }
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
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
