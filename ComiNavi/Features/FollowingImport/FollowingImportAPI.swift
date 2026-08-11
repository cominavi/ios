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
      String(localized: "Log in to ComiNavi before importing X followings.")
    case .invalidResponse:
      String(localized: "The import service returned an invalid response.")
    case .server(_, let message, _):
      message
    }
  }
}

protocol FollowingImportServicing: Sendable {
  func importXFollowings(userName: String) async throws -> FollowingImportPayload
}

extension CominaviServiceClient: FollowingImportServicing {}

struct FollowingImportAPIClient: Sendable {
  private let service: any FollowingImportServicing

  init(service: any FollowingImportServicing = CominaviServiceClient.shared) {
    self.service = service
  }

  func importFollowings(twitterUserName: String) async throws -> FollowingImportPayload {
    try await service.importXFollowings(userName: twitterUserName)
  }
}
