//
//  ComiNaviApp.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import SwiftData
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    // handle url scheme open (cominavi://open-circle?from-twitter-url=httpsxxxxx)
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NSLog("[ComiNavi.AppDelegate] Received URL: \(url)")
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        
        guard let queryItems = components.queryItems else {
            return false
        }
        
        guard let fromTwitterURL = queryItems.first(where: { $0.name == "from-twitter-url" })?.value else {
            return false
        }
        
        guard let url = URL(string: fromTwitterURL) else {
            return false
        }
        
        let username = url.lastPathComponent
        guard !username.isEmpty else {
            return false
        }
        
        let circleExtend = try? CirclemsDataSource.shared.sqliteMain.read { db in
            try CirclemsDataSchema.ComiketCircleExtend.fetchOne(db, sql: "SELECT * FROM ComiketCircleExtend WHERE twitterURL = ?", arguments: ["https://twitter.com/\(username)"])
        }
        
        guard let circleExtend = circleExtend else {
            return false
        }
        guard let circle = CirclemsDataSource.shared.circles.first(where: { $0.id == circleExtend.id }) else { return false }
        let rootView = CirclePreviewView(circle: circle)
        let vc = UIHostingController(rootView: rootView)
        UIApplication.shared.windows.first?.rootViewController?.present(vc, animated: true, completion: nil)
        
        return true
    }
}

@main
struct ComiNaviApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
