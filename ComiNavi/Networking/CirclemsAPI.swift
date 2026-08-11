//
//  CirclemsAPI.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Alamofire
import Foundation

private extension KeyedDecodingContainer {
    func decodeFlexibleInteger(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }

        let value = try decode(String.self, forKey: key)
        guard let integer = Int(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected an integer or a decimal integer string."
            )
        }
        return integer
    }
}

extension DataRequest {
    func debugValidate() -> Self {
        return self
            .validate()
//            .cURLDescription(calling: { print("[REQ]\n\n", $0) })
//            .validate { _, response, data in
//                print("[RESP HEAD]\n\n", response.statusCode, response.headers)
//                print("[RESP DATA]\n\n", String(data: data!, encoding: .utf8)!)
//                return .success(())
//            }
    }
}

enum CirclemsAPIAuthorizationError: LocalizedError, Equatable {
    case accessTokenRequired

    var errorDescription: String? {
        switch self {
        case .accessTokenRequired:
            String(localized: "Circle.ms authorization is required for the direct catalog source.")
        }
    }
}

enum CirclemsAPI {
    public static var baseURL: String {
        AppEnvironment.current.circlems.apiBaseURL.absoluteString
    }

    public static var authBaseURL: String {
        AppEnvironment.current.circlems.authenticationBaseURL.absoluteString
    }
    
    private struct APIError: Error, Decodable, Sendable {
        let message: String
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    
    static func authenticatedHeaders(accessToken: String) throws -> HTTPHeaders {
        let accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw CirclemsAPIAuthorizationError.accessTokenRequired
        }
        return ["Authorization": "Bearer \(accessToken)"]
    }

    private static func headers() async throws -> HTTPHeaders {
        try authenticatedHeaders(accessToken: await AppData.getUserToken())
    }
    
    // MARK: - Response Types
    
    struct Response<T: Decodable & Sendable>: Decodable, Sendable {
        let response: T
        let status: String
    }

    typealias EventListResponse = Response<EventListResponseData>
    
    struct EventListResponseData: Decodable, Sendable {
        struct Event: Decodable, Sendable {
            let eventID: Int
            let eventNumber: Int

            private enum CodingKeys: String, CodingKey {
                case eventID = "EventId"
                case eventNumber = "EventNo"
            }
        }

        let list: [Event]
        let latestEventID: Int
        let latestEventNumber: Int

        private enum CodingKeys: String, CodingKey {
            case list
            case latestEventID = "LatestEventId"
            case latestEventNumber = "LatestEventNo"
        }
    }
    
    typealias CatalogBaseResponse = Response<CatalogBaseResponseData>

    struct CatalogBaseResponseData: Decodable, Sendable {
        struct DBKeys: Decodable, Sendable {
            let textdbSqlite3UrlSsl: String
            let imagedb1UrlSsl: String
        }
        
        let url: DBKeys
        let md5: DBKeys
        let updatedate: String
    }
    
    typealias FavoriteCirclesResponse = Response<FavoriteCirclesResponseData>

    struct FavoriteCirclesResponseData: Decodable, Sendable {
        let list: [FavoriteCircle]
    }

    struct FavoriteCircle: Decodable, Sendable {
        let circle: FavoriteCircleSummary
        let favorite: FavoriteInfoResponseData
    }

    struct FavoriteCircleSummary: Decodable, Sendable {
        let wcid: Int
        let updateId: Int

        private enum CodingKeys: String, CodingKey {
            case wcid
            case updateId
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wcid = try container.decodeFlexibleInteger(forKey: .wcid)
            updateId = try container.decodeFlexibleInteger(forKey: .updateId)
        }
    }
    
    typealias CircleResponse = Response<CircleResponseData>

    struct CircleResponseData: Decodable, Sendable {
        /// 公開サークルId
        let wcid: Int
        /// サークル名
        let name: String
        /// サークル名カタカナ
        let nameKana: String
        /// Circle.msサークルId
        let circlemsId: Int
        /// サークルカット画像URL
        let cutUrl: String
        /// 申込時サークルカット画像URL
        let cutBaseUrl: String
        /// Web用サークルカット画像URL
        let cutWebUrl: String
        /// JST形式のWebサークルカット画像の最終更新日
        let cutWebUpdatedate: String
        /// ジャンルコード
        let genre: Int
        /// サークルURL
        let url: String
        /// PixivURL
        let pixivUrl: String
        /// TwitterURL
        let twitterUrl: String
        /// CLIP STUDIO PROFILE Url
        let clipstudioUrl: String
        /// ニコニコUrl
        let niconicoUrl: String
        /// サークルに関連するタグ(カンマ区切り)
        let tag: String
        /// 補足説明、サークルアピール
        let description: String
        /// 書店名、書店リンク先の一覧情報
        let onlinestore: [OnlineStore]
        /// 初期データベースのサークルを特定するための値
        let updateId: Int
        /// JST形式の最終更新日
        let updateDate: String
        
