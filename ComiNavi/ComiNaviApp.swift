//
//  ComiNaviApp.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

#if DEBUG
import DebugSwift
#endif
import PostHog
import Sentry
import SwiftData
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        SentrySDK.start { options in
            options.dsn = "https://36a7d7a2a5e4f350eef0142c1ec297e0@o4508052459225088.ingest.us.sentry.io/4508052462305280"
            options.tracesSampleRate = 0.5 // Sample 50% of transactions
            #if DEBUG
            options.enabled = false
            #else
            options.enabled = true
            #endif
        }

        #if !DEBUG
        var posthogConfig = PostHogConfig(
            apiKey: "phc_RFEZavxHTrPF8x3frBKZvO6rLNId8DEwq3y6YykY9uc",
            host: "https://us.i.posthog.com")
        PostHogSDK.shared.setup(posthogConfig)
        #endif

        #if DEBUG
        DebugSwift.setup()
        DebugSwift.show()
        #endif

        AppTrack.user(AppData.userState.user)

        return true
    }
}

@main
struct ComiNaviApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EntryView()
        }
    }
}
