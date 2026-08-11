//
//  Extensions+Toast.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/22/24.
//

import Foundation
import Toast

@MainActor
enum AppToast {
    private static let configuration = ToastConfiguration(
        direction: .bottom,
        dismissBy: [.time(time: 4), .swipe(direction: .natural), .tap],
        allowToastOverlap: false
    )

    static func showError(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle, config: configuration)
        toast.show(haptic: .error)
    }

    static func showSuccess(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle, config: configuration)
        toast.show(haptic: .success)
    }

    static func showInfo(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle, config: configuration)
        toast.show()
    }
}
