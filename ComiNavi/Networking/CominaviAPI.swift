//
//  CominaviAPI.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/10/24.
//

import Alamofire
import Foundation

enum CominaviAPI {
    private static let decoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    struct OAuthCirclesRefreshTokenResponse: Codable {
        var status: String
        var tokenType: String
        var accessToken: String
        var expiresIn: String
        var refreshToken: String
    }

    static func oauthCirclemsRefreshToken(refreshToken: String) async throws -> OAuthCirclesRefreshTokenResponse {
        let url = URL(string: "https://cominavi.net/api/v1/oauth/circlems/refresh_token")!
        let parameters = ["refresh_token": refreshToken]
        let headers: HTTPHeaders = [
            "Content-Type": "application/json"
        ]

        return try await AF.request(url, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers)
            .validate()
            .serializingDecodable(OAuthCirclesRefreshTokenResponse.self, decoder: decoder)
            .value
    }
}
