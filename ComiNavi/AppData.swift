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

            if let user = user, let userId = user.userId, let nickname = user.nickname {
                SentrySDK.configureScope { scope in
                    let sentryUser = Sentry.User(userId: userId.string)
                    sentryUser.name = nickname
                    scope.setUser(sentryUser)
                }

                PostHogSDK.shared.identify(userId.string, userProperties: ["name": nickname, "r18": user.preferenceR18Enabled as Any])
            } else {
                SentrySDK.configureScope { scope in
                    scope.setUser(nil)
                }

                PostHogSDK.shared.reset()
            }
        }
    }

    var isLoggedIn: Bool {
        return user?.accessToken != nil
    }
}
