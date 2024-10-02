//
//  ComiNaviApp.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

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
        }

        PostHogSDK.shared.setup(
            PostHogConfig(
                apiKey: "phc_fj1m73n4ngugOVGfueEqVvXaVhGUP0D8e0ZvR4w00Tr",
                host: "https://us.i.posthog.com"))

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
