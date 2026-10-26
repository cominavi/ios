import SwiftUI
import UIKit

/// App-wide Lucide icons bundled from Iconify's `@iconify-json/lucide` data.
///
/// Icons are decorative by default: the text next to them already names the
/// action, so VoiceOver must not read the asset name. Pass `accessibilityLabel`
/// only when the icon is the sole content of a control.
struct LucideIcon: View {
    private let legacyName: String
    private let requestedSize: Double?
    private let accessibilityLabel: Text?
    /// Dynamic Type multiplier applied to every icon, including fixed `size:` call sites.
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    init(_ legacyName: String, size: Double? = nil, accessibilityLabel: Text? = nil) {
        self.legacyName = legacyName
        requestedSize = size
        self.accessibilityLabel = accessibilityLabel
        Self.assertAssetExists(Self.assetName(for: legacyName))
    }

    var body: some View {
        let dimension = Self.scaledDimension(requestedSize ?? Self.defaultSize, scale: scale)
        icon
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: dimension, height: dimension)
    }

    private var icon: Image {
        if let accessibilityLabel {
            Image(Self.assetName(for: legacyName), label: accessibilityLabel)
        } else {
            Image(decorative: Self.assetName(for: legacyName))
        }
    }

    static let defaultSize = 17.0

    /// Scales a design size with Dynamic Type. Large hero glyphs grow less than
    /// inline icons so that they do not push the text they illustrate off screen.
    static func scaledDimension(_ size: Double, scale: Double) -> Double {
        let maximumScale = size >= 28 ? 1.4 : 2.0
        return size * min(max(scale, 0.8), maximumScale)
    }

    static func assertAssetExists(_ assetName: String) {
        #if DEBUG
            if UIImage(named: assetName) == nil {
                assertionFailure("Missing icon asset \(assetName). Add a mapping or an imageset.")
            }
        #endif
    }

    static func uiImage(for legacyName: String) -> UIImage? {
        UIImage(named: assetName(for: legacyName))?.withRenderingMode(.alwaysTemplate)
    }

    /// Every SF Symbol-style name with an explicit mapping, for asset coverage tests.
    static var mappedLegacyNames: [String] {
        Array(lucideNameByLegacyName.keys)
    }

    static func assetName(for legacyName: String) -> String {
        "lucide-\(lucideNameByLegacyName[legacyName] ?? legacyName)"
    }

    private static let lucideNameByLegacyName: [String: String] = [
        "antenna.radiowaves.left.and.right": "radio-tower",
        "arrow.clockwise": "rotate-cw",
        "arrow.down": "arrow-down",
        "arrow.down.right": "arrow-down-right",
        "arrow.left.arrow.right": "arrow-left-right",
        "arrow.triangle.2.circlepath": "refresh-cw",
        "arrow.triangle.turn.up.right.diamond.fill": "navigation",
        "arrow.up.left.and.arrow.down.right": "maximize-2",
        "arrow.up.right": "external-link",
        "arrow.down.circle.fill": "circle-arrow-down",
        "at": "at-sign",
        "building.2": "building-2",
        "building.2.crop.circle": "building-2",
        "building.2.fill": "building-2",
        "calendar": "calendar-days",
        "calendar.badge.clock": "calendar-clock",
        "character.textbox": "scan-text",
        "checkmark": "check",
        "checkmark.circle.fill": "circle-check-big",
        "chevron.down": "chevron-down",
        "chevron.forward": "chevron-right",
        "chevron.up": "chevron-up",
        "chevron.up.chevron.down": "chevrons-up-down",
        "circle": "circle",
        "circle.dotted": "loader-circle",
        "clock.badge": "clock",
        "delete.left.fill": "delete",
        "doc.on.doc": "copy",
        "doc.richtext": "file-text",
        "doc.richtext.fill": "file-text",
        "ellipsis": "ellipsis",
        "exclamationmark.circle": "circle-alert",
        "exclamationmark.circle.fill": "circle-alert",
        "exclamationmark.triangle.fill": "triangle-alert",
        "externaldrive": "database",
        "eye": "eye",
        "eye.slash": "eye-off",
        "figure.walk": "person-standing",
        "figure.walk.arrival": "footprints",
        "gearshape.2.fill": "settings",
        "globe": "globe",
        // Manual positioning: the user points at the map.
        "hand.tap.fill": "pointer",
        "info.circle": "info",
        "info.circle.fill": "info",
        "line.3.horizontal.decrease": "list-filter",
        "line.3.horizontal.decrease.circle": "list-filter",
        "line.3.horizontal.decrease.circle.fill": "list-filter",
        "list.bullet": "list",
        // GPS and "where am I" use crosshairs. `map-pin` is only for destinations.
        "location": "locate",
        "location.fill": "locate",
        "location.north.fill": "navigation",
        "location.north.line.fill": "compass",
        "location.slash": "map-pin-off",
        "location.viewfinder": "locate-fixed",
        "magnifyingglass": "search",
        "map": "map",
        "map.fill": "map",
        "mappin.and.ellipse": "map-pin",
        "minus": "minus",
        "person.circle": "circle-user",
        "person.circle.fill": "circle-user",
        "person.crop.circle.badge.questionmark": "user-round-search",
        "person.2.crop.square.stack": "users",
        "person.crop.circle.badge.minus": "user-round-minus",
        "person.crop.circle.badge.plus": "user-round-plus",
        "person.crop.circle.badge.xmark": "user-round-x",
        "person.slash": "user-round-x",
        "photo.badge.exclamationmark": "image-off",
        "photo.stack": "images",
        "paintbrush.pointed": "paintbrush",
        "plus": "plus",
        "ruler": "ruler",
        // The Explore tab uses binoculars so the compass overlay keeps `compass`.
        "binoculars": "binoculars",
        "safari": "compass",
        "slider.horizontal.3": "sliders-horizontal",
        "sparkle.magnifyingglass": "scan-search",
        "sparkles": "sparkles",
        "square.grid.2x2": "grid-2x2",
        "square.3.layers.3d": "layers-3",
        "square.3.layers.3d.top.filled": "layers-3",
        "square.and.arrow.up": "share",
        "star": "star",
        "star.fill": "star-filled",
        "tag": "tag",
        "tag.fill": "tag",
        "tag.slash": "tag-x",
        "theatermasks": "drama",
        "theatermasks.fill": "drama",
        "text.magnifyingglass": "search",
        "door.left.hand.open": "door-open",
        "cart.fill": "shopping-cart",
        "cross.case.fill": "briefcase-medical",
        "figure.stairs": "move-vertical",
        "arrow.trianglehead.branch": "git-branch",
        "wifi.exclamationmark": "wifi-off",
        "xmark": "x",
        "xmark.circle.fill": "x",
    ]
}

