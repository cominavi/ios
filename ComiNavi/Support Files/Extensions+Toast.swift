//
//  Extensions+Toast.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/22/24.
//

import Foundation
import Toast

extension Toast {
    static func showError(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle)
        toast.enableTapToClose()
        toast.show(haptic: .error)
    }

    static func showSuccess(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle)
        toast.enableTapToClose()
        toast.show(haptic: .success)
    }

    static func showInfo(_ title: String, subtitle: String?) {
        let toast = Toast.text(title, subtitle: subtitle)
        toast.enableTapToClose()
        toast.show()
    }
}
