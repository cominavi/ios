//
//  AppDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/1/24.
//

import Foundation
import PostHog
import Sentry

enum AppData {
    // CirclemsDataSource shall be initialized by EntryView
    public static var circlems: CirclemsDataSource!

    @UserDefaultsBacked("circlems.user")
    static var user: User?

    static var userState = UserState()

    public static func getUserToken() async -> String {
        // TODO: refresh user token before returning the header if it has already expired.
        return AppData.userState.user?.accessToken ?? ""
    }
}

struct User: Codable {
    var accessToken: String?
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
    var userId: Int?
    var nickname: String?
    var preferenceR18Enabled: Bool?
}

class UserState: ObservableObject {
    @Published var user = AppData.user {
        didSet {
            AppData.user = user
            
            AppTrack.user(user)
        }
    }

    var isLoggedIn: Bool {
        return user?.accessToken != nil
    }
}