/// Brand marks bundled from Iconify's `simple-icons` set.
struct IconifyBrandIcon: View {
    private let name: String
    private let requestedSize: Double?
    private let accessibilityLabel: Text?
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    init(_ name: String, size: Double? = nil, accessibilityLabel: Text? = nil) {
        self.name = name
        requestedSize = size
        self.accessibilityLabel = accessibilityLabel
        LucideIcon.assertAssetExists("simple-icons-\(name)")
    }

    static func uiImage(for name: String) -> UIImage? {
        UIImage(named: "simple-icons-\(name)")?.withRenderingMode(.alwaysTemplate)
    }

    var body: some View {
        let dimension = LucideIcon.scaledDimension(requestedSize ?? 19, scale: scale)
        icon
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: dimension, height: dimension)
    }

    private var icon: Image {
        if let accessibilityLabel {
            Image("simple-icons-\(name)", label: accessibilityLabel)
        } else {
            Image(decorative: "simple-icons-\(name)")
        }
    }
}

struct LucideLabel: View {
    private let title: Text
    private let icon: String

    init(_ title: LocalizedStringKey, icon: String) {
        self.title = Text(title)
        self.icon = icon
    }

    init(resource title: LocalizedStringResource, icon: String) {
        self.title = Text(title)
        self.icon = icon
    }

    init(verbatim title: String, icon: String) {
        self.title = Text(verbatim: title)
        self.icon = icon
    }

    var body: some View {
        Label {
            title
        } icon: {
            LucideIcon(icon)
        }
        // One element whose label is the title. A Section header then reads its
        // title with the heading trait instead of an icon asset name.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

struct LucideContentUnavailableView: View {
    private let title: LocalizedStringKey
    private let icon: String
    private let description: Text?

    init(
        _ title: LocalizedStringKey,
        icon: String,
        description: Text? = nil
    ) {
        self.title = title
        self.icon = icon
        self.description = description
    }

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                LucideIcon(icon)
                Text(title)
            }
        } description: {
            if let description {
                description
            }
        }
    }
}
