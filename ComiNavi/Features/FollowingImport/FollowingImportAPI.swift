import Foundation

struct FollowingAccount: Codable, Equatable, Hashable, Sendable {
  let id: String
  let userName: String
  let name: String
  let url: URL
  let profilePicture: URL?
}

struct FollowingImportPayload: Codable, Equatable, Sendable {
  enum Source: String, Codable, Sendable {
    case twitterAPI = "twitterapi.io"
    case cache
  }

  let twitterUserName: String
  let importedAt: Date
  let nextAllowedAt: Date
  let followings: [FollowingAccount]
  let source: Source
}

enum FollowingImportAPIError: LocalizedError {
  case notLoggedIn
  case invalidResponse
  case server(code: String, message: String, nextAllowedAt: Date?)

  var errorDescription: String? {
    switch self {
    case .notLoggedIn:
      String(localized: "Log in to Circle.ms before importing X followings.")
    case .invalidResponse:
      String(localized: "The import service returned an invalid response.")
    case .server(_, let message, _):
      message
    }
  }
}

struct FollowingImportAPIClient: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private struct AuthenticationResponse: Decodable {
    let accessToken: String
  }

  private struct APIErrorResponse: Decodable {
    let error: String
    let message: String
    let nextAllowedAt: Date?
  }

  private let baseURL: URL
  private let transport: Transport

  init(
    baseURL: URL = URL(string: "https://cominavi.net")!,
    transport: @escaping Transport = { request in
      try await URLSession.shared.data(for: request)
    }
  ) {
    self.baseURL = baseURL
    self.transport = transport
  }

  func importFollowings(
    twitterUserName: String,
    circlemsAccessToken: String,
    circlemsEnvironment: CirclemsServiceEnvironment
  ) async throws -> FollowingImportPayload {
    guard !circlemsAccessToken.isEmpty else {
      throw FollowingImportAPIError.notLoggedIn
    }

    let authentication = try await send(
      path: "/api/v1/auth/circlems",
      bearerToken: circlemsAccessToken,
      body: [
        "environment": circlemsEnvironment == .production
          ? "production"
          : "sandbox"
      ],
      as: AuthenticationResponse.self
    )
    return try await send(
      path: "/api/v1/imports/x-followings",
      bearerToken: authentication.accessToken,
      body: ["userName": twitterUserName],
      as: FollowingImportPayload.self
    )
  }

  private func send<Response: Decodable>(
    path: String,
    bearerToken: String,
    body: [String: String],
    as type: Response.Type
  ) async throws -> Response {
    let url = baseURL.appending(path: path)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    // Large accounts can require several server-side TwitterAPI.io pages.
    request.timeoutInterval = 180
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await transport(request)
    guard let response = response as? HTTPURLResponse else {
      throw FollowingImportAPIError.invalidResponse
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard (200..<300).contains(response.statusCode) else {
      if let error = try? decoder.decode(APIErrorResponse.self, from: data) {
        throw FollowingImportAPIError.server(
          code: error.error,
          message: error.message,
          nextAllowedAt: error.nextAllowedAt
        )
      }
      throw FollowingImportAPIError.invalidResponse
    }
    guard let decoded = try? decoder.decode(Response.self, from: data) else {
      throw FollowingImportAPIError.invalidResponse
    }
    return decoded
  }
}
