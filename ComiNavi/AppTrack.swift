//
//  AppTrack.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/6/24.
//

import Foundation
import PostHog
import Sentry

enum AppTrack {
    static func user(_ user: User?) {
        if let user = user, let userId = user.userId, let nickname = user.nickname {
            SentrySDK.configureScope { scope in
                let sentryUser = Sentry.User(userId: userId.string)
                sentryUser.name = nickname
                scope.setUser(sentryUser)
            }

            PostHogSDK.shared.identify(userId.string, userProperties: [
                "name": nickname,
                "circlems_preferences_r18enabled": user.preferenceR18Enabled as Any
            ])
        } else {
            SentrySDK.configureScope { scope in
                scope.setUser(nil)
            }

            PostHogSDK.shared.reset()
        }
    }
}
