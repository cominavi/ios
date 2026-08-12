//
//  Extensions+Toast.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/22/24.
//

import Foundation
import Toast
import UIKit

@MainActor
enum AppToast {
    private static let configuration = ToastConfiguration(
        direction: .top,
        dismissBy: [.time(time: 4), .swipe(direction: .natural), .tap],
        animationTime: 0.28,
        allowToastOverlap: false
    )

    private static let viewConfiguration = ToastViewConfiguration(
        minHeight: 68,
        minWidth: 180,
        darkBackgroundColor: UIColor(white: 0.12, alpha: 0.98),
        lightBackgroundColor: UIColor(white: 0.98, alpha: 0.98),
        titleNumberOfLines: 2,
        subtitleNumberOfLines: 3,
        cornerRadius: 20
    )

    static func showError(_ title: String, subtitle: String?) {
        let toast = makeToast(
            title: title,
            subtitle: subtitle,
            symbolName: "exclamationmark.triangle.fill",
            symbolColor: .systemRed
        )
        toast.show(haptic: .error)
    }

    static func showSuccess(_ title: String, subtitle: String?) {
        let toast = makeToast(
            title: title,
            subtitle: subtitle,
            symbolName: "checkmark.circle.fill",
            symbolColor: .systemGreen
        )
        toast.show(haptic: .success)
    }

    static func showInfo(_ title: String, subtitle: String?) {
        let toast = makeToast(
            title: title,
            subtitle: subtitle,
            symbolName: "info.circle.fill",
            symbolColor: .systemBlue
        )
        toast.show()
    }

    private static func makeToast(
        title: String,
        subtitle: String?,
        symbolName: String,
        symbolColor: UIColor
    ) -> Toast {
        guard let image = UIImage(systemName: symbolName) else {
            return Toast.text(
                title,
                subtitle: subtitle,
                viewConfig: viewConfiguration,
                config: configuration
            )
        }

        return Toast.default(
            image: image,
            imageTint: symbolColor,
            title: title,
            subtitle: subtitle,
            viewConfig: viewConfiguration,
            config: configuration
        )
    }
}
