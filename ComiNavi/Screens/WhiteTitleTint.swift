import SwiftUI
import UIKit

extension Color {
    /// The tint for a system control that always draws a white title on its
    /// tint, such as `PasteButton`.
    ///
    /// The asset accent is dark olive in light mode but lime in dark mode,
    /// and white text on lime is not legible. This color keeps the
    /// light-mode olive (and its high-contrast variant) in both appearances.
    static let whiteTitleTint = Color(uiColor: UIColor { traits in
        let lightTraits = UITraitCollection(traitsFrom: [
            traits,
            UITraitCollection(userInterfaceStyle: .light),
        ])
        return (UIColor(named: "AccentColor") ?? .systemGreen)
            .resolvedColor(with: lightTraits)
    })
}
