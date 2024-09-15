//
//  ComiNaviApp.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import SwiftData
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {}

@main
struct ComiNaviApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
