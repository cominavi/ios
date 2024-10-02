//
//  CirclemsAPI.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Alamofire
import Foundation

enum CirclemsAPI {
    public static let baseURL = "https://api1-sandbox.circle.ms"
    public static let authBaseURL = "https://auth1-sandbox.circle.ms"
    
    private struct APIError: Error, Decodable {
        let message: String
    }
    
    private static let decoder = { () -> JSONDecoder in
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    
    private static func headers() async -> HTTPHeaders {
        ["Authorization": "Bearer \(await AppData.getUserToken())"]
    }
    
    // MARK: - Response Types
    
    struct Response<T: Decodable>: Decodable {
        let response: T
        let status: String
    }

    typealias EventListResponse = Response<EventListResponseData>
    
    struct EventListResponseData: Decodable {
        struct Event: Decodable {
            let id: Int
            let name: String
        }
        
        let events: [Event]
    }
    
    typealias CatalogBaseResponse = Response<CatalogBaseResponseData>

    struct CatalogBaseResponseData: Decodable {
        struct DBKeys: Decodable {
            let textdbSqlite3UrlSsl: String
            let imagedb1UrlSsl: String
        }
        
        let url: DBKeys
        let md5: DBKeys
        let updatedate: String
    }
    
    typealias FavoriteCirclesResponse = Response<FavoriteCirclesResponseData>

    struct FavoriteCirclesResponseData: Decodable {
        let circles: [FavoriteCircle]
    }

    struct FavoriteCircle: Decodable {
        let id: String
        let name: String
    }
    
    typealias CircleResponse = Response<CircleResponseData>

    struct CircleResponseData: Decodable {
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
        
        struct OnlineStore: Decodable {
            let name: String
            let link: String
        }
    }
    
    typealias CircleQueryResponse = Response<CircleQueryResponseData>

    struct CircleQueryResponseData: Decodable {
        let circles: [CircleResponse]
    }
    
    typealias UserInfoResponse = Response<UserInfoResponseData>

    struct UserInfoResponseData: Decodable {
        let id: Int
        let name: String
        let r18: Int
    }
    
    typealias BookQueryResponse = Response<BookQueryResponseData>

    struct BookQueryResponseData: Decodable {
        let books: [Book]
    }

    struct Book: Decodable {
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

    struct FavoriteInfoResponseData: Decodable {
        /// 公開サークルId
        let wcid: Int
        /// サークル名
        let circleName: String
        /// カラー番号
        let color: Int
        /// ユーザメモ情報
        let memo: String
        /// 自由入力データ
        let free: String
        /// お気に入り情報のJST形式の最終更新日時
        let updateDate: String
    }
    
    // A placeholder for empty responses
    struct EmptyResponse: Decodable {}

    // MARK: - API Methods
    
    static func getEventList() async throws -> EventListResponse {
        let url = "\(baseURL)/WebCatalog/GetEventList"
        return try await AF.request(url, headers: await headers())
            .validate()
            .serializingDecodable(EventListResponse.self, decoder: decoder)
            .value
    }
    
    static func getCatalogBase(eventId: Int) async throws -> CatalogBaseResponse {
        let url = "\(baseURL)/CatalogBase/All/"
        let parameters: [String: Any] = ["event_Id": eventId]
        return try await AF.request(url, parameters: parameters, headers: await headers())
            .validate()
            .cURLDescription(calling: { print($0) })
            .serializingDecodable(CatalogBaseResponse.self, decoder: decoder)
            .value
    }
    
    static func getFavoriteCircles(eventId: Int, circleName: String? = nil) async throws -> FavoriteCirclesResponse {
        let url = "\(authBaseURL)/Readers/FavoriteCircles"
        var parameters: [String: Any] = ["event_id": eventId]
        if let circleName = circleName {
            parameters["circle_name"] = circleName
        }
        return try await AF.request(url, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(FavoriteCirclesResponse.self, decoder: decoder)
            .value
    }
    
    static func getCircle(wcid: String) async throws -> CircleResponse {
        let url = "\(baseURL)/WebCatalog/GetCircle"
        let parameters: [String: Any] = ["wcid": wcid]
        return try await AF.request(url, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(CircleResponse.self, decoder: decoder)
            .value
    }
    
    static func queryCircles(eventId: Int, circleName: String? = nil, genre: String? = nil, floor: String? = nil, sort: String? = nil, lastUpdate: String? = nil) async throws -> CircleQueryResponse {
        let url = "\(baseURL)/WebCatalog/QueryCircle"
        var parameters: [String: Any] = ["event_Id": eventId]
        if let circleName = circleName { parameters["circle_name"] = circleName }
        if let genre = genre { parameters["genre"] = genre }
        if let floor = floor { parameters["floor"] = floor }
        if let sort = sort { parameters["sort"] = sort }
        if let lastUpdate = lastUpdate { parameters["lastupdate"] = lastUpdate }
        return try await AF.request(url, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(CircleQueryResponse.self, decoder: decoder)
            .value
    }
    
    static func addFavorite(wcid: String, color: String? = nil, memo: String? = nil, free: String? = nil) async throws -> EmptyResponse {
        let url = "\(baseURL)/Readers/Favorite"
        var parameters: [String: Any] = ["wcid": wcid]
        if let color = color { parameters["color"] = color }
        if let memo = memo { parameters["memo"] = memo }
        if let free = free { parameters["free"] = free }
        return try await AF.request(url, method: .post, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(EmptyResponse.self, decoder: decoder)
            .value
    }
    
    static func editFavorite(wcid: String, color: String? = nil, memo: String? = nil, free: String? = nil) async throws -> EmptyResponse {
        let url = "\(baseURL)/Readers/Favorite"
        var parameters: [String: Any] = ["wcid": wcid]
        if let color = color { parameters["color"] = color }
        if let memo = memo { parameters["memo"] = memo }
        if let free = free { parameters["free"] = free }
        return try await AF.request(url, method: .put, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(EmptyResponse.self, decoder: decoder)
            .value
    }
    
    static func deleteFavorite(wcid: String) async throws -> EmptyResponse {
        let url = "\(baseURL)/Readers/Favorite"
        let parameters: [String: Any] = ["wcid": wcid]
        return try await AF.request(url, method: .delete, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(EmptyResponse.self, decoder: decoder)
            .value
    }
    
    static func getUserInfo() async throws -> UserInfoResponse {
        let url = "\(baseURL)/User/Info"
        return try await AF.request(url, headers: await headers())
            .validate()
            .serializingDecodable(UserInfoResponse.self, decoder: decoder)
            .value
    }
    
    static func queryBooks(eventId: Int, circleName: String? = nil, workName: String? = nil, workWord: String? = nil, genre: String? = nil, floor: String? = nil, sort: String? = nil, page: Int? = nil, lastUpdate: String? = nil) async throws -> BookQueryResponse {
        let url = "\(baseURL)/WebCatalog/QueryBook"
        var parameters: [String: Any] = ["event_Id": eventId]
        if let circleName = circleName { parameters["circle_name"] = circleName }
        if let workName = workName { parameters["work_name"] = workName }
        if let workWord = workWord { parameters["work_word"] = workWord }
        if let genre = genre { parameters["genre"] = genre }
        if let floor = floor { parameters["floor"] = floor }
        if let sort = sort { parameters["sort"] = sort }
        if let page = page { parameters["page"] = page }
        if let lastUpdate = lastUpdate { parameters["lastupdate"] = lastUpdate }
        return try await AF.request(url, parameters: parameters, headers: await headers())
            .validate()
            .serializingDecodable(BookQueryResponse.self, decoder: decoder)
            .value
    }
}