        struct OnlineStore: Decodable, Sendable {
            let name: String
            let link: String
        }
    }
    
    typealias CircleQueryResponse = Response<CircleQueryResponseData>

    struct CircleQueryResponseData: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let updateId: Int
            let tag: String?

            private enum CodingKeys: String, CodingKey {
                case updateId
                case tag
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                updateId = try container.decodeFlexibleInteger(forKey: .updateId)
                tag = try container.decodeIfPresent(String.self, forKey: .tag)
            }
        }

        let count: Int
        let maxCount: Int
        let list: [Item]

        private enum CodingKeys: String, CodingKey {
            case count
            case maxCount = "maxcount"
            case list
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            count = try container.decodeFlexibleInteger(forKey: .count)
            maxCount = try container.decodeFlexibleInteger(forKey: .maxCount)
            list = try container.decode([Item].self, forKey: .list)
        }
    }
    
    typealias UserInfoResponse = Response<UserInfoResponseData>

    struct UserInfoResponseData: Decodable, Sendable {
        let pid: Int
        let r18: Int
        let nickname: String
    }
    
    typealias BookQueryResponse = Response<BookQueryResponseData>

    struct BookQueryResponseData: Decodable, Sendable {
        let books: [Book]
    }

    struct Book: Decodable, Sendable {
        /// 頒布物Id
        let workId: String
        /// 公開サークルId
        let wcid: Int
        /// 表示順 (0 = その他項目, 1～5 = 各頒布物項目)
        let num: Int
        /// 発行誌名
        let name: String
        /// サイズ
        let size: String
        /// ページ
        let page: Int
        /// ジャンル
        let genre: String
        /// 発行年月日
        let distDate: String
        /// 新刊 (1 = 新刊, 0 = 既刊)
        let newBook: Int
        /// 表紙画像URL
        let imageUrl: String
        /// 内容紹介
        let introduction: String
        /// JST形式の最終更新日
        let updateDate: String
        /// R18判定フラグ (0 = 全年齢, 1 = 18禁)
        let r18: Int
        /// 価格
        let price: Int?
    }
    
    typealias FavoriteInfoResponse = Response<FavoriteInfoResponseData>

    struct FavoriteInfoResponseData: Decodable, Sendable {
        /// 公開サークルId
        let wcid: Int
        /// サークル名
        let circleName: String
        /// カラー番号
        let color: Int
        /// ユーザメモ情報
        let memo: String
        /// 自由入力データ
        let free: String?
        /// お気に入り情報のJST形式の最終更新日時
        let updateDate: String
    }

    typealias FavoriteMutationResponse = Response<FavoriteMutationResponseData>

    struct FavoriteMutationResponseData: Decodable, Sendable {
        let favorite: FavoriteInfoResponseData
        let circle: FavoriteCircleSummary
    }
    
    // A placeholder for empty responses
    struct EmptyResponse: Decodable, Sendable {}

    // MARK: - Request Types

    private struct EventParameters: Encodable, Sendable {
        let eventID: Int

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
        }
    }

    private struct FavoriteListParameters: Encodable, Sendable {
        let eventID: Int
        let circleName: String?
        let page: Int
        let lastUpdate: String?

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case circleName = "circle_name"
            case page
            case lastUpdate = "lastupdate"
        }
    }

    private struct CircleParameters: Encodable, Sendable {
        let wcid: String
    }

    private struct CircleQueryParameters: Encodable, Sendable {
        let eventID: Int
        let circleName: String?
        let genre: String?
        let floor: String?
        let sort: String?
        let page: Int?
        let lastUpdate: String?

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case circleName = "circle_name"
            case genre
            case floor
            case sort
            case page
            case lastUpdate = "lastupdate"
        }
    }

    private struct FavoriteMutationParameters: Encodable, Sendable {
        let wcid: Int
        let color: Int
        let memo: String
        let free: String?
    }

    private struct FavoriteDeleteParameters: Encodable, Sendable {
        let wcid: Int
    }

    private struct BookQueryParameters: Encodable, Sendable {
        let eventID: Int
        let circleName: String?
        let workName: String?
        let workWord: String?
        let genre: String?
        let floor: String?
        let sort: String?
        let page: Int?
        let lastUpdate: String?

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case circleName = "circle_name"
            case workName = "work_name"
            case workWord = "work_word"
            case genre
            case floor
            case sort
            case page
            case lastUpdate = "lastupdate"
        }
    }

    // MARK: - API Methods
    
    static func getEventList() async throws -> EventListResponse {
        let url = "\(baseURL)/WebCatalog/GetEventList"
        return try await AF.request(url, headers: try await headers())
            .debugValidate()
            .serializingDecodable(EventListResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func getCatalogBase(eventId: Int) async throws -> CatalogBaseResponse {
        let url = "\(baseURL)/CatalogBase/All/"
        return try await AF.request(
            url,
            parameters: EventParameters(eventID: eventId),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(CatalogBaseResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func getFavoriteCircles(
        eventId: Int,
        circleName: String? = nil,
        page: Int = 1,
        lastUpdate: String? = nil
    ) async throws -> FavoriteCirclesResponse {
        let url = "\(baseURL)/Readers/FavoriteCircles"
        return try await AF.request(
            url,
            parameters: FavoriteListParameters(
                eventID: eventId,
                circleName: circleName,
                page: page,
                lastUpdate: lastUpdate
            ),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(FavoriteCirclesResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func getCircle(wcid: String) async throws -> CircleResponse {
        let url = "\(baseURL)/WebCatalog/GetCircle"
        return try await AF.request(
            url,
            parameters: CircleParameters(wcid: wcid),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(CircleResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func queryCircles(
        eventId: Int,
        circleName: String? = nil,
        genre: String? = nil,
        floor: String? = nil,
        sort: String? = nil,
        page: Int? = nil,
        lastUpdate: String? = nil
    ) async throws -> CircleQueryResponse {
        let url = "\(baseURL)/WebCatalog/QueryCircle"
        return try await AF.request(
            url,
            parameters: CircleQueryParameters(
                eventID: eventId,
                circleName: circleName,
                genre: genre,
                floor: floor,
                sort: sort,
                page: page,
                lastUpdate: lastUpdate
            ),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(CircleQueryResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func addFavorite(wcid: Int, color: Int, memo: String, free: String? = nil) async throws -> FavoriteMutationResponse {
        let url = "\(baseURL)/Readers/Favorite"
        return try await AF.request(
            url,
            method: .post,
            parameters: FavoriteMutationParameters(wcid: wcid, color: color, memo: memo, free: free),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(FavoriteMutationResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func editFavorite(wcid: Int, color: Int, memo: String, free: String? = nil) async throws -> FavoriteMutationResponse {
        let url = "\(baseURL)/Readers/Favorite"
        return try await AF.request(
            url,
            method: .put,
            parameters: FavoriteMutationParameters(wcid: wcid, color: color, memo: memo, free: free),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(FavoriteMutationResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func deleteFavorite(wcid: Int) async throws -> Response<EmptyResponse> {
        let url = "\(baseURL)/Readers/Favorite"
        return try await AF.request(
            url,
            method: .delete,
            parameters: FavoriteDeleteParameters(wcid: wcid),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(Response<EmptyResponse>.self, decoder: makeDecoder())
            .value
    }
    
    static func getUserInfo() async throws -> UserInfoResponse {
        let url = "\(baseURL)/User/Info"
        return try await AF.request(url, method: .post, headers: try await headers())
            .debugValidate()
            .serializingDecodable(UserInfoResponse.self, decoder: makeDecoder())
            .value
    }
    
    static func queryBooks(eventId: Int, circleName: String? = nil, workName: String? = nil, workWord: String? = nil, genre: String? = nil, floor: String? = nil, sort: String? = nil, page: Int? = nil, lastUpdate: String? = nil) async throws -> BookQueryResponse {
        let url = "\(baseURL)/WebCatalog/QueryBook"
        return try await AF.request(
            url,
            parameters: BookQueryParameters(
                eventID: eventId,
                circleName: circleName,
                workName: workName,
                workWord: workWord,
                genre: genre,
                floor: floor,
                sort: sort,
                page: page,
                lastUpdate: lastUpdate
            ),
            encoder: URLEncodedFormParameterEncoder.default,
            headers: try await headers()
        )
            .debugValidate()
            .serializingDecodable(BookQueryResponse.self, decoder: makeDecoder())
            .value
    }
}
