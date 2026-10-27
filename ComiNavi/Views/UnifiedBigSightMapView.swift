import CoreLocation
import MapLibre
import OSLog
import SpriteKit
import SwiftUI
import UIKit

enum MapChromeLayout {
    static let edgeInset: CGFloat = Spacing.large
    static let controlSize: CGFloat = HitArea.minimum
    static let controlSpacing: CGFloat = Spacing.small

    /// Width of the SwiftUI location controls at the trailing end of the
    /// bottom row. MapView shows "Where am I?" alone, or with the destination
    /// pin when a destination exists.
    static func locationControlsWidth(count: Int) -> CGFloat {
        let count = CGFloat(max(count, 0))
        return controlSize * count + controlSpacing * max(count - 1, 0)
    }

    /// Trailing inset of the compass, which sits just before the location
    /// controls with one `controlSpacing` gap.
    static func adjacentChromeTrailingInset(locationControlCount: Int) -> CGFloat {
        edgeInset + locationControlsWidth(count: locationControlCount)
            + (locationControlCount > 0 ? controlSpacing : 0)
    }
}

enum UnifiedMapAppearance: Equatable {
    case light
    case dark

    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }

    var palette: UnifiedMapPalette {
        switch self {
        case .light:
            UnifiedMapPalette(
                mapBackground: UIColor(white: 0.94, alpha: 1),
                grid: UIColor.black.withAlphaComponent(0.055),
                pedestrianUnderlay: UIColor.white.withAlphaComponent(0.86),
                pedestrianFootway: UIColor(white: 0.27, alpha: 0.72),
                pedestrianSteps: UIColor(red: 0.70, green: 0.34, blue: 0.13, alpha: 0.84),
                bridgeFill: UIColor(white: 0.86, alpha: 0.96),
                bridgeStroke: UIColor.black.withAlphaComponent(0.36),
                floor: .white,
                floorStroke: UIColor.black.withAlphaComponent(0.26),
                tableStroke: UIColor.black.withAlphaComponent(0.72),
                tableDivider: UIColor.black.withAlphaComponent(0.5),
                primaryText: UIColor.black.withAlphaComponent(0.82),
                secondaryText: UIColor.black.withAlphaComponent(0.58),
                venueText: UIColor(red: 0.03, green: 0.24, blue: 0.16, alpha: 1),
                blockText: UIColor(red: 0.02, green: 0.56, blue: 0.32, alpha: 0.9),
                chromeBackground: UIColor.white.withAlphaComponent(0.92),
                iconBackground: UIColor.white.withAlphaComponent(0.96),
                markerStroke: UIColor.separator.withAlphaComponent(0.35)
            )
        case .dark:
            UnifiedMapPalette(
                mapBackground: UIColor(red: 0.055, green: 0.063, blue: 0.071, alpha: 1),
                grid: UIColor.white.withAlphaComponent(0.075),
                pedestrianUnderlay: UIColor.black.withAlphaComponent(0.72),
                pedestrianFootway: UIColor(white: 0.78, alpha: 0.76),
                pedestrianSteps: UIColor(red: 0.96, green: 0.57, blue: 0.28, alpha: 0.90),
                bridgeFill: UIColor(white: 0.25, alpha: 0.96),
                bridgeStroke: UIColor.white.withAlphaComponent(0.42),
                floor: UIColor(red: 0.105, green: 0.115, blue: 0.125, alpha: 1),
                floorStroke: UIColor.white.withAlphaComponent(0.3),
                tableStroke: UIColor.white.withAlphaComponent(0.68),
                tableDivider: UIColor.white.withAlphaComponent(0.42),
                primaryText: UIColor(white: 0.93, alpha: 0.92),
                secondaryText: UIColor(white: 0.72, alpha: 1),
                venueText: UIColor(red: 0.55, green: 0.90, blue: 0.72, alpha: 1),
                blockText: UIColor(red: 0.32, green: 0.92, blue: 0.58, alpha: 0.95),
                chromeBackground: UIColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 0.94),
                iconBackground: UIColor(white: 0.94, alpha: 0.96),
                markerStroke: UIColor.black.withAlphaComponent(0.18)
            )
        }
    }
}

struct UnifiedMapPalette {
    let mapBackground: UIColor
    let grid: UIColor
    let pedestrianUnderlay: UIColor
    let pedestrianFootway: UIColor
    let pedestrianSteps: UIColor
    let bridgeFill: UIColor
    let bridgeStroke: UIColor
    let floor: UIColor
    let floorStroke: UIColor
    let tableStroke: UIColor
    let tableDivider: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let venueText: UIColor
    let blockText: UIColor
    let chromeBackground: UIColor
    /// ComiNavi's pictograms are tinted at render time. A light tile in both
    /// appearances preserves their category colors and map-size contrast.
    let iconBackground: UIColor
    let markerStroke: UIColor
}

extension UnifiedMapPalette {
    /// The halo behind map text, so roads, footways, and floor artwork never
    /// cross a label. It matches the floor the labels mostly sit on.
    var labelHalo: UIColor { floor.withAlphaComponent(0.9) }
}

extension UnifiedMapAppearance {
    /// The rim around the colored plate of a hall badge. White in light mode;
    /// the dark floor color in dark mode, so the badge has the same visual
    /// weight on both maps.
    var venueBadgeRim: UIColor {
        self == .dark ? palette.floor : .white
    }

    var venueBadgeRimStroke: UIColor {
        self == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.16)
    }
}

/// A single retained-mode surface for both the Big Sight campus and every hall map.
/// Gestures mutate `SKCameraNode` directly, so dragging does not invalidate SwiftUI.
struct UnifiedBigSightMapView: UIViewRepresentable {
    let campus: BigSightCampusScene
    let scope: MapScreenModel.Scope
    let selectedMapID: Int
    let selectedTableID: CatalogMapTable.ID?
    let circlePlacements: [CatalogMapCirclePlacement]
    let circleArtwork: [Int: CGImage]
    let searchMatches: [CatalogMapSearchMatch]
    let searchActive: Bool
    let genrePlacements: [CatalogMapGenrePlacement]
    let bookmarks: [MapBookmark]
    let primarySharedPlanCircles: [CatalogBookmarkLocation]
    let locatedUser: LocatedMapUser?
    let destination: MapDestination?
    let visibleMapLayers: Set<BigSightMapLayer>
    let locationFocusBottomInset: CGFloat
    let onViewportChange: (CatalogMapViewport) -> Void
    let onCameraRotationChange: (CGFloat) -> Void
    let onSelectVenue: (Int) -> Void
    let onShowCampus: () -> Void
    let onSelectTable: (CatalogMapTable, Int) -> Void
    let onSelectLocatedUser: () -> Void
    let onLocate: (Int, CGPoint, CatalogMapTable, Int) -> Void
    /// Measured map chrome, so camera fits frame content in the uncovered
    /// area. When `nil`, the renderer estimates the chrome from the safe area.
    var overviewChromeInsets: MapViewportInsets? = nil
    /// Frames a campus target once per request `id`.
    var cameraFitRequest: MapCameraFitRequest? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UnifiedMapHostView {
        let appearance = UnifiedMapAppearance(colorScheme)
        let host = UnifiedMapHostView(appearance: appearance)
        let renderer = UnifiedBigSightScene(campus: campus, appearance: appearance)
        context.coordinator.connect(host: host, renderer: renderer)
        context.coordinator.updateCallbacks(
            onSelectVenue: onSelectVenue,
            onShowCampus: onShowCampus,
            onSelectTable: onSelectTable,
            onSelectLocatedUser: onSelectLocatedUser,
            onCameraRotationChange: onCameraRotationChange,
            onLocate: onLocate
        )
        host.mapView.presentScene(renderer)
        host.mapView.ignoresSiblingOrder = true
        host.mapView.shouldCullNonVisibleNodes = true
        host.mapView.isAsynchronous = true
        update(host: host, renderer: renderer)
        return host
    }

    func updateUIView(_ host: UnifiedMapHostView, context: Context) {
        guard let renderer = host.mapView.scene as? UnifiedBigSightScene else { return }
        context.coordinator.updateCallbacks(
            onSelectVenue: onSelectVenue,
            onShowCampus: onShowCampus,
            onSelectTable: onSelectTable,
            onSelectLocatedUser: onSelectLocatedUser,
            onCameraRotationChange: onCameraRotationChange,
            onLocate: onLocate
        )
        update(host: host, renderer: renderer)
    }

    private func update(host: UnifiedMapHostView, renderer: UnifiedBigSightScene) {
        let appearance = UnifiedMapAppearance(colorScheme)
        host.updateAppearance(appearance)
        renderer.updateAppearance(appearance)
        renderer.onViewportChange = onViewportChange
        renderer.reduceMotion = reduceMotion
        renderer.update(
            campus: campus,
            scope: scope,
            selectedMapID: selectedMapID,
            selectedTableID: selectedTableID,
            circlePlacements: circlePlacements,
            circleArtwork: circleArtwork,
            searchMatches: searchMatches,
            searchActive: searchActive,
            genrePlacements: genrePlacements,
            bookmarks: bookmarks,
            primarySharedPlanCircles: primarySharedPlanCircles,
            locatedUser: locatedUser,
            destination: destination,
            visibleMapLayers: visibleMapLayers,
            locationFocusBottomInset: locationFocusBottomInset,
            overviewInsets: overviewChromeInsets,
            cameraFitRequest: cameraFitRequest
        )
        // MapLocationControls shows the destination pin beside "Where am I?"
        // only while a destination exists.
        host.updateLocationControlCount(destination == nil ? 1 : 2)
        host.updateBasemap(camera: renderer.basemapCamera)
        host.updateAccessibility(renderer: renderer, scope: scope)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var host: UnifiedMapHostView?
        private weak var renderer: UnifiedBigSightScene?
        private var onSelectVenue: (Int) -> Void = { _ in }
        private var onShowCampus: () -> Void = {}
        private var onSelectTable: (CatalogMapTable, Int) -> Void = { _, _ in }
        private var onSelectLocatedUser: () -> Void = {}
        private var onCameraRotationChange: (CGFloat) -> Void = { _ in }
        private var onLocate: (Int, CGPoint, CatalogMapTable, Int) -> Void = { _, _, _, _ in }

        func connect(host: UnifiedMapHostView, renderer: UnifiedBigSightScene) {
            self.host = host
            self.renderer = renderer
            renderer.onCameraChange = { [weak self, weak host, weak renderer] in
                guard let self, let host, let renderer else { return }
                host.updateCompass(
                    rotation: renderer.cameraRotation,
                    gridAlignedRotation: renderer.gridAlignedCameraRotation
                )
                host.updateBasemap(camera: renderer.basemapCamera)
                host.updateAccessibility(renderer: renderer, scope: renderer.scope)
                self.onCameraRotationChange(renderer.cameraRotation)
            }
            renderer.onSemanticScopeChange = { [weak self] scope, mapID in
                guard let self else { return }
                switch scope {
                case .campus:
                    self.onShowCampus()
                case .venue:
                    if let mapID { self.onSelectVenue(mapID) }
                }
            }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 2
            pan.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self

            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
            rotation.delegate = self

            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.delegate = self

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            tap.require(toFail: doubleTap)

            let longPress = UILongPressGestureRecognizer(
                target: self, action: #selector(longPress(_:)))
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 18
            longPress.delegate = self

            [pan, pinch, rotation, tap, doubleTap, longPress].forEach(
                host.mapView.addGestureRecognizer)
            host.compassButton.addTarget(
                self, action: #selector(advanceCompassRotation), for: .touchUpInside)
            host.updateCompass(
                rotation: renderer.cameraRotation,
                gridAlignedRotation: renderer.gridAlignedCameraRotation
            )
            host.onActivateVenue = { [weak self, weak renderer] mapID in
                guard let self else { return }
                renderer?.requestVenue(mapID)
                self.onSelectVenue(mapID)
            }
        }

        func updateCallbacks(
            onSelectVenue: @escaping (Int) -> Void,
            onShowCampus: @escaping () -> Void,
            onSelectTable: @escaping (CatalogMapTable, Int) -> Void,
            onSelectLocatedUser: @escaping () -> Void,
            onCameraRotationChange: @escaping (CGFloat) -> Void,
            onLocate: @escaping (Int, CGPoint, CatalogMapTable, Int) -> Void
        ) {
            self.onSelectVenue = onSelectVenue
            self.onShowCampus = onShowCampus
            self.onSelectTable = onSelectTable
            self.onSelectLocatedUser = onSelectLocatedUser
            self.onCameraRotationChange = onCameraRotationChange
            self.onLocate = onLocate
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let navigationTypes: [UIGestureRecognizer.Type] = [
                UIPanGestureRecognizer.self,
                UIPinchGestureRecognizer.self,
                UIRotationGestureRecognizer.self,
            ]
            let firstIsNavigation = navigationTypes.contains {
                gestureRecognizer.isKind(of: $0)
            }
            let secondIsNavigation = navigationTypes.contains {
                otherGestureRecognizer.isKind(of: $0)
            }
            return firstIsNavigation && secondIsNavigation
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView = host?.mapView, let renderer else { return }
            if gesture.state == .began { renderer.beginGesture() }
            let translation = gesture.translation(in: mapView)
            if translation != .zero {
                renderer.pan(by: translation, in: mapView)
                gesture.setTranslation(.zero, in: mapView)
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                renderer.endPan(velocity: gesture.velocity(in: mapView), in: mapView)
            }
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let mapView = host?.mapView, let renderer else { return }
            if gesture.state == .began { renderer.beginGesture() }
            renderer.zoom(
                by: gesture.scale,
                around: gesture.location(in: mapView),
                in: mapView
            )
            gesture.scale = 1
            if gesture.state == .ended || gesture.state == .cancelled {
                renderer.endGesture()
            }
        }

        @objc private func rotate(_ gesture: UIRotationGestureRecognizer) {
            guard let mapView = host?.mapView, let renderer else { return }
            if gesture.state == .began { renderer.beginGesture() }
            renderer.rotate(
                by: gesture.rotation,
                around: gesture.location(in: mapView),
                in: mapView
            )
            gesture.rotation = 0
            if gesture.state == .ended || gesture.state == .cancelled {
                renderer.endGesture()
            }
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = host?.mapView,
                let renderer,
                let hit = renderer.hit(at: gesture.location(in: mapView), in: mapView)
            else { return }

            switch hit {
            case .userLocation:
                onSelectLocatedUser()
            case .venue(let venue):
                renderer.requestVenue(venue.id)
                onSelectVenue(venue.id)
            case .table(let table, let subspace):
                onSelectTable(table, subspace)
            }
        }

        @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = host?.mapView, let renderer else { return }
            renderer.animatedZoom(by: 2, around: gesture.location(in: mapView), in: mapView)
        }

        @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                let mapView = host?.mapView,
                let renderer,
                let location = renderer.locationHit(
                    at: gesture.location(in: mapView),
                    in: mapView
                )
            else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLocate(
                location.mapID,
                location.localPoint,
                location.table,
                location.subspace
            )
        }

        @objc private func advanceCompassRotation() {
            renderer?.advanceCompassRotation()
        }
    }
}

/// Load state of the MapLibre street basemap underneath the venue overlay.
/// The venue overlay never depends on it, so `.unavailable` only explains
/// the missing street context.
enum UnifiedBasemapState: Equatable {
    case loading
    case ready
    case unavailable
}

@MainActor
final class UnifiedMapHostView: UIView {
    /// Fallback only. Both appearances bundle their style so the map never
    /// needs the network before it can draw the venue context.
    private static let openStreetMapStyleURL = URL(string: "https://americanamap.org/style.json")!
    /// Tiles that have not rendered by then are treated as unreachable. The
    /// state still returns to `.ready` if MapLibre completes a render later.
    private static let basemapLoadTimeout: TimeInterval = 10
    private static let ambientCacheConfiguration: Void = {
        let cacheSize = UInt(150 * 1_024 * 1_024)
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "ComiNavi",
            category: "MapTileCache"
        )
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(cacheSize) { error in
            if let error {
                logger.error(
                    "Unable to configure the map tile cache: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }()

    let basemapView: MLNMapView
    let mapView = SKView(frame: .zero)
    let compassButton = MapCompassButton(type: .system)
    private let dataAttributionButton = MapAttributionButton(type: .system)
    private let campusAccessibilityProxy = UIView(frame: .zero)
    private let venueAccessibilityProxy = UIView(frame: .zero)
    private var requestedBasemapCamera: UnifiedBasemapCamera?
    private var lastBasemapCamera: UnifiedBasemapCamera?
    private var appearance: UnifiedMapAppearance
    private var compassState = CompassState.north
    private let basemapStatusChip = MapStatusChip(
        text: String(localized: "Street map unavailable offline. The venue map still works.")
    )
    private let campusHintChip = MapStatusChip(
        text: String(localized: "Tap a hall to open its floor map")
    )
    private let statusChipStack = UIStackView()
    private let venueAccessibilityContainer = UIView(frame: .zero)
    private var venueAccessibilityElements: [Int: MapVenueAccessibilityElement] = [:]
    private var basemapTimeoutWorkItem: DispatchWorkItem?
    /// Opens a hall from its VoiceOver button, matching a tap on the badge.
    var onActivateVenue: ((Int) -> Void)?
    private static let campusHintSeenKey = "map.campusHallHint.seen"
    /// Cached because accessibility refreshes on every camera frame.
    private var hasSeenCampusHint = UserDefaults.standard.bool(
        forKey: UnifiedMapHostView.campusHintSeenKey
    )
    private(set) var basemapState = UnifiedBasemapState.loading
    /// Number of SwiftUI location buttons trailing the compass.
    private(set) var locationControlCount = 1
    private var compassTrailingConstraint: NSLayoutConstraint!

    private enum CompassState: Equatable {
        case north
        case gridAligned
        case free
    }

    init(frame: CGRect = .zero, appearance: UnifiedMapAppearance = .light) {
        self.appearance = appearance
        _ = Self.ambientCacheConfiguration
        basemapView = MLNMapView(frame: .zero, styleURL: Self.styleURL(for: appearance))
        super.init(frame: frame)
        backgroundColor = appearance.palette.mapBackground

        basemapView.translatesAutoresizingMaskIntoConstraints = false
        basemapView.isUserInteractionEnabled = false
        basemapView.automaticallyAdjustsContentInset = false
        basemapView.contentInset = .zero
        basemapView.maximumZoomLevel = 25.5
        basemapView.logoView.isHidden = true
        basemapView.attributionButton.isHidden = true
        basemapView.compassView.isHidden = true
        basemapView.delegate = self
        // MapLibre exposes its own zoom slider, compass, and attribution
        // elements even when they are visually hidden. The SpriteKit canvas
        // already describes the map, so the basemap stays silent.
        basemapView.accessibilityElementsHidden = true
        addSubview(basemapView)

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.backgroundColor = .clear
        mapView.allowsTransparency = true
        mapView.isOpaque = false
        mapView.isAccessibilityElement = true
        mapView.accessibilityIdentifier = "unified-map-canvas"
        addSubview(mapView)

        // Holds one button element per visible hall badge, read right after
        // the canvas itself.
        venueAccessibilityContainer.translatesAutoresizingMaskIntoConstraints = false
        venueAccessibilityContainer.backgroundColor = .clear
        venueAccessibilityContainer.isUserInteractionEnabled = false
        venueAccessibilityContainer.isAccessibilityElement = false
        addSubview(venueAccessibilityContainer)

        for proxy in [campusAccessibilityProxy, venueAccessibilityProxy] {
            proxy.translatesAutoresizingMaskIntoConstraints = false
            proxy.backgroundColor = .clear
            proxy.isUserInteractionEnabled = false
            addSubview(proxy)
            NSLayoutConstraint.activate([
                proxy.leadingAnchor.constraint(equalTo: leadingAnchor),
                proxy.trailingAnchor.constraint(equalTo: trailingAnchor),
                proxy.topAnchor.constraint(equalTo: topAnchor),
                proxy.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        // The proxies keep their scope-specific identifiers for automation,
        // but VoiceOver reads only `mapView` so the canvas is announced once.
        campusAccessibilityProxy.isAccessibilityElement = false
        campusAccessibilityProxy.accessibilityIdentifier = "campus-map-canvas"
        venueAccessibilityProxy.isAccessibilityElement = false
        venueAccessibilityProxy.accessibilityIdentifier = "interactive-map-canvas"

        // The compass draws its own material circle, so it matches the
        // SwiftUI location buttons beside it.
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        compassButton.configuration = configuration
        compassButton.accessibilityLabel = String(localized: "Align map to venue grid")
        compassButton.accessibilityIdentifier = "map-compass-button"
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(compassButton)

        var attributionConfiguration = UIButton.Configuration.plain()
        attributionConfiguration.title = "© OpenStreetMap"
        attributionConfiguration.baseForegroundColor = .secondaryLabel
        attributionConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer {
                incoming in
                var outgoing = incoming
                // Caption 2 follows Dynamic Type. The 13 pt cap keeps the
                // credit one compact line beside the bottom controls at
                // accessibility sizes, so it does not cover the map.
                outgoing.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                    for: .systemFont(ofSize: 11, weight: .regular),
                    maximumPointSize: 13
                )
                return outgoing
            }
        attributionConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.xSmall,
            leading: Spacing.small,
            bottom: Spacing.xSmall,
            trailing: Spacing.small
        )
        dataAttributionButton.configuration = attributionConfiguration
        dataAttributionButton.contentHorizontalAlignment = .trailing
        dataAttributionButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.72)
        // A pill, like the other floating map chrome. The button sets the
        // capsule radius from its height in `layoutSubviews`.
        dataAttributionButton.layer.cornerCurve = .continuous
        dataAttributionButton.accessibilityLabel = String(localized: "Map data attribution")
        dataAttributionButton.accessibilityValue =
            "OpenStreetMap, OpenStreetMap US, OpenMapTiles, and MapLibre"
        dataAttributionButton.accessibilityIdentifier = "map-data-attribution-button"
        dataAttributionButton.translatesAutoresizingMaskIntoConstraints = false
        dataAttributionButton.menu = UIMenu(
            title: String(localized: "Map data attribution"),
            children: [
                attributionAction(
                    title: "OpenStreetMap US Tileservice",
                    url: "https://tiles.openstreetmap.us"
                ),
                attributionAction(
                    title: "OpenStreetMap contributors",
                    url: "https://www.openstreetmap.org/copyright"
                ),
                attributionAction(title: "OpenMapTiles", url: "https://www.openmaptiles.org"),
                attributionAction(title: "MapLibre", url: "https://maplibre.org"),
            ]
        )
        dataAttributionButton.showsMenuAsPrimaryAction = true
        addSubview(dataAttributionButton)

        campusHintChip.accessibilityIdentifier = "map-campus-hint"
        campusHintChip.isHidden = true
        basemapStatusChip.accessibilityIdentifier = "map-basemap-status"
        basemapStatusChip.isHidden = true
        statusChipStack.axis = .vertical
        statusChipStack.alignment = .leading
        statusChipStack.spacing = MapChromeLayout.controlSpacing
        statusChipStack.isUserInteractionEnabled = false
        statusChipStack.translatesAutoresizingMaskIntoConstraints = false
        statusChipStack.addArrangedSubview(campusHintChip)
        statusChipStack.addArrangedSubview(basemapStatusChip)
        addSubview(statusChipStack)

        compassTrailingConstraint = compassButton.trailingAnchor.constraint(
            equalTo: safeAreaLayoutGuide.trailingAnchor,
            constant: -MapChromeLayout.adjacentChromeTrailingInset(
                locationControlCount: locationControlCount
            )
        )

        NSLayoutConstraint.activate([
            basemapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            basemapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            basemapView.topAnchor.constraint(equalTo: topAnchor),
            basemapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            compassButton.widthAnchor.constraint(equalToConstant: MapChromeLayout.controlSize),
            compassButton.heightAnchor.constraint(equalToConstant: MapChromeLayout.controlSize),
            compassTrailingConstraint,
            compassButton.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor,
                constant: -MapChromeLayout.edgeInset
            ),
            dataAttributionButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor,
                constant: MapChromeLayout.edgeInset
            ),
            // The credit follows the compass, so the bottom row keeps one
            // gap size and one center line.
            dataAttributionButton.trailingAnchor.constraint(
                equalTo: compassButton.leadingAnchor,
                constant: -MapChromeLayout.controlSpacing
            ),
            dataAttributionButton.centerYAnchor.constraint(
                equalTo: compassButton.centerYAnchor
            ),
            venueAccessibilityContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            venueAccessibilityContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            venueAccessibilityContainer.topAnchor.constraint(equalTo: topAnchor),
            venueAccessibilityContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusChipStack.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor,
                constant: MapChromeLayout.edgeInset
            ),
            statusChipStack.trailingAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor,
                constant: -MapChromeLayout.edgeInset
            ),
            // Sit above the bottom control row so the chips never cover the
            // compass, location buttons, or attribution.
            statusChipStack.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor,
                constant: -(MapChromeLayout.edgeInset + MapChromeLayout.controlSize
                    + MapChromeLayout.controlSpacing)
            ),
        ])
        beginBasemapLoad()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        applyChromeAppearance()
        center.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let screen = window?.windowScene?.screen {
            mapView.preferredFramesPerSecond = screen.maximumFramesPerSecond
        }
        synchronizeBasemapFromScene()

        // SpriteKit applies `.resizeFill` after the SKView receives its final
        // bounds. Re-read the fitted camera on the next main-loop turn so the
        // first MapLibre frame cannot remain at its default world camera.
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeBasemapFromScene()
        }
    }

    func updateAppearance(_ appearance: UnifiedMapAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        backgroundColor = appearance.palette.mapBackground
        applyChromeAppearance()
        basemapView.styleURL = Self.styleURL(for: appearance)
        beginBasemapLoad()
        lastBasemapCamera = nil
        applyRequestedBasemapCamera()
    }

    private func beginBasemapLoad() {
        basemapTimeoutWorkItem?.cancel()
        // Keep showing `.unavailable` across a style swap while offline; a
        // successful render clears it.
        if basemapState != .unavailable { setBasemapState(.loading) }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.basemapState == .loading else { return }
            self.setBasemapState(.unavailable)
        }
        basemapTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.basemapLoadTimeout, execute: timeout)
    }

    fileprivate func setBasemapState(_ state: UnifiedBasemapState) {
        if state != .loading {
            basemapTimeoutWorkItem?.cancel()
            basemapTimeoutWorkItem = nil
        }
        guard state != basemapState else { return }
        basemapState = state
        let isHidden = state != .unavailable
        guard basemapStatusChip.isHidden != isHidden else { return }
        basemapStatusChip.isHidden = isHidden
        if !isHidden {
            UIAccessibility.post(notification: .announcement, argument: basemapStatusChip.text)
        }
    }

    @objc private func didEnterBackground() {
        mapView.isPaused = true
        basemapView.isHidden = true
    }

    @objc private func willEnterForeground() {
        mapView.isPaused = false
        basemapView.isHidden = false
    }

    func updateCompass(rotation: CGFloat, gridAlignedRotation: CGFloat) {
        let state: CompassState
        if MapCameraMath.isRotation(rotation, alignedWith: gridAlignedRotation) {
            state = .gridAligned
        } else if MapCameraMath.isRotation(rotation, alignedWith: 0) {
            state = .north
        } else {
            state = .free
        }
        if state != compassState {
            compassState = state
            updateCompassAccessibility()
            applyCompassAppearance()
        }
        compassButton.updateIndicator(
            rotation: MapCameraMath.northIndicatorRotation(mapRotation: rotation)
        )
    }

    /// Moves the compass next to the visible location buttons, so the gap
    /// between every bottom control stays `MapChromeLayout.controlSpacing`.
    func updateLocationControlCount(_ count: Int) {
        guard count != locationControlCount else { return }
        locationControlCount = count
        compassTrailingConstraint.constant =
            -MapChromeLayout.adjacentChromeTrailingInset(locationControlCount: count)
        setNeedsLayout()
    }

    func updateBasemap(camera: UnifiedBasemapCamera) {
        requestedBasemapCamera = camera
        applyRequestedBasemapCamera()
    }

    private func synchronizeBasemapFromScene() {
        if let renderer = mapView.scene as? UnifiedBigSightScene {
            requestedBasemapCamera = renderer.basemapCamera
        }
        applyRequestedBasemapCamera()
    }

    private func applyRequestedBasemapCamera() {
        guard bounds.width > 1,
            bounds.height > 1,
            let camera = requestedBasemapCamera,
            camera != lastBasemapCamera
        else { return }
        lastBasemapCamera = camera
        basemapView.setCenter(
            camera.coordinate,
            zoomLevel: camera.zoomLevel,
            direction: camera.direction,
            animated: false
        )
    }

    private func applyChromeAppearance() {
        let palette = appearance.palette
        applyCompassAppearance()

        var attributionConfiguration = dataAttributionButton.configuration
        attributionConfiguration?.baseForegroundColor = palette.secondaryText
        dataAttributionButton.configuration = attributionConfiguration
        dataAttributionButton.backgroundColor = palette.chromeBackground.withAlphaComponent(0.76)
    }

    private func applyCompassAppearance() {
        let palette = appearance.palette
        var compassConfiguration = compassButton.configuration
        compassConfiguration?.baseForegroundColor = palette.primaryText
        compassButton.configuration = compassConfiguration
        compassButton.updateIndicatorColor(
            palette.primaryText,
            isGridAligned: compassState == .gridAligned
        )
    }

    private func updateCompassAccessibility() {
        switch compassState {
        case .north:
            compassButton.accessibilityLabel = String(localized: "Align map to venue grid")
        case .gridAligned, .free:
            compassButton.accessibilityLabel = String(localized: "Reset map to north")
        }
        compassButton.accessibilityValue = compassState == .gridAligned
            ? String(localized: "Grid aligned")
            : nil
    }

    private static func styleURL(for appearance: UnifiedMapAppearance) -> URL {
        let name = appearance == .dark ? "AmericanaDark" : "AmericanaLight"
        if let direct = Bundle.main.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "MapStyles"
        ) ?? Bundle.main.url(forResource: name, withExtension: "json") {
            return direct
        }
        let fileName = "\(name).json"
        if let resourceURL = Bundle.main.resourceURL,
            let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        {
            for case let url as URL in enumerator where url.lastPathComponent == fileName {
                return url
            }
        }
        assertionFailure("Missing bundled \(fileName) map style")
        return openStreetMapStyleURL
    }

    func alignmentResidual(
        at campusPoint: CGPoint,
        renderer: UnifiedBigSightScene
    ) -> CGVector {
        let geographic = BigSightCampusLayout.coordinate(from: campusPoint)
        let basemapPoint = basemapView.convert(
            CLLocationCoordinate2D(
                latitude: geographic.latitude,
                longitude: geographic.longitude
            ),
            toPointTo: basemapView
        )
        let overlayPoint = renderer.viewPoint(forCampus: campusPoint, in: mapView)
        return CGVector(
            dx: overlayPoint.x - basemapPoint.x,
            dy: overlayPoint.y - basemapPoint.y
        )
    }

    func updateAccessibility(renderer: UnifiedBigSightScene, scope: MapScreenModel.Scope) {
        mapView.accessibilityLabel =
            scope == .campus
            ? String(localized: "Tokyo Big Sight unified campus map")
            : String(localized: "Interactive unified venue map")
        mapView.accessibilityHint = String(
            localized:
                "Drag to move, pinch to zoom, rotate with two fingers, or tap a venue or table."
        )
        mapView.accessibilityValue = renderer.accessibilitySummary
        // The proxies only mark the scope for UI automation. They carry no
        // label, so assistive technology meets one map canvas, not two.
        campusAccessibilityProxy.isHidden = scope != .campus
        venueAccessibilityProxy.isHidden = scope != .venue
        updateVenueAccessibilityElements(renderer: renderer, scope: scope)
        updateCampusHint(scope: scope, isSearchActive: renderer.isSearchModeActive)
    }

    /// Exposes each visible hall badge as a button so VoiceOver users can open
    /// a hall from the campus overview without the venue menu.
    private func updateVenueAccessibilityElements(
        renderer: UnifiedBigSightScene,
        scope: MapScreenModel.Scope
    ) {
        let targets = scope == .campus ? renderer.venueBadgeTargets() : []
        let minimumSide = MapChromeLayout.controlSize
        var elements: [MapVenueAccessibilityElement] = []
        for target in targets {
            let element =
                venueAccessibilityElements[target.venueID]
                ?? MapVenueAccessibilityElement(accessibilityContainer: venueAccessibilityContainer)
            venueAccessibilityElements[target.venueID] = element
            element.accessibilityLabel = target.title
            element.accessibilityHint = String(localized: "Opens the floor map for this hall.")
            element.accessibilityTraits = .button
            element.accessibilityIdentifier = "map-venue-badge-\(target.venueID)"
            element.accessibilityFrameInContainerSpace = target.frame.insetBy(
                dx: min(0, (target.frame.width - minimumSide) / 2),
                dy: min(0, (target.frame.height - minimumSide) / 2)
            )
            let venueID = target.venueID
            element.onActivate = { [weak self] in
                self?.onActivateVenue?(venueID)
            }
            elements.append(element)
        }
        // Read badges top to bottom, then leading to trailing.
        elements.sort { lhs, rhs in
            let left = lhs.accessibilityFrameInContainerSpace
            let right = rhs.accessibilityFrameInContainerSpace
            if abs(left.midY - right.midY) > minimumSide / 2 {
                return left.midY < right.midY
            }
            return left.midX < right.midX
        }
        let currentIDs = (venueAccessibilityContainer.accessibilityElements ?? [])
            .map { ($0 as? MapVenueAccessibilityElement)?.accessibilityIdentifier }
        venueAccessibilityContainer.accessibilityElements = elements
        if currentIDs != elements.map(\.accessibilityIdentifier) {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    /// Shows "Tap a hall to open its floor map" on the campus overview until
    /// the attendee opens a hall for the first time. Search results replace
    /// the hint while search is active.
    private func updateCampusHint(scope: MapScreenModel.Scope, isSearchActive: Bool) {
        if scope == .venue, !hasSeenCampusHint {
            hasSeenCampusHint = true
            UserDefaults.standard.set(true, forKey: Self.campusHintSeenKey)
        }
        let isHidden = scope != .campus || hasSeenCampusHint || isSearchActive
        if campusHintChip.isHidden != isHidden {
            campusHintChip.isHidden = isHidden
        }
    }

    private func attributionAction(title: String, url: String) -> UIAction {
        UIAction(title: title) { _ in
            guard let url = URL(string: url) else { return }
            UIApplication.shared.open(url)
        }
    }
}

/// The map data credit stays visually compact, but accepts touches across a
/// full 44-point target around its label.
final class MapAttributionButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let minimumSide = MapChromeLayout.controlSize
        let target = bounds.insetBy(
            dx: min(0, (bounds.width - minimumSide) / 2),
            dy: min(0, (bounds.height - minimumSide) / 2)
        )
        return target.contains(point)
    }

    /// Reports the same 44-point target to assistive technology, so the
    /// VoiceOver cursor and Switch Control match the touch area.
    override var accessibilityFrame: CGRect {
        get {
            let frame = super.accessibilityFrame
            let minimumSide = MapChromeLayout.controlSize
            return frame.insetBy(
                dx: min(0, (frame.width - minimumSide) / 2),
                dy: min(0, (frame.height - minimumSide) / 2)
            )
        }
        set { super.accessibilityFrame = newValue }
    }
}

/// A hall badge drawn by SpriteKit, exposed to VoiceOver as a button.
final class MapVenueAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

extension UnifiedMapHostView: MLNMapViewDelegate {
    nonisolated func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
        Task { @MainActor [weak self] in
            self?.setBasemapState(.ready)
        }
    }

    nonisolated func mapViewDidFinishRenderingMap(
        _ mapView: MLNMapView,
        fullyRendered: Bool
    ) {
        // Partial renders happen while tiles stream in; only a full render
        // proves the street tiles are reachable.
        guard fullyRendered else { return }
        Task { @MainActor [weak self] in
            self?.setBasemapState(.ready)
        }
    }

    nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.setBasemapState(.unavailable)
        }
    }
}

/// A compact material chip for passive map status text. It never intercepts
/// touches, so the map stays fully interactive underneath it.
///
/// It is floating map chrome: a capsule while the text fits on one line, and
/// a `Radius.panel` rounded rectangle when the text wraps.
final class MapStatusChip: UIView {
    private let effectView = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemMaterial)
    )
    private let label = UILabel()

    var text: String {
        get { label.text ?? "" }
        set {
            label.text = newValue
            accessibilityLabel = newValue
            setNeedsLayout()
        }
    }

    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.layer.cornerCurve = .continuous
        effectView.layer.borderWidth = 0.5
        effectView.clipsToBounds = true
        addSubview(effectView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        // A status sentence wraps fully; it never truncates.
        label.numberOfLines = 0
        effectView.contentView.addSubview(label)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(
                equalTo: effectView.contentView.leadingAnchor, constant: Spacing.medium),
            label.trailingAnchor.constraint(
                equalTo: effectView.contentView.trailingAnchor, constant: -Spacing.medium),
            label.topAnchor.constraint(
                equalTo: effectView.contentView.topAnchor, constant: Spacing.small),
            label.bottomAnchor.constraint(
                equalTo: effectView.contentView.bottomAnchor, constant: -Spacing.small),
        ])
        self.text = text
        updateBorderColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (chip: MapStatusChip, _: UITraitCollection) in
            chip.updateBorderColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Measured from the chip's own height, which is final here; the
        // label inside the effect view may not have its frame yet.
        let isSingleLine = bounds.height < label.font.lineHeight * 1.5 + Spacing.small * 2
        effectView.layer.cornerRadius =
            isSingleLine ? bounds.height / 2 : min(Radius.panel, bounds.height / 2)
    }

    private func updateBorderColor() {
        // `Color.hairline` in UIKit form: separator at 24 % opacity.
        effectView.layer.borderColor =
            UIColor.separator.withAlphaComponent(0.24)
            .resolvedColor(with: traitCollection).cgColor
    }
}

struct UnifiedBasemapCamera: Equatable {
    let coordinate: CLLocationCoordinate2D
    let zoomLevel: Double
    let direction: CLLocationDirection

    static func == (lhs: Self, rhs: Self) -> Bool {
        abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 0.000_000_01
            && abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 0.000_000_01
            && abs(lhs.zoomLevel - rhs.zoomLevel) < 0.000_1
            && abs(lhs.direction - rhs.direction) < 0.001
    }

    static func zoomLevel(metersPerPoint: CGFloat, latitude: Double) -> Double {
        let earthCircumference = 2 * Double.pi * 6_378_137
        let latitudeScale = max(cos(latitude * .pi / 180), 0.01)
        let resolution = max(Double(metersPerPoint), 0.000_001)
        return log2(latitudeScale * earthCircumference / (512 * resolution))
    }
}

enum UnifiedMapProjection {
    static func scenePoint(fromCampus point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: -point.y)
    }

    static func campusPoint(fromScene point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: -point.y)
    }

    static func sceneTransform(for venue: BigSightVenuePlacement) -> CGAffineTransform {
        let transform = venue.transform
        return CGAffineTransform(
            a: transform.a,
            b: -transform.b,
            c: transform.c,
            d: -transform.d,
            tx: transform.tx,
            ty: -transform.ty
        )
    }

    static func sceneBounds(fromCampus rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }
}

enum UnifiedMapLevelOfDetail {
    static func opacity(
        at zoom: CGFloat,
        minimumZoom: CGFloat,
        maximumZoom: CGFloat,
        fadeSpan: CGFloat = 1
    ) -> CGFloat {
        guard maximumZoom > minimumZoom,
            zoom >= minimumZoom,
            zoom <= maximumZoom
        else { return 0 }

        let availableSpan = maximumZoom - minimumZoom
        let span = min(max(fadeSpan, 0.001), availableSpan / 2)
        let fadeIn =
            minimumZoom <= 0
            ? 1
            : smoothstep((zoom - minimumZoom) / span)
        let fadeOut = smoothstep((maximumZoom - zoom) / span)
        return min(fadeIn, fadeOut)
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

@MainActor
final class MapCompassButton: UIButton {
    /// The same material as the SwiftUI location buttons (`.regularMaterial`),
    /// so the bottom control row reads as one set of floating chrome.
    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let indicatorView = UIView(frame: .zero)
    private let northNeedleLayer = CAShapeLayer()
    private let southNeedleLayer = CAShapeLayer()
    private let centerCapLayer = CAShapeLayer()
    private(set) var indicatorRotation: CGFloat = 0
    private(set) var isGridAligned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        materialView.isUserInteractionEnabled = false
        materialView.clipsToBounds = true
        insertSubview(materialView, at: 0)
        indicatorView.isUserInteractionEnabled = false
        indicatorView.layer.addSublayer(southNeedleLayer)
        indicatorView.layer.addSublayer(northNeedleLayer)
        indicatorView.layer.addSublayer(centerCapLayer)
        addSubview(indicatorView)
        layer.cornerRadius = MapChromeLayout.controlSize / 2
        layer.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateIndicator(rotation: CGFloat) {
        indicatorRotation = rotation
        indicatorView.transform = CGAffineTransform(rotationAngle: rotation)
    }

    func updateIndicatorColor(_ color: UIColor, isGridAligned: Bool) {
        self.isGridAligned = isGridAligned
        let accentColor = UIColor(named: "AccentColor") ?? color
        northNeedleLayer.fillColor = UIColor.systemRed.cgColor
        southNeedleLayer.fillColor = (
            isGridAligned ? accentColor : color.withAlphaComponent(0.72)
        ).cgColor
        centerCapLayer.fillColor = UIColor.systemBackground.cgColor
        // `Color.hairline` in UIKit form: separator at 24 % opacity.
        layer.borderColor = (
            isGridAligned
                ? accentColor.withAlphaComponent(0.58)
                : UIColor.separator.withAlphaComponent(0.24)
        ).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialView.frame = bounds
        materialView.layer.cornerRadius = bounds.height / 2
        sendSubviewToBack(materialView)
        bringSubviewToFront(indicatorView)
        indicatorView.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        indicatorView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        indicatorView.transform = CGAffineTransform(rotationAngle: indicatorRotation)
        for layer in [northNeedleLayer, southNeedleLayer, centerCapLayer] {
            layer.frame = indicatorView.bounds
        }

        let center = CGPoint(x: indicatorView.bounds.midX, y: indicatorView.bounds.midY)
        northNeedleLayer.path = needlePath(
            tip: CGPoint(x: center.x, y: 1),
            center: center
        ).cgPath
        southNeedleLayer.path = needlePath(
            tip: CGPoint(x: center.x, y: 29),
            center: center
        ).cgPath
        centerCapLayer.path = UIBezierPath(
            ovalIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
        ).cgPath
    }

    var indicatedNorthVector: CGVector {
        CGVector(dx: sin(indicatorRotation), dy: -cos(indicatorRotation))
    }

    var usesTwoToneNeedle: Bool {
        northNeedleLayer.fillColor != nil && southNeedleLayer.fillColor != nil
    }

    private func needlePath(tip: CGPoint, center: CGPoint) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x - 4.5, y: center.y))
        path.addLine(to: center)
        path.addLine(to: CGPoint(x: center.x + 4.5, y: center.y))
        path.close()
        return path
    }
}

enum UnifiedMapMarkerMetrics {
    static let venueIconSize: CGFloat = 32
    /// Facility titles wrap to two lines at this width instead of running
    /// off the screen. About 18 characters of 11 pt text per line.
    static let facilityLabelMaxWidth: CGFloat = 120
    /// Gap between a marker backing and its title.
    static let labelClearance: CGFloat = Spacing.xSmall
    /// Distance by which the halo extends past the outline of map text,
    /// in points.
    static let labelHaloWidth: CGFloat = 1.5

    // Shared by the SpriteKit badge and `BigSightVenueBadge`, so the two
    // renderers keep one shape.
    static let venueBadgeCornerRatio: CGFloat = 0.24
    static let venueBadgePlateInsetRatio: CGFloat = 0.075

    static func venueBadgeCornerRadius(side: CGFloat) -> CGFloat {
        side * venueBadgeCornerRatio
    }

    static func venueBadgePlateInset(side: CGFloat) -> CGFloat {
        side * venueBadgePlateInsetRatio
    }

    /// Concentric with the outer corner. `Radius.concentric` is not used
    /// because it clamps to 6 pt, and small badges scale below that.
    static func venueBadgePlateRadius(side: CGFloat) -> CGFloat {
        venueBadgeCornerRadius(side: side) - venueBadgePlateInset(side: side)
    }

    static func facilityIconSize(for kind: BigSightFacilityLocation.Kind) -> CGFloat {
        kind == .conferenceTower ? 22 : 18
    }

    static func backingSize(for icon: BigSightMapIcon, iconSize: CGFloat) -> CGFloat {
        iconSize + (icon.venueBadge == nil ? 6 : 10)
    }

    /// The rounded bold face of every map title.
    static func titleFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: size) } ?? base
    }

    static func titleWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: titleFont(size: fontSize)]).width)
    }

    /// A facility title laid out for at most two lines of `maxWidth`.
    ///
    /// A title that fits stays on one line. A longer title breaks at the word
    /// boundary that gives the two most equal lines, so "エントランスプラザ喫煙所"
    /// becomes "エントランスプラザ / 喫煙所", never "エントランスプラ / ザ喫煙所".
    /// The returned text holds the break as "\n", and `width` is the wrap
    /// width that keeps both lines whole. `nil` means that no word boundary
    /// gives two lines that fit: the map then shows the icon without a title.
    static func facilityTitle(
        _ text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat
    ) -> (text: String, width: CGFloat)? {
        guard !text.isEmpty else { return (text, maxWidth) }
        if titleWidth(text, fontSize: fontSize) <= maxWidth {
            return (text, maxWidth)
        }
        // ICU word boundaries also split Japanese and Chinese into words.
        var wordStarts: [String.Index] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            if range.lowerBound > text.startIndex {
                wordStarts.append(range.lowerBound)
            }
        }
        var best: (text: String, width: CGFloat)?
        for index in wordStarts {
            let first = text[..<index].trimmingCharacters(in: .whitespaces)
            let second = text[index...].trimmingCharacters(in: .whitespaces)
            guard !first.isEmpty, !second.isEmpty else { continue }
            let width = max(
                titleWidth(first, fontSize: fontSize),
                titleWidth(second, fontSize: fontSize)
            )
            guard width <= maxWidth else { continue }
            if best.map({ width < $0.width }) ?? true {
                best = ("\(first)\n\(second)", width)
            }
        }
        // One point of slack, so rounding never wraps a line a second time.
        return best.map { ($0.text, $0.width + 1) }
    }
}

@MainActor
final class UnifiedBigSightScene: SKScene {
    enum Hit {
        case userLocation
        case venue(BigSightVenuePlacement)
        case table(CatalogMapTable, Int)
    }

    struct LocationHit {
        let mapID: Int
        let localPoint: CGPoint
        let table: CatalogMapTable
        let subspace: Int
    }

    private struct ScreenSpaceMarker {
        let id: String
        let node: SKNode
        let label: SKLabelNode
        let layer: BigSightMapLayer?
        let minimumZoom: CGFloat
        let labelMinimumZoom: CGFloat
        let maximumZoom: CGFloat
        /// Side of the square or round backing, in screen points.
        let badgeSize: CGFloat
        let venueID: Int?
        /// Lower values claim screen space first: halls, then gates and
        /// help points, then food and restrooms, then everything else.
        let priority: Int
    }

    /// The on-screen footprint of a hall badge and its title, in the SKView's
    /// coordinate space.
    struct VenueBadgeTarget: Equatable {
        let venueID: Int
        let title: String
        let frame: CGRect
    }

    private static let darkArtworkShader = SKShader(
        source: """
            void main() {
                vec4 source = texture2D(u_texture, v_tex_coord);
                float luminance = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
                float targetLuminance = clamp(0.86 - luminance * 0.78, 0.08, 0.86);
                vec3 hue = luminance > 0.005 ? source.rgb / luminance : vec3(1.0);
                vec3 darkColor = clamp(hue * targetLuminance, 0.0, 1.0);
                gl_FragColor = vec4(darkColor, source.a) * v_color_mix;
            }
            """)

    private(set) var scope: MapScreenModel.Scope = .campus
    private(set) var selectedMapID: Int?
    var onViewportChange: ((CatalogMapViewport) -> Void)?
    var onCameraChange: (() -> Void)?
    var onSemanticScopeChange: ((MapScreenModel.Scope, Int?) -> Void)?
    var reduceMotion = false

    private var campus: BigSightCampusScene
    private var appearance: UnifiedMapAppearance
    private let mapCamera = SKCameraNode()
    private let staticRoot = SKNode()
    private let campusDetailRoot = SKNode()
    private let pedestrianRoot = SKNode()
    private let markerRoot = SKNode()
    private let venueRoot = SKNode()
    private let tableRoot = SKNode()
    private let blockLabelRoot = SKNode()
    private let tableLabelRoot = SKNode()
    private let genreRoot = SKNode()
    private let dynamicRoot = SKNode()
    private let destinationRoot = SKNode()
    private let userRoot = SKNode()
    private var venueMarkers: [ScreenSpaceMarker] = []
    private var facilityMarkers: [ScreenSpaceMarker] = []
    private var blockLabels: [SKLabelNode] = []
    private var minimumCameraScale: CGFloat = 1
    private var maximumCameraScale: CGFloat = 0.01
    private var hasFittedInitialCamera = false
    /// True while the camera still shows the fitted campus overview. A size
    /// change then fits the overview again; after any pan, zoom, rotation,
    /// or focus, the user's camera stays where it is.
    private var isShowingOverviewFit = false
    private var overviewInsets: MapViewportInsets?
    private var lastCameraFitRequestID: UUID?
    /// The overview never opens closer than this, so it stays clear of the
    /// 2.4x threshold at which the campus drills into a hall.
    private static let maximumOverviewZoomFactor: CGFloat = 2
    private var lastCameraPosition = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var lastCameraScale: CGFloat = .infinity
    private var lastCameraRotation: CGFloat = .infinity
    private var viewportWorkItem: DispatchWorkItem?
    private var requestedScopeInternally = false
    private var lastDynamicFingerprint: Int?
    private var lastRenderedLocatedUser: LocatedMapUser?
    private var artworkCount = 0
    private var favoriteCount = 0
    private var primarySharedPlanCircleCount = 0
    private var locatedUserSummary: String?
    private var locatedUserHeading: Double?
    private var destinationSummary: String?
    private var lastLocatedUserPlacedAt: Date?
    private var lastDestinationSelectedAt: Date?
    private var locationFocusBottomInset: CGFloat = 0
    private var visibleMapLayers = BigSightMapLayer.defaultVisible
    private var isSearchActive = false
    /// Halls that contain at least one search match. Their badges stay at
    /// full opacity in search mode; the other halls dim.
    private var searchMatchedVenueIDs: Set<Int> = []
    /// Opacity of the floor plans while search highlights are shown. High
    /// enough that hall outlines stay readable around the matches.
    private static let searchBaseMapAlpha: CGFloat = 0.5
    /// Opacity of a hall badge with no search match.
    private static let searchUnmatchedVenueAlpha: CGFloat = 0.35

    var cameraRotation: CGFloat { mapCamera.zRotation }
    var gridAlignedCameraRotation: CGFloat { campus.gridAlignedCameraRotation }
    var cameraCampusCenter: CGPoint {
        UnifiedMapProjection.campusPoint(fromScene: mapCamera.position)
    }
    var cameraMetersPerPoint: CGFloat { mapCamera.xScale }
    var basemapCamera: UnifiedBasemapCamera {
        let campusPoint = cameraCampusCenter
        let coordinate = BigSightCampusLayout.coordinate(from: campusPoint)
        let rawDirection = -Double(normalizedRotation(mapCamera.zRotation) * 180 / .pi)
        let direction = (rawDirection.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return UnifiedBasemapCamera(
            coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            zoomLevel: UnifiedBasemapCamera.zoomLevel(
                metersPerPoint: mapCamera.xScale,
                latitude: coordinate.latitude
            ),
            direction: direction
        )
    }
    var zoomFactor: CGFloat { minimumCameraScale / max(mapCamera.xScale, 0.000_1) }
    var staticShapeNodeCount: Int { staticRoot.descendants(of: SKShapeNode.self).count }
    var authoredMapNodeCount: Int { venueRoot.children.compactMap { $0 as? SKSpriteNode }.count }
    var openStreetMapFeatureNodeCount: Int {
        pedestrianRoot.children.filter {
            $0.name?.hasPrefix("openstreetmap-feature-") == true
        }.count
    }
    var darkArtworkNodeCount: Int {
        venueRoot.children.compactMap { $0 as? SKSpriteNode }.filter { $0.shader != nil }.count
    }
    var venueMarkerCount: Int { venueMarkers.count }
    var facilityMarkerCount: Int { facilityMarkers.count }
    var visibleFacilityMarkerCount: Int {
        facilityMarkers.filter { !$0.node.isHidden }.count
    }
    var isPersistentOverlayVisible: Bool { !dynamicRoot.isHidden }
    var persistentOverlayShapeCount: Int {
        dynamicRoot.children.compactMap { $0 as? SKShapeNode }.count
    }
    var baseMapAlpha: CGFloat { staticRoot.alpha }
    var isSearchModeActive: Bool { isSearchActive }
    /// Search mode hides the facility icons. Hall badges stay visible so the
    /// user can still see where each match is.
    var areMapIconsHiddenForSearch: Bool {
        isSearchActive && facilityMarkers.allSatisfy(\.node.isHidden)
    }
    func isFacilityMarkerVisible(id: String) -> Bool {
        facilityMarkers.first(where: { $0.id == id }).map { !$0.node.isHidden } ?? false
    }
    func updateVisibleMapLayers(_ layers: Set<BigSightMapLayer>) {
        visibleMapLayers = layers
        applyLevelOfDetail()
    }
    var generatedBlockLabelCount: Int { blockLabels.count }
    var venueMarkerOpacities: [CGFloat] { venueMarkers.map(\.node.alpha) }
    var venueMarkerRotations: [CGFloat] { venueMarkers.map(\.node.zRotation) }
    var blockLabelRotations: [CGFloat] { blockLabels.map(\.zRotation) }
    func venueMarkerScreenRightVectors(in view: SKView) -> [CGVector] {
        venueMarkers.map { marker in
            let center = convertPoint(
                toView: marker.node.convert(.zero, to: self)
            )
            let right = convertPoint(
                toView: marker.node.convert(CGPoint(x: 1, y: 0), to: self)
            )
            return CGVector(dx: right.x - center.x, dy: right.y - center.y)
        }
    }
    var circleArtworkNodes: [SKSpriteNode] {
        dynamicRoot.children.compactMap { node in
            guard let sprite = node as? SKSpriteNode,
                sprite.name?.hasPrefix("circle-artwork-") == true
            else { return nil }
            return sprite
        }
    }
    var genreOverlayNodeCount: Int { genreRoot.children.count }
    var isGenreOverlayVisible: Bool {
        genreOverlayNodeCount > 0 && !genreRoot.isHidden && genreRoot.alpha > 0
    }
    var userMarkerCount: Int { userRoot.children.count }
    private(set) var dynamicOverlayRebuildCount = 0
    var destinationMarkerCount: Int {
        destinationRoot.children.filter { $0.name == "map-destination-marker" }.count
    }
    var userHeadingIndicatorCount: Int {
        userRoot.children.filter {
            $0.childNode(withName: "located-user-heading") != nil
        }.count
    }
    var userHeadingIndicatorRotation: CGFloat? {
        userRoot.childNode(withName: "located-user-marker")?
            .childNode(withName: "located-user-heading")?
            .zRotation
    }

    var accessibilitySummary: String {
        let zoom = Double(zoomFactor).formatted(.number.precision(.fractionLength(1)))
        var summary: String
        if scope == .campus {
            summary = String(
                localized:
                    "\(campus.venues.count) venues and \(campus.facilities.count) facilities, zoom \(zoom) times"
            )
        } else {
            summary = String(
                localized:
                    "Zoom \(zoom) times, \(artworkCount) circle images, \(favoriteCount) favorites, \(primarySharedPlanCircleCount) primary plan circles"
            )
        }
        if let locatedUserSummary {
            summary = String(localized: "\(summary), user location \(locatedUserSummary)")
        }
        if let destinationSummary {
            summary = String(localized: "\(summary), destination \(destinationSummary)")
        }
        #if DEBUG
            // Raw camera numbers mean nothing to a VoiceOver user. UI tests
            // opt in to them explicitly to observe camera changes.
            if ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-map-diagnostics") {
                let bearing = Double(normalizedRotation(mapCamera.zRotation) * 180 / .pi)
                    .formatted(.number.precision(.fractionLength(1)))
                var debugSummary =
                    "\(summary), camera offset \(mapCamera.position.x) \(mapCamera.position.y), bearing \(bearing) degrees"
                if let locatedUserHeading {
                    debugSummary += ", user heading \(Int(locatedUserHeading.rounded())) degrees"
                }
                return debugSummary
            }
        #endif
        return summary
    }

    init(campus: BigSightCampusScene, appearance: UnifiedMapAppearance = .light) {
        self.campus = campus
        self.appearance = appearance
        super.init(size: CGSize(width: 390, height: 844))
        scaleMode = .resizeFill
        backgroundColor = .clear
        camera = mapCamera
        addChild(mapCamera)
        addChild(staticRoot)
        staticRoot.addChild(campusDetailRoot)
        staticRoot.addChild(venueRoot)
        staticRoot.addChild(tableRoot)
        staticRoot.addChild(blockLabelRoot)
        addChild(tableLabelRoot)
        addChild(genreRoot)
        addChild(dynamicRoot)
        destinationRoot.zPosition = 90
        addChild(destinationRoot)
        userRoot.zPosition = 100
        addChild(userRoot)
        buildStaticScene()
    }

    func updateAppearance(_ appearance: UnifiedMapAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        lastDynamicFingerprint = nil
        buildStaticScene()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        fitCameraIfNeeded(force: !hasFittedInitialCamera)
    }

    override func didFinishUpdate() {
        super.didFinishUpdate()
        publishCameraChangeIfNeeded()
    }

    private func publishCameraChangeIfNeeded() {
        guard
            mapCamera.position != lastCameraPosition
                || mapCamera.xScale != lastCameraScale
                || mapCamera.zRotation != lastCameraRotation
        else { return }
        clampCamera()
        applyLevelOfDetail()
        lastCameraPosition = mapCamera.position
        lastCameraScale = mapCamera.xScale
        lastCameraRotation = mapCamera.zRotation
        onCameraChange?()
    }

    func update(
        campus: BigSightCampusScene,
        scope: MapScreenModel.Scope,
        selectedMapID: Int,
        selectedTableID: CatalogMapTable.ID?,
        circlePlacements: [CatalogMapCirclePlacement],
        circleArtwork: [Int: CGImage],
        searchMatches: [CatalogMapSearchMatch],
        searchActive: Bool,
        genrePlacements: [CatalogMapGenrePlacement],
        bookmarks: [MapBookmark],
        primarySharedPlanCircles: [CatalogBookmarkLocation] = [],
        locatedUser: LocatedMapUser?,
        destination: MapDestination? = nil,
        visibleMapLayers: Set<BigSightMapLayer> = BigSightMapLayer.defaultVisible,
        locationFocusBottomInset: CGFloat = 0,
        overviewInsets: MapViewportInsets? = nil,
        cameraFitRequest: MapCameraFitRequest? = nil
    ) {
        if overviewInsets != self.overviewInsets {
            self.overviewInsets = overviewInsets
            if hasFittedInitialCamera, isShowingOverviewFit, self.scope == .campus {
                focusCampus(animated: false)
            }
        }
        if self.campus.id != campus.id {
            self.campus = campus
            lastDynamicFingerprint = nil
            lastRenderedLocatedUser = nil
            buildStaticScene()
            hasFittedInitialCamera = false
            fitCameraIfNeeded(force: true)
        }

        let previousScope = self.scope
        let previousMapID = self.selectedMapID
        let sanitizedFocusInset = max(0, locationFocusBottomInset)
        let didFocusViewportChange =
            sanitizedFocusInset > 0
            && abs(sanitizedFocusInset - self.locationFocusBottomInset) > 0.5
        self.locationFocusBottomInset = sanitizedFocusInset
        let shouldFocusLocatedUser =
            locatedUser?.placedAt != lastLocatedUserPlacedAt
            || didFocusViewportChange
        let shouldFocusDestination = destination?.selectedAt != lastDestinationSelectedAt
        self.scope = scope
        self.selectedMapID = scope == .venue ? selectedMapID : nil
        self.visibleMapLayers = visibleMapLayers
        isSearchActive = searchActive
        searchMatchedVenueIDs = searchActive ? Set(searchMatches.map(\.mapID)) : []
        applyLevelOfDetail()
        artworkCount = circleArtwork.count
        favoriteCount = bookmarks.count
        primarySharedPlanCircleCount = primarySharedPlanCircles.count
        locatedUserSummary = locatedUser?.spaceCode
        locatedUserHeading = locatedUser?.headingDegrees
        destinationSummary = destination?.spaceCode

        if requestedScopeInternally {
            requestedScopeInternally = false
        } else if scope != previousScope || self.selectedMapID != previousMapID {
            if scope == .campus {
                focusCampus(animated: true)
            } else {
                focusVenue(mapID: selectedMapID, animated: true)
            }
        }

        let fingerprint = dynamicFingerprint(
            selectedTableID: selectedTableID,
            placements: circlePlacements,
            artwork: circleArtwork,
            matches: searchMatches,
            searchActive: searchActive,
            genres: genrePlacements,
            bookmarks: bookmarks,
            primarySharedPlanCircles: primarySharedPlanCircles,
            locatedUser: locatedUser,
            destination: destination
        )
        if fingerprint != lastDynamicFingerprint {
            lastDynamicFingerprint = fingerprint
            rebuildDynamicOverlay(
                selectedTableID: selectedTableID,
                circlePlacements: circlePlacements,
                circleArtwork: circleArtwork,
                searchMatches: searchMatches,
                searchActive: searchActive,
                genrePlacements: genrePlacements,
                bookmarks: bookmarks,
                primarySharedPlanCircles: primarySharedPlanCircles,
                locatedUser: locatedUser,
                destination: destination
            )
            lastRenderedLocatedUser = locatedUser
        } else if locatedUser != lastRenderedLocatedUser {
            rebuildUserOverlay(locatedUser)
            lastRenderedLocatedUser = locatedUser
        }
        lastLocatedUserPlacedAt = locatedUser?.placedAt
        lastDestinationSelectedAt = destination?.selectedAt
        if shouldFocusDestination, let destination {
            focus(on: destination, animated: true)
        } else if shouldFocusLocatedUser, let locatedUser {
            focus(on: locatedUser, animated: true)
        }
        if let cameraFitRequest, cameraFitRequest.id != lastCameraFitRequestID {
            lastCameraFitRequestID = cameraFitRequest.id
            fitCamera(to: cameraFitRequest.target, searchMatches: searchMatches)
        }
    }

    func beginGesture() {
        isShowingOverviewFit = false
        mapCamera.removeAllActions()
    }

    func pan(by translation: CGPoint, in view: SKView) {
        guard translation != .zero else { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let before = convertPoint(fromView: center)
        let after = convertPoint(
            fromView: CGPoint(
                x: center.x + translation.x,
                y: center.y + translation.y
            ))
        mapCamera.position.x -= after.x - before.x
        mapCamera.position.y -= after.y - before.y
        clampCamera()
    }

    func endPan(velocity: CGPoint, in view: SKView) {
        let projected = CGPoint(
            x: max(-1_800, min(1_800, velocity.x)) * 0.16,
            y: max(-1_800, min(1_800, velocity.y)) * 0.16
        )
        let original = mapCamera.position
        pan(by: projected, in: view)
        let target = mapCamera.position
        mapCamera.position = original
        let action = SKAction.move(to: target, duration: reduceMotion ? 0 : 0.34)
        action.timingMode = .easeOut
        mapCamera.run(action) { [weak self] in self?.endGesture() }
    }

    func zoom(by scale: CGFloat, around viewPoint: CGPoint, in view: SKView) {
        guard scale.isFinite, scale > 0, scale != 1 else { return }
        let before = convertPoint(fromView: viewPoint)
        let target = max(maximumCameraScale, min(minimumCameraScale, mapCamera.xScale / scale))
        mapCamera.setScale(target)
        let after = convertPoint(fromView: viewPoint)
        mapCamera.position.x += before.x - after.x
        mapCamera.position.y += before.y - after.y
        clampCamera()
    }

    func rotate(by angle: CGFloat, around viewPoint: CGPoint, in view: SKView) {
        guard angle.isFinite, angle != 0 else { return }
        let before = convertPoint(fromView: viewPoint)
        // UIKit reports a positive rotation for a clockwise twist in its
        // top-left coordinate system. Applying that delta directly to the
        // SpriteKit camera keeps the map content under the user's fingers.
        mapCamera.zRotation = normalizedRotation(mapCamera.zRotation + angle)
        let after = convertPoint(fromView: viewPoint)
        mapCamera.position.x += before.x - after.x
        mapCamera.position.y += before.y - after.y
        clampCamera()
    }

    func animatedZoom(by scale: CGFloat, around viewPoint: CGPoint, in view: SKView) {
        beginGesture()
        let startPosition = mapCamera.position
        let startScale = mapCamera.xScale
        zoom(by: scale, around: viewPoint, in: view)
        let targetPosition = mapCamera.position
        let targetScale = mapCamera.xScale
        mapCamera.position = startPosition
        mapCamera.setScale(startScale)
        let duration = reduceMotion ? 0 : 0.24
        let group = SKAction.group([
            SKAction.move(to: targetPosition, duration: duration),
            SKAction.scale(to: targetScale, duration: duration),
        ])
        group.timingMode = .easeOut
        mapCamera.run(group) { [weak self] in self?.endGesture() }
    }

    func advanceCompassRotation() {
        let targetRotation = MapCameraMath.compassTargetRotation(
            currentRotation: mapCamera.zRotation,
            gridAlignedRotation: gridAlignedCameraRotation
        )
        mapCamera.removeAction(forKey: "compass-rotation")
        isShowingOverviewFit = false

        if reduceMotion {
            mapCamera.zRotation = targetRotation
            endGesture()
            return
        }

        let action = SKAction.rotate(
            toAngle: targetRotation,
            duration: 0.22,
            shortestUnitArc: true
        )
        action.timingMode = .easeOut
        let commitRotation = SKAction.run { [weak self] in
            guard let self else { return }
            // SpriteKit can finish the shortest-arc animation with a tiny
            // remainder. Commit the exact target so the map, compass color,
            // and accessibility state all agree after the transition.
            self.mapCamera.zRotation = targetRotation
            self.endGesture()
        }
        mapCamera.run(
            .sequence([action, commitRotation]),
            withKey: "compass-rotation"
        )
    }

    func endGesture(updateSemanticScope shouldUpdateSemanticScope: Bool = true) {
        clampCamera()
        refreshVisibleTableLabels()
        scheduleViewportUpdate(immediate: true)
        if shouldUpdateSemanticScope {
            updateSemanticScope()
        }
        // A zero-duration reduced-motion transition completes before
        // SpriteKit's next frame. Publish its final state now so compass
        // appearance and accessibility never remain one frame behind.
        publishCameraChangeIfNeeded()
    }

    func requestVenue(_ mapID: Int) {
        requestedScopeInternally = true
        scope = .venue
        selectedMapID = mapID
        focusVenue(mapID: mapID, animated: true)
    }

    func hit(at viewPoint: CGPoint, in view: SKView, prefersTable: Bool = false) -> Hit? {
        if isUserMarker(at: viewPoint, in: view) {
            return .userLocation
        }
        for (venue, local) in venueHits(at: viewPoint, in: view) {
            let isSelectedVenue = scope == .venue && venue.id == selectedMapID
            if prefersTable || (isSelectedVenue && zoomFactor >= 12),
                let table = venue.scene.tables.first(where: {
                    CGRect(origin: $0.origin, size: venue.scene.tableSize).contains(local)
                })
            {
                return .table(table, subspace(at: local, table: table, scene: venue.scene))
            }
            // Once a venue is open, empty-space taps should not unexpectedly
            // zoom all the way back out to its fitted bounds.
            if isSelectedVenue {
                return nil
            }
            return .venue(venue)
        }
        return nil
    }

    func userMarkerViewPoint(in view: SKView) -> CGPoint? {
        guard let marker = userRoot.childNode(withName: "located-user-marker") else { return nil }
        return convertPoint(toView: marker.convert(.zero, to: self))
    }

    private func isUserMarker(at viewPoint: CGPoint, in view: SKView) -> Bool {
        guard let markerViewPoint = userMarkerViewPoint(in: view) else { return false }
        return hypot(viewPoint.x - markerViewPoint.x, viewPoint.y - markerViewPoint.y) <= 28
    }

    func locationHit(at viewPoint: CGPoint, in view: SKView) -> LocationHit? {
        for (venue, localPoint) in venueHits(at: viewPoint, in: view) {
            guard
                let table = WhereAmIResolver.nearestTable(
                    to: localPoint,
                    in: venue.scene
                )
            else { continue }

            return LocationHit(
                mapID: venue.id,
                localPoint: localPoint,
                table: table,
                subspace: WhereAmIResolver.subspace(
                    at: localPoint,
                    in: table,
                    scene: venue.scene
                )
            )
        }
        return nil
    }

    private func venueHits(
        at viewPoint: CGPoint,
        in view: SKView
    ) -> [(venue: BigSightVenuePlacement, localPoint: CGPoint)] {
        let scenePoint = convertPoint(fromView: viewPoint)
        let campusPoint = UnifiedMapProjection.campusPoint(fromScene: scenePoint)
        return campus.venues
            .sorted { lhs, rhs in
                lhs.id == selectedMapID && rhs.id != selectedMapID
            }
            .compactMap { venue in
                let localPoint = campusPoint.applying(venue.transform.inverted())
                guard CGRect(origin: .zero, size: venue.scene.size).contains(localPoint) else {
                    return nil
                }
                return (venue, localPoint)
            }
    }

    func viewPoint(forCampus campusPoint: CGPoint, in view: SKView) -> CGPoint {
        convertPoint(
            toView: UnifiedMapProjection.scenePoint(fromCampus: campusPoint)
        )
    }

    private var selectedVenue: BigSightVenuePlacement? {
        guard let selectedMapID else { return nil }
        return campus.venues.first(where: { $0.id == selectedMapID })
    }

    private func buildStaticScene() {
        let palette = appearance.palette
        staticRoot.removeAllChildren()
        campusDetailRoot.removeAllChildren()
        pedestrianRoot.removeAllChildren()
        markerRoot.removeAllChildren()
        venueRoot.removeAllChildren()
        tableRoot.removeAllChildren()
        blockLabelRoot.removeAllChildren()
        tableLabelRoot.removeAllChildren()
        venueMarkers = []
        facilityMarkers = []
        blockLabels = []
        staticRoot.addChild(campusDetailRoot)
        staticRoot.addChild(pedestrianRoot)
        staticRoot.addChild(markerRoot)
        staticRoot.addChild(venueRoot)
        staticRoot.addChild(tableRoot)
        staticRoot.addChild(blockLabelRoot)

        let sceneBounds = UnifiedMapProjection.sceneBounds(fromCampus: campus.bounds)
        let grid = CGMutablePath()
        let spacing: CGFloat = 100
        let minX = floor(sceneBounds.minX / spacing) * spacing
        let maxX = ceil(sceneBounds.maxX / spacing) * spacing
        let minY = floor(sceneBounds.minY / spacing) * spacing
        let maxY = ceil(sceneBounds.maxY / spacing) * spacing
        for x in stride(from: minX, through: maxX, by: spacing) {
            grid.move(to: CGPoint(x: x, y: minY))
            grid.addLine(to: CGPoint(x: x, y: maxY))
        }
        for y in stride(from: minY, through: maxY, by: spacing) {
            grid.move(to: CGPoint(x: minX, y: y))
            grid.addLine(to: CGPoint(x: maxX, y: y))
        }
        let gridNode = SKShapeNode(path: grid)
        gridNode.strokeColor = palette.grid
        gridNode.lineWidth = 1
        gridNode.zPosition = -20
        campusDetailRoot.addChild(gridNode)

        for feature in campus.openStreetMapFeatures where feature.points.count > 1 {
            let path = CGMutablePath()
            path.move(to: UnifiedMapProjection.scenePoint(fromCampus: feature.points[0]))
            for point in feature.points.dropFirst() {
                path.addLine(to: UnifiedMapProjection.scenePoint(fromCampus: point))
            }

            switch feature.kind {
            case .connectingBridge:
                path.closeSubpath()
                let shape = SKShapeNode(path: path)
                shape.name = "openstreetmap-feature-\(feature.id)"
                shape.fillColor = palette.bridgeFill
                shape.strokeColor = palette.bridgeStroke
                shape.lineWidth = 1.1
                shape.lineJoin = .round
                shape.isAntialiased = true
                shape.zPosition = -3
                pedestrianRoot.addChild(shape)

            case .footway, .steps:
                let underlay = SKShapeNode(path: path)
                underlay.strokeColor = palette.pedestrianUnderlay
                underlay.lineWidth = feature.isIndoor || feature.isCovered ? 3.4 : 2.8
                underlay.lineCap = .round
                underlay.lineJoin = .round
                underlay.isAntialiased = true
                underlay.zPosition = -2.5
                pedestrianRoot.addChild(underlay)

                let renderedPath: CGPath
                if feature.kind == .steps {
                    renderedPath = path.copy(
                        dashingWithPhase: 0,
                        lengths: [1.4, 1.1]
                    )
                } else {
                    renderedPath = path
                }
                let line = SKShapeNode(path: renderedPath)
                line.name = "openstreetmap-feature-\(feature.id)"
                line.strokeColor =
                    feature.kind == .steps
                    ? palette.pedestrianSteps
                    : palette.pedestrianFootway
                line.lineWidth = feature.kind == .steps ? 1.45 : 1.25
                line.lineCap = .round
                line.lineJoin = .round
                line.isAntialiased = true
                line.zPosition = -2
                pedestrianRoot.addChild(line)
            }
        }

        for venue in campus.venues {
            buildVenue(venue)
        }
        for facility in campus.facilities {
            buildFacility(facility)
        }
        applyLevelOfDetail()
    }

    private func buildVenue(_ venue: BigSightVenuePlacement) {
        let palette = appearance.palette
        var transform = UnifiedMapProjection.sceneTransform(for: venue)
        let floorPath = CGPath(
            rect: CGRect(origin: .zero, size: venue.scene.size),
            transform: &transform
        )
        let floor = SKShapeNode(path: floorPath)
        floor.fillColor = palette.floor
        floor.strokeColor = palette.floorStroke
        floor.lineWidth = 0.8
        floor.zPosition = -5
        venueRoot.addChild(floor)

        if let artwork = venue.scene.artwork {
            let texture = SKTexture(cgImage: artwork.image)
            texture.filteringMode = .linear
            let map = SKSpriteNode(texture: texture)
            map.name = "authored-map-\(artwork.name)"
            map.position = UnifiedMapProjection.scenePoint(fromCampus: venue.center)
            map.size = CGSize(
                width: artwork.pixelSize.width * venue.metersPerMapPoint,
                height: artwork.pixelSize.height * venue.verticalMetersPerMapPoint
            )
            map.zRotation = -venue.rotation
            map.zPosition = -4
            map.shader = appearance == .dark ? Self.darkArtworkShader : nil
            venueRoot.addChild(map)
        } else {
            for (blockID, tables) in Dictionary(grouping: venue.scene.tables, by: { $0.id.blockID })
            {
                let path = CGMutablePath()
                let dividerPath = CGMutablePath()
                for table in tables {
                    let rect = CGRect(origin: table.origin, size: venue.scene.tableSize)
                    var tableTransform = transform
                    path.addPath(CGPath(rect: rect, transform: &tableTransform))
                    let divider = dividerSegment(for: rect, orientation: table.orientation)
                    let dividerTransform = transform
                    dividerPath.move(to: divider.start, transform: dividerTransform)
                    dividerPath.addLine(to: divider.end, transform: dividerTransform)
                }

                let shape = SKShapeNode(path: path)
                shape.fillColor = blockColor(blockID)
                shape.strokeColor = palette.tableStroke
                shape.lineWidth = 0.065
                shape.isAntialiased = true
                shape.zPosition = 0
                tableRoot.addChild(shape)

                let dividers = SKShapeNode(path: dividerPath)
                dividers.strokeColor = palette.tableDivider
                dividers.lineWidth = 0.04
                dividers.zPosition = 1
                tableRoot.addChild(dividers)
            }
        }

        let venueMarker = markerNode(
            icon: venue.kind.icon,
            title: venue.kind.displayName,
            at: UnifiedMapProjection.scenePoint(fromCampus: venue.center),
            iconSize: UnifiedMapMarkerMetrics.venueIconSize,
            fontSize: 13,
            titleColor: palette.venueText,
            zPosition: 20
        )
        venueMarkers.append(
            ScreenSpaceMarker(
                id: "venue-\(venue.id)",
                node: venueMarker.node,
                label: venueMarker.label,
                layer: nil,
                minimumZoom: 0,
                labelMinimumZoom: 0,
                maximumZoom: 12,
                badgeSize: UnifiedMapMarkerMetrics.backingSize(
                    for: venue.kind.icon,
                    iconSize: UnifiedMapMarkerMetrics.venueIconSize
                ),
                venueID: venue.id,
                priority: 0
            ))
        // Hall titles must stay readable where a neighboring badge overlaps
        // them, so they draw above every marker backing.
        venueMarker.label.zPosition = 30
        markerRoot.addChild(venueMarker.node)

        if venue.scene.artwork == nil {
            for block in venue.scene.blockLabels {
                let campusPoint = block.position.applying(venue.transform)
                let label = labelNode(
                    text: block.name,
                    at: UnifiedMapProjection.scenePoint(fromCampus: campusPoint),
                    fontSize: 19,
                    color: palette.blockText,
                    zPosition: 12,
                    halo: true
                )
                label.userData = NSMutableDictionary(dictionary: ["mapID": venue.id])
                blockLabels.append(label)
                blockLabelRoot.addChild(label)
            }
        }
    }

    private func buildFacility(_ facility: BigSightFacilityLocation) {
        let presentation = facilityMarkerPresentation(facility)
        let isInsideVenue = campus.venues.contains {
            $0.contains(campusPoint: facility.center)
        }
        let marker = markerNode(
            icon: facility.kind.icon,
            title: presentation.title,
            at: UnifiedMapProjection.scenePoint(fromCampus: facility.center),
            iconSize: UnifiedMapMarkerMetrics.facilityIconSize(for: facility.kind),
            fontSize: 11,
            titleColor: appearance.palette.primaryText,
            zPosition: 22,
            labelMaxWidth: UnifiedMapMarkerMetrics.facilityLabelMaxWidth
        )
        facilityMarkers.append(
            ScreenSpaceMarker(
                id: facility.id,
                node: marker.node,
                label: marker.label,
                layer: facility.layer,
                minimumZoom: facility.minimumZoom,
                labelMinimumZoom: presentation.labelMinimumZoom,
                maximumZoom: isInsideVenue ? facility.maximumZoom : .infinity,
                badgeSize: UnifiedMapMarkerMetrics.backingSize(
                    for: facility.kind.icon,
                    iconSize: UnifiedMapMarkerMetrics.facilityIconSize(for: facility.kind)
                ),
                venueID: nil,
                priority: Self.labelPriority(for: facility.kind)
            ))
        markerRoot.addChild(marker.node)
    }

    private static func labelPriority(for kind: BigSightFacilityLocation.Kind) -> Int {
        switch kind {
        case .entryGate, .information, .internationalDesk, .firstAid, .ticketExchange,
            .waitingArea, .train, .conferenceTower:
            1
        case .food, .restroom, .convenienceStore:
            2
        default:
            3
        }
    }

    private func facilityMarkerPresentation(
        _ facility: BigSightFacilityLocation
    ) -> (title: String, labelMinimumZoom: CGFloat) {
        if facility.minimumZoom >= 8 {
            switch facility.kind {
            case .restroom:
                return ("", facility.maximumZoom)
            case .information:
                return (String(localized: "Information"), 32)
            case .firstAid:
                return (String(localized: "First Aid"), 32)
            case .elevator:
                return (String(localized: "Elevator · Staff-directed"), 36)
            case .escalator:
                return (String(localized: "Escalator · Staff-directed"), 36)
            case .stairs:
                return (String(localized: "Stairs · Staff-directed"), 36)
            default:
                return (facility.name, 32)
            }
        }

        let compactTitle: String
        switch facility.kind {
        case .entryGate: compactTitle = String(localized: "Entry / Exit")
        case .waitingArea: compactTitle = String(localized: "Waiting Area")
        case .ticketExchange: compactTitle = String(localized: "Ticket Exchange")
        case .internationalDesk: compactTitle = String(localized: "International Desk")
        case .firstAid: compactTitle = String(localized: "First Aid & Emergency")
        case .cosplayArea, .cosplayChanging: compactTitle = String(localized: "Cosplay")
        case .food: compactTitle = String(localized: "Food")
        default: compactTitle = facility.name
        }
        let labelMinimum =
            facility.layer == nil
            ? max(facility.minimumZoom, 3.2)
            : max(facility.minimumZoom, 5)
        return (compactTitle, labelMinimum)
    }

    private func fitCameraIfNeeded(force: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        let bounds = UnifiedMapProjection.sceneBounds(fromCampus: campus.bounds)
        // The zoom-out limit always follows the current viewport, even when
        // the user's camera is kept.
        minimumCameraScale = max(
            bounds.width / (size.width * 0.86), bounds.height / (size.height * 0.76))
        maximumCameraScale = max(minimumCameraScale / 180, 0.006)
        let refitsOverview = isShowingOverviewFit && scope == .campus
        guard force || !hasFittedInitialCamera || refitsOverview else {
            clampCamera()
            applyLevelOfDetail()
            return
        }
        let fit = campusOverviewFit()
        mapCamera.position = fit.position
        mapCamera.setScale(fit.scale)
        mapCamera.zRotation = 0
        isShowingOverviewFit = true
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-rotated-camera") {
                mapCamera.zRotation = .pi / 4
            }
        #endif
        hasFittedInitialCamera = true
        applyLevelOfDetail()
    }

    private func focusCampus(animated: Bool) {
        let fit = campusOverviewFit()
        animateCamera(
            position: fit.position,
            scale: fit.scale,
            rotation: 0,
            animated: animated
        )
        isShowingOverviewFit = true
    }

    /// Chrome that covers the map edges. MapView can report measured insets;
    /// until it does, estimate the event banner and hall selector at the top
    /// and the control row at the bottom.
    private var effectiveOverviewInsets: MapViewportInsets {
        if let overviewInsets { return overviewInsets }
        let safeArea = view?.safeAreaInsets ?? .zero
        return MapViewportInsets(
            top: safeArea.top + 96,
            left: safeArea.left + MapChromeLayout.edgeInset,
            bottom: safeArea.bottom + MapChromeLayout.edgeInset + MapChromeLayout.controlSize
                + MapChromeLayout.controlSpacing,
            right: safeArea.right + MapChromeLayout.edgeInset
        )
    }

    /// The halls and the stations attendees walk from, in scene coordinates.
    /// `campus.bounds` also holds every facility and footway, which leaves
    /// the halls small on a large screen such as iPad.
    private var campusOverviewSceneRect: CGRect {
        var rect = campus.venues.reduce(CGRect.null) { $0.union($1.bounds) }
        for facility in campus.facilities where facility.kind == .train {
            rect = rect.union(CGRect(origin: facility.center, size: CGSize(width: 1, height: 1)))
        }
        return UnifiedMapProjection.sceneBounds(fromCampus: rect.isNull ? campus.bounds : rect)
    }

    private func campusOverviewFit() -> MapCameraFit {
        let rect = campusOverviewSceneRect
        let closestScale = minimumCameraScale / Self.maximumOverviewZoomFactor
        return MapCameraMath.spriteKitCameraFit(
            sceneRect: rect,
            viewportSize: size,
            insets: effectiveOverviewInsets,
            padding: MapCameraMath.locationMarkerViewportPadding,
            scaleRange: min(closestScale, minimumCameraScale)...minimumCameraScale
        )
            ?? MapCameraFit(
                position: CGPoint(x: rect.midX, y: rect.midY),
                scale: minimumCameraScale
            )
    }

    private func fitCamera(
        to target: MapCameraFitRequest.Target,
        searchMatches: [CatalogMapSearchMatch]
    ) {
        switch target {
        case .campusOverview:
            focusCampus(animated: true)
        case .layer(let layer):
            let rect = campus.facilities
                .filter { $0.layer == layer }
                .reduce(CGRect.null) {
                    $0.union(CGRect(origin: $1.center, size: CGSize(width: 1, height: 1)))
                }
            fitCamera(toCampusRect: rect, rotation: mapCamera.zRotation)
        case .searchMatches:
            let venuesByMapID = Dictionary(uniqueKeysWithValues: campus.venues.map { ($0.id, $0) })
            var rect = CGRect.null
            var matchedVenues: [Int: BigSightVenuePlacement] = [:]
            for match in searchMatches {
                guard let venue = venuesByMapID[match.mapID],
                    let table = venue.scene.tableByID[match.tableID]
                else { continue }
                let local = subspaceRect(table: table, subspace: match.subspace, scene: venue.scene)
                rect = rect.union(local.applying(venue.transform))
                matchedVenues[venue.id] = venue
            }
            // Matches in one hall read best in that hall's own orientation.
            let rotation =
                matchedVenues.count == 1
                ? -(matchedVenues.values.first?.rotation ?? 0)
                : mapCamera.zRotation
            fitCamera(toCampusRect: rect, rotation: rotation)
        }
    }

    private func fitCamera(toCampusRect rect: CGRect, rotation: CGFloat) {
        guard !rect.isNull else { return }
        let closestScale = max(maximumCameraScale, minimumCameraScale / 45)
        guard
            let fit = MapCameraMath.spriteKitCameraFit(
                sceneRect: UnifiedMapProjection.sceneBounds(fromCampus: rect),
                viewportSize: size,
                insets: effectiveOverviewInsets,
                padding: MapCameraMath.locationMarkerViewportPadding,
                cameraRotation: rotation,
                scaleRange: min(closestScale, minimumCameraScale)...minimumCameraScale
            )
        else { return }
        animateCamera(
            position: fit.position,
            scale: fit.scale,
            rotation: rotation,
            animated: true,
            updatesSemanticScope: true
        )
    }

    private func focusVenue(mapID: Int, animated: Bool) {
        guard let venue = campus.venues.first(where: { $0.id == mapID }) else { return }
        let bounds = UnifiedMapProjection.sceneBounds(fromCampus: venue.bounds)
        let targetScale = max(
            maximumCameraScale,
            min(
                minimumCameraScale,
                max(bounds.width / (size.width * 0.82), bounds.height / (size.height * 0.68))
            )
        )
        animateCamera(
            position: CGPoint(x: bounds.midX, y: bounds.midY),
            scale: targetScale,
            rotation: -venue.rotation,
            animated: animated
        )
    }

    private func focus(on user: LocatedMapUser, animated: Bool) {
        guard let venue = campus.venues.first(where: { $0.id == user.sceneID.mapID }) else {
            return
        }
        let campusPoint = user.point.applying(venue.transform)
        let userPosition = UnifiedMapProjection.scenePoint(fromCampus: campusPoint)
        let viewportSize = view?.bounds.size ?? size
        let effectiveBottomInset =
            locationFocusBottomInset
            + (view?.safeAreaInsets.bottom ?? 0)
        let currentTransform = MapCameraMath.spriteKitViewTransform(
            viewportSize: viewportSize,
            cameraPosition: mapCamera.position,
            cameraScale: mapCamera.xScale,
            cameraRotation: mapCamera.zRotation
        )
        let zoomOutFactor = MapCameraMath.zoomOutFactorToReveal(
            location: userPosition,
            renderedBy: currentTransform,
            viewportSize: viewportSize,
            bottomInset: effectiveBottomInset,
            padding: MapCameraMath.locationMarkerViewportPadding
        )
        let targetScale = min(
            minimumCameraScale,
            mapCamera.xScale / max(zoomOutFactor, 0.000_1)
        )
        guard targetScale > mapCamera.xScale else { return }

        let visibleCenter = MapCameraMath.visibleViewportCenter(
            viewportSize: viewportSize,
            bottomInset: effectiveBottomInset
        )
        let anchoredScenePoint = visibleCenter.applying(currentTransform.inverted())
        let position = MapCameraMath.spriteKitCameraPosition(
            focusing: anchoredScenePoint,
            at: visibleCenter,
            viewportSize: viewportSize,
            cameraScale: targetScale,
            cameraRotation: mapCamera.zRotation
        )
        animateCamera(
            position: position,
            scale: targetScale,
            rotation: mapCamera.zRotation,
            animated: animated
        )
    }

    private func focus(on destination: MapDestination, animated: Bool) {
        guard let venue = campus.venues.first(where: { $0.id == destination.sceneID.mapID }) else {
            return
        }
        let destinationPoint = UnifiedMapProjection.scenePoint(
            fromCampus: destination.point.applying(venue.transform)
        )
        let targetScale = max(maximumCameraScale, minimumCameraScale / 45)
        animateCamera(
            position: destinationPoint,
            scale: targetScale,
            rotation: -venue.rotation,
            animated: animated
        )
    }

    private func animateCamera(
        position: CGPoint,
        scale: CGFloat,
        rotation: CGFloat,
        animated: Bool,
        updatesSemanticScope: Bool = false
    ) {
        mapCamera.removeAllActions()
        isShowingOverviewFit = false
        let duration = animated && !reduceMotion ? 0.42 : 0
        guard duration > 0 else {
            mapCamera.position = position
            mapCamera.setScale(scale)
            mapCamera.zRotation = rotation
            endGesture(updateSemanticScope: updatesSemanticScope)
            return
        }
        let group = SKAction.group([
            SKAction.move(to: position, duration: duration),
            SKAction.scale(to: scale, duration: duration),
            SKAction.rotate(toAngle: rotation, duration: duration, shortestUnitArc: true),
        ])
        group.timingMode = .easeInEaseOut
        mapCamera.run(group) { [weak self] in
            self?.endGesture(updateSemanticScope: updatesSemanticScope)
        }
    }

    private func clampCamera() {
        guard size.width > 0, size.height > 0 else { return }
        let bounds = UnifiedMapProjection.sceneBounds(fromCampus: campus.bounds)
        let scale = max(maximumCameraScale, min(minimumCameraScale, mapCamera.xScale))
        if scale != mapCamera.xScale { mapCamera.setScale(scale) }
        // Keep the camera center within the map boundary rather than keeping
        // the entire viewport inside it. Edge tables and circles must still be
        // able to reach the center of the screen at any zoom level.
        let margin = min(size.width, size.height) * scale * 0.08
        let minX = bounds.minX - margin
        let maxX = bounds.maxX + margin
        let minY = bounds.minY - margin
        let maxY = bounds.maxY + margin
        mapCamera.position.x =
            minX <= maxX
            ? max(minX, min(maxX, mapCamera.position.x))
            : bounds.midX
        mapCamera.position.y =
            minY <= maxY
            ? max(minY, min(maxY, mapCamera.position.y))
            : bounds.midY
    }

    private func applyLevelOfDetail() {
        let zoom = zoomFactor
        // SpriteKit's positive node rotation is visually opposite the camera
        // rotation after the scene-to-UIKit coordinate flip. Matching the
        // camera angle therefore keeps marker artwork and text screen-upright.
        let levelRotation = mapCamera.zRotation
        campusDetailRoot.isHidden = zoom > 18
        pedestrianRoot.alpha = UnifiedMapLevelOfDetail.opacity(
            at: zoom,
            minimumZoom: 0,
            maximumZoom: 80,
            fadeSpan: 8
        )
        pedestrianRoot.isHidden = pedestrianRoot.alpha <= 0
        tableRoot.isHidden = zoom < 2.2
        blockLabelRoot.isHidden = zoom < 10 || zoom > 65
        tableLabelRoot.isHidden = zoom < 32
        staticRoot.alpha = isSearchActive ? Self.searchBaseMapAlpha : 1
        tableLabelRoot.alpha = isSearchActive ? Self.searchBaseMapAlpha : 1
        genreRoot.alpha = isSearchActive ? 0.12 : 1
        genreRoot.isHidden = scope != .venue
        dynamicRoot.isHidden = false
        markerRoot.isHidden = false
        for marker in destinationRoot.children where marker.name == "map-destination-marker" {
            marker.setScale(mapCamera.xScale)
            marker.zRotation = levelRotation
        }
        for marker in venueMarkers + facilityMarkers {
            marker.node.setScale(mapCamera.xScale)
            marker.node.zRotation = levelRotation
            let isVenue = marker.venueID != nil
            let isLayerVisible = marker.layer.map(visibleMapLayers.contains) ?? true
            // Search hides facility icons only. Hall badges stay, and halls
            // without a match dim.
            let isVisible = isLayerVisible && (isVenue || !isSearchActive)
            var searchAlpha: CGFloat = 1
            if isSearchActive, let venueID = marker.venueID,
                !searchMatchedVenueIDs.contains(venueID)
            {
                searchAlpha = Self.searchUnmatchedVenueAlpha
            }
            marker.node.alpha =
                isVisible
                ? UnifiedMapLevelOfDetail.opacity(
                    at: zoom,
                    minimumZoom: marker.minimumZoom,
                    maximumZoom: marker.maximumZoom
                ) * searchAlpha
                : 0
            marker.node.isHidden = marker.node.alpha <= 0
            marker.label.alpha = UnifiedMapLevelOfDetail.opacity(
                at: zoom,
                minimumZoom: marker.labelMinimumZoom,
                maximumZoom: marker.maximumZoom
            )
            marker.label.isHidden = marker.label.alpha <= 0
        }
        for label in blockLabels {
            label.setScale(mapCamera.xScale)
            label.zRotation = levelRotation
            if let mapID = label.userData?["mapID"] as? Int {
                label.isHidden =
                    zoom < 10 || zoom > 65 || (scope == .venue && mapID != selectedMapID)
            }
        }
        for child in tableLabelRoot.children {
            child.setScale(mapCamera.xScale)
            child.zRotation = levelRotation
        }
        for child in userRoot.children {
            child.setScale(mapCamera.xScale)
        }
        layoutMarkerLabels()
    }

    /// Screen-space collision pass for every marker and title.
    ///
    /// 1. Hall badges claim their rects first.
    /// 2. Each hall title takes the first clear side of its badge: below,
    ///    trailing, leading, then above.
    /// 3. Facility icons follow in priority order. An icon that would cover a
    ///    hall badge, a hall title, or a higher-priority icon is hidden.
    /// 4. Facility titles take the first clear side of their icon: below,
    ///    above, trailing, then leading. A title with no clear side inside the
    ///    uncovered viewport is hidden, and its icon stays.
    ///
    /// The viewport excludes the top and bottom map chrome, so no title runs
    /// under the compass, the attribution, or off the screen edge.
    private func layoutMarkerLabels() {
        guard let view else { return }
        let insets = effectiveOverviewInsets
        // Titles keep the 8 pt gap from the screen edges too, so no title
        // touches the edge of the display.
        let viewport = CGRect(
            x: insets.left,
            y: insets.top,
            width: view.bounds.width - insets.left - insets.right,
            height: view.bounds.height - insets.top - insets.bottom
        ).insetBy(dx: Spacing.small, dy: 0)
        let venues = venueMarkers.filter { !$0.node.isHidden }
        var obstacles = venues.map(badgeViewRect)

        let badgeRects = obstacles
        for marker in venues {
            guard marker.label.alpha > 0 else { continue }
            let ownBadge = badgeViewRect(marker)
            place(
                marker.label,
                of: marker,
                sides: [.below, .trailing, .leading, .above],
                in: viewport,
                obstacles: &obstacles,
                // A hall title must sit closer to its own badge than to any
                // other badge, or "East 7" reads as the name of East 4–6.
                otherBadges: badgeRects.filter { $0 != ownBadge }
            )
        }

        let facilities = facilityMarkers.enumerated()
            .filter { !$0.element.node.isHidden }
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
        var placedFacilities: [ScreenSpaceMarker] = []
        for marker in facilities {
            let iconRect = badgeViewRect(marker)
            // Icons may touch, but not overlap by more than a point.
            let probe = iconRect.insetBy(dx: 1, dy: 1)
            if obstacles.contains(where: { $0.intersects(probe) }) {
                marker.node.isHidden = true
                continue
            }
            obstacles.append(iconRect)
            placedFacilities.append(marker)
        }

        for marker in placedFacilities {
            guard !marker.label.isHidden, marker.label.alpha > 0,
                marker.label.text?.isEmpty == false
            else { continue }
            place(
                marker.label,
                of: marker,
                sides: [.below, .above, .trailing, .leading],
                in: viewport,
                obstacles: &obstacles
            )
        }
    }

    private enum LabelSide {
        case below, above, trailing, leading
    }

    /// Moves `label` to the first side of its marker whose rect stays inside
    /// `viewport` and clear of `obstacles`, then adds that rect to
    /// `obstacles`. Hides the label when no side is clear.
    ///
    /// The own badge only needs to stay clear of the label; every other
    /// obstacle keeps an 8 pt gap, so two titles never stack into one block
    /// and a title never touches a neighbor badge. With `otherBadges`, a side
    /// is also rejected when the label would sit nearer to one of those
    /// badges than to its own.
    private func place(
        _ label: SKLabelNode,
        of marker: ScreenSpaceMarker,
        sides: [LabelSide],
        in viewport: CGRect,
        obstacles: inout [CGRect],
        otherBadges: [CGRect] = []
    ) {
        let ownBadge = badgeViewRect(marker)
        let center = markerViewCenter(marker)
        let size = label.frame.size
        let clearance = marker.badgeSize / 2 + UnifiedMapMarkerMetrics.labelClearance
        for side in sides {
            // Screen-space offset of the label center, y down.
            let offset: CGPoint =
                switch side {
                case .below: CGPoint(x: 0, y: clearance + size.height / 2)
                case .above: CGPoint(x: 0, y: -(clearance + size.height / 2))
                case .trailing: CGPoint(x: clearance + size.width / 2, y: 0)
                case .leading: CGPoint(x: -(clearance + size.width / 2), y: 0)
                }
            let rect = CGRect(
                x: center.x + offset.x - size.width / 2,
                y: center.y + offset.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            let probe = rect.insetBy(dx: -Spacing.small, dy: -Spacing.small)
            let ownDistance = Self.distance(between: rect, and: ownBadge)
            guard viewport.contains(rect),
                !obstacles.contains(where: { obstacle in
                    obstacle == ownBadge ? obstacle.intersects(rect) : obstacle.intersects(probe)
                }),
                !otherBadges.contains(where: {
                    Self.distance(between: rect, and: $0) <= ownDistance + Spacing.xSmall
                })
            else { continue }
            // The marker is scaled and rotated to stay screen-upright, so one
            // local unit is one screen point with the y axis pointing up.
            label.position = CGPoint(x: offset.x, y: -offset.y)
            label.isHidden = false
            obstacles.append(rect)
            return
        }
        label.isHidden = true
    }

    /// The shortest gap between two rects; zero when they touch or overlap.
    private static func distance(between a: CGRect, and b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    private func markerViewCenter(_ marker: ScreenSpaceMarker) -> CGPoint {
        convertPoint(toView: marker.node.convert(.zero, to: self))
    }

    private func badgeViewRect(_ marker: ScreenSpaceMarker) -> CGRect {
        let center = markerViewCenter(marker)
        return CGRect(
            x: center.x - marker.badgeSize / 2,
            y: center.y - marker.badgeSize / 2,
            width: marker.badgeSize,
            height: marker.badgeSize
        )
    }

    /// Hall badges that are currently drawn, with frames that cover the badge
    /// and its visible title. The host exposes each one as a VoiceOver button.
    func venueBadgeTargets() -> [VenueBadgeTarget] {
        guard view != nil else { return [] }
        return venueMarkers.compactMap { marker in
            guard let venueID = marker.venueID,
                !marker.node.isHidden,
                marker.node.alpha > 0.05
            else { return nil }
            var frame = badgeViewRect(marker)
            if !marker.label.isHidden {
                let center = markerViewCenter(marker)
                let size = marker.label.frame.size
                frame = frame.union(
                    CGRect(
                        x: center.x + marker.label.position.x - size.width / 2,
                        y: center.y - marker.label.position.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    ))
            }
            return VenueBadgeTarget(
                venueID: venueID,
                title: marker.label.text ?? "",
                frame: frame
            )
        }
    }

    private func refreshVisibleTableLabels() {
        tableLabelRoot.removeAllChildren()
        guard zoomFactor >= 32,
            let venue = selectedVenue,
            venue.scene.artwork == nil,
            let view
        else { return }
        let visibleRect = visibleLocalRect(for: venue, in: view).insetBy(
            dx: -venue.scene.tableSize.width,
            dy: -venue.scene.tableSize.height
        )
        for table in venue.scene.tables.lazy.filter({
            CGRect(origin: $0.origin, size: venue.scene.tableSize).intersects(visibleRect)
        }).prefix(180) {
            let rect = CGRect(origin: table.origin, size: venue.scene.tableSize)
            let campusPoint = CGPoint(x: rect.midX, y: rect.midY).applying(venue.transform)
            let label = labelNode(
                text: "\(table.blockName)\(table.id.spaceNumber)",
                at: UnifiedMapProjection.scenePoint(fromCampus: campusPoint),
                fontSize: 8,
                color: appearance.palette.primaryText.withAlphaComponent(0.86),
                zPosition: 30
            )
            label.setScale(mapCamera.xScale)
            tableLabelRoot.addChild(label)
        }
    }

    private func rebuildDynamicOverlay(
        selectedTableID: CatalogMapTable.ID?,
        circlePlacements: [CatalogMapCirclePlacement],
        circleArtwork: [Int: CGImage],
        searchMatches: [CatalogMapSearchMatch],
        searchActive: Bool,
        genrePlacements: [CatalogMapGenrePlacement],
        bookmarks: [MapBookmark],
        primarySharedPlanCircles: [CatalogBookmarkLocation],
        locatedUser: LocatedMapUser?,
        destination: MapDestination?
    ) {
        dynamicOverlayRebuildCount += 1
        genreRoot.removeAllChildren()
        dynamicRoot.removeAllChildren()
        destinationRoot.removeAllChildren()

        if let destination {
            addDestinationMarker(destination)
        }
        rebuildUserOverlay(locatedUser)

        let venuesByMapID = Dictionary(uniqueKeysWithValues: campus.venues.map { ($0.id, $0) })
        for match in searchMatches {
            guard let venue = venuesByMapID[match.mapID],
                  let table = venue.scene.tableByID[match.tableID]
            else { continue }
            addRectOverlay(
                subspaceRect(table: table, subspace: match.subspace, scene: venue.scene),
                venue: venue,
                fill: UIColor.systemYellow.withAlphaComponent(searchActive ? 0.82 : 0.45),
                stroke: .systemOrange,
                zPosition: 44
            )
        }

        for circle in primarySharedPlanCircles {
            guard let venue = venuesByMapID[circle.mapID],
                  let table = venue.scene.tableByID[circle.tableID]
            else { continue }
            addRectOverlay(
                subspaceRect(
                    table: table,
                    subspace: circle.subspace,
                    scene: venue.scene
                ),
                venue: venue,
                fill: UIColor.systemGreen.withAlphaComponent(0.48),
                stroke: .systemGreen,
                zPosition: 42
            )
        }

        for bookmark in bookmarks {
            guard let venue = venuesByMapID[bookmark.mapID],
                  let table = venue.scene.tableByID[bookmark.tableID]
            else { continue }
            addRectOverlay(
                subspaceRect(
                    table: table,
                    subspace: bookmark.subspace,
                    scene: venue.scene
                ),
                venue: venue,
                fill: bookmark.color.uiColor.withAlphaComponent(0.62),
                stroke: bookmark.color.uiColor,
                zPosition: 43
            )
        }

        guard let venue = selectedVenue else { return }
        let scene = venue.scene

        if let selectedTableID, let table = scene.tableByID[selectedTableID] {
            addRectOverlay(
                CGRect(origin: table.origin, size: scene.tableSize),
                venue: venue,
                fill: UIColor.systemGreen.withAlphaComponent(0.24),
                stroke: .systemGreen,
                zPosition: 40
            )
        }

        addGenreOverlays(genrePlacements, scene: scene, venue: venue)

        if zoomFactor >= 32, !searchActive {
            for placement in circlePlacements {
                guard let table = scene.tableByID[placement.tableID],
                    let image = circleArtwork[placement.circleID]
                else { continue }
                let rect = subspaceRect(table: table, subspace: placement.subspace, scene: scene)
                let center = CGPoint(x: rect.midX, y: rect.midY).applying(venue.transform)
                let geometry = CatalogCircleArtworkGeometry.fitting(
                    pixelSize: CGSize(width: image.width, height: image.height),
                    in: rect.size,
                    orientation: table.orientation
                )
                let texture = SKTexture(cgImage: image)
                texture.filteringMode = .linear
                let sprite = SKSpriteNode(texture: texture)
                sprite.name = "circle-artwork-\(placement.circleID)"
                sprite.position = UnifiedMapProjection.scenePoint(fromCampus: center)
                sprite.size = CGSize(
                    width: geometry.imageSize.width * venue.metersPerMapPoint,
                    height: geometry.imageSize.height * venue.verticalMetersPerMapPoint
                )
                sprite.zRotation = -venue.rotation - geometry.rotation
                sprite.zPosition = 46
                let favoriteColor = bookmarks.first(where: {
                    $0.catalogCircleID == placement.circleID
                })?.color.uiColor
                let planColor = primarySharedPlanCircles.contains(where: {
                    $0.catalogCircleID == placement.circleID
                }) ? UIColor.systemGreen : nil
                if let markColor = favoriteColor ?? planColor {
                    let markRect = CircleFavoriteMarkGeometry.rect(in: sprite.size)
                    let mark = SKShapeNode(
                        rectOf: markRect.size,
                        cornerRadius: 0
                    )
                    mark.fillColor = markColor
                    mark.strokeColor = .clear
                    mark.position = CGPoint(
                        x: -sprite.size.width / 2 + markRect.midX,
                        y: sprite.size.height / 2 - markRect.midY
                    )
                    mark.zPosition = 1
                    sprite.addChild(mark)
                }
                dynamicRoot.addChild(sprite)
            }
        }

    }

    private func addDestinationMarker(_ destination: MapDestination) {
        guard let venue = campus.venues.first(where: { $0.id == destination.sceneID.mapID }) else {
            return
        }
        let campusPoint = destination.point.applying(venue.transform)
        let marker = SKNode()
        marker.name = "map-destination-marker"
        marker.position = UnifiedMapProjection.scenePoint(fromCampus: campusPoint)
        marker.setScale(mapCamera.xScale)
        marker.zRotation = mapCamera.zRotation
        marker.zPosition = 2

        let halo = SKShapeNode(circleOfRadius: 17)
        halo.fillColor = UIColor.systemRed.withAlphaComponent(0.16)
        halo.strokeColor = .clear
        marker.addChild(halo)

        let ring = SKShapeNode(circleOfRadius: 10)
        ring.fillColor = .white
        ring.strokeColor = .systemRed
        ring.lineWidth = 3
        marker.addChild(ring)

        let center = SKShapeNode(circleOfRadius: 3.5)
        center.fillColor = .systemRed
        center.strokeColor = .clear
        center.zPosition = 1
        marker.addChild(center)

        destinationRoot.addChild(marker)
    }

    private func addUser(_ user: LocatedMapUser, venue: BigSightVenuePlacement) {
        let campusPoint = user.point.applying(venue.transform)
        let center = UnifiedMapProjection.scenePoint(fromCampus: campusPoint)
        let marker = SKNode()
        marker.name = "located-user-marker"
        marker.position = center
        marker.setScale(mapCamera.xScale)

        let halo = SKShapeNode(circleOfRadius: 15)
        halo.fillColor = UIColor.systemBlue.withAlphaComponent(0.18)
        halo.strokeColor = .clear
        marker.addChild(halo)

        if let headingDegrees = user.headingDegrees {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 26))
            path.addLine(to: CGPoint(x: -7, y: 5))
            path.addLine(to: CGPoint(x: 7, y: 5))
            path.closeSubpath()

            let heading = SKShapeNode(path: path)
            heading.name = "located-user-heading"
            heading.fillColor = .systemBlue
            heading.strokeColor = .white
            heading.lineWidth = 1.5
            heading.lineJoin = .round
            heading.zRotation = -CGFloat(headingDegrees * .pi / 180)
            heading.zPosition = 0.5
            marker.addChild(heading)
        }

        let puck = SKShapeNode(circleOfRadius: 7)
        puck.fillColor = .systemBlue
        puck.strokeColor = .white
        puck.lineWidth = 2.5
        puck.zPosition = 1
        marker.addChild(puck)
        userRoot.addChild(marker)
    }

    private func addRectOverlay(
        _ rect: CGRect,
        venue: BigSightVenuePlacement,
        fill: UIColor,
        stroke: UIColor = .clear,
        zPosition: CGFloat
    ) {
        var transform = UnifiedMapProjection.sceneTransform(for: venue)
        let path = CGPath(rect: rect, transform: &transform)
        let node = SKShapeNode(path: path)
        node.fillColor = fill
        node.strokeColor = stroke
        node.lineWidth = stroke == .clear ? 0 : 0.07
        node.zPosition = zPosition
        dynamicRoot.addChild(node)
    }

    private func addGenreOverlays(
        _ placements: [CatalogMapGenrePlacement],
        scene: CatalogMapScene,
        venue: BigSightVenuePlacement
    ) {
        var pathsByGenre: [Int: CGMutablePath] = [:]
        let transform = UnifiedMapProjection.sceneTransform(for: venue)

        for placement in placements {
            guard let table = scene.tableByID[placement.tableID] else { continue }
            let path = pathsByGenre[placement.genreID] ?? CGMutablePath()
            path.addRect(
                subspaceRect(table: table, subspace: placement.subspace, scene: scene),
                transform: transform
            )
            pathsByGenre[placement.genreID] = path
        }

        for genreID in pathsByGenre.keys.sorted() {
            guard let path = pathsByGenre[genreID] else { continue }
            let node = SKShapeNode(path: path)
            node.name = "genre-overlay-\(genreID)"
            node.fillColor = genreColor(genreID).withAlphaComponent(0.42)
            node.strokeColor = .clear
            node.lineWidth = 0
            node.zPosition = 41
            genreRoot.addChild(node)
        }
    }

    private func scheduleViewportUpdate(immediate: Bool) {
        viewportWorkItem?.cancel()
        guard let venue = selectedVenue, let view else { return }
        let viewport = CatalogMapViewport(
            sceneID: venue.scene.id,
            mapRect: visibleLocalRect(for: venue, in: view),
            renderedScale: min(venue.metersPerMapPoint, venue.verticalMetersPerMapPoint)
                / max(mapCamera.xScale, 0.000_1)
        )
        let work = DispatchWorkItem { [weak self] in self?.onViewportChange?(viewport) }
        viewportWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.12), execute: work)
    }

    private func visibleLocalRect(for venue: BigSightVenuePlacement, in view: SKView) -> CGRect {
        let inverse = venue.transform.inverted()
        let points = [
            CGPoint(x: view.bounds.minX, y: view.bounds.minY),
            CGPoint(x: view.bounds.maxX, y: view.bounds.minY),
            CGPoint(x: view.bounds.minX, y: view.bounds.maxY),
            CGPoint(x: view.bounds.maxX, y: view.bounds.maxY),
        ].map { point -> CGPoint in
            let scenePoint = convertPoint(fromView: point)
            return UnifiedMapProjection.campusPoint(fromScene: scenePoint).applying(inverse)
        }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? venue.scene.size.width
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? venue.scene.size.height
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func updateSemanticScope() {
        // A fitted hall is about 3x the campus scale. Only return to the
        // campus scope once the user is genuinely close to the campus fit.
        if zoomFactor < 1.6, scope == .venue {
            requestedScopeInternally = true
            scope = .campus
            selectedMapID = nil
            onSemanticScopeChange?(.campus, nil)
            return
        }
        guard zoomFactor >= 2.4, scope == .campus else { return }
        let campusPoint = UnifiedMapProjection.campusPoint(fromScene: mapCamera.position)
        guard
            let venue = campus.venues.first(where: {
                CGRect(origin: .zero, size: $0.scene.size)
                    .contains(campusPoint.applying($0.transform.inverted()))
            })
        else { return }
        requestedScopeInternally = true
        scope = .venue
        selectedMapID = venue.id
        onSemanticScopeChange?(.venue, venue.id)
    }

    private func dynamicFingerprint(
        selectedTableID: CatalogMapTable.ID?,
        placements: [CatalogMapCirclePlacement],
        artwork: [Int: CGImage],
        matches: [CatalogMapSearchMatch],
        searchActive: Bool,
        genres: [CatalogMapGenrePlacement],
        bookmarks: [MapBookmark],
        primarySharedPlanCircles: [CatalogBookmarkLocation],
        locatedUser: LocatedMapUser?,
        destination: MapDestination?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedMapID)
        hasher.combine(selectedTableID)
        hasher.combine(placements.count)
        placements.forEach { hasher.combine($0.circleID) }
        hasher.combine(artwork.count)
        artwork.keys.sorted().forEach { hasher.combine($0) }
        hasher.combine(matches.count)
        matches.forEach {
            hasher.combine($0.id)
            hasher.combine($0.mapID)
            hasher.combine($0.tableID)
            hasher.combine($0.subspace)
        }
        hasher.combine(searchActive)
        hasher.combine(genres.count)
        genres.forEach {
            hasher.combine($0.id)
            hasher.combine($0.genreID)
        }
        hasher.combine(bookmarks.count)
        bookmarks.forEach {
            hasher.combine($0.publicCircleID)
            hasher.combine($0.mapID)
            hasher.combine($0.tableID)
            hasher.combine($0.subspace)
            hasher.combine($0.color.rawValue)
        }
        hasher.combine(primarySharedPlanCircles.count)
        primarySharedPlanCircles.forEach {
            hasher.combine($0.publicCircleID)
            hasher.combine($0.catalogCircleID)
            hasher.combine($0.mapID)
            hasher.combine($0.tableID)
            hasher.combine($0.subspace)
        }
        hasher.combine(locatedUser?.placedAt)
        hasher.combine(destination?.selectedAt)
        return hasher.finalize()
    }

    private func rebuildUserOverlay(_ locatedUser: LocatedMapUser?) {
        userRoot.removeAllChildren()
        guard let locatedUser,
            let venue = campus.venues.first(where: { $0.id == locatedUser.sceneID.mapID })
        else { return }
        addUser(locatedUser, venue: venue)
    }

    private func labelNode(
        text: String,
        at position: CGPoint,
        fontSize: CGFloat,
        color: UIColor,
        zPosition: CGFloat,
        halo: Bool = false,
        maxWidth: CGFloat? = nil
    ) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: ".AppleSystemUIFontRounded-Bold")
        label.text = text
        label.fontSize = fontSize
        label.fontColor = color
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = position
        label.zPosition = zPosition
        if let maxWidth {
            // Long facility names take two lines, broken only between words.
            // A name that cannot fit loses its title; the icon stays.
            label.numberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            if let title = UnifiedMapMarkerMetrics.facilityTitle(
                text,
                fontSize: fontSize,
                maxWidth: maxWidth
            ) {
                label.text = title.text
                label.preferredMaxLayoutWidth = title.width
            } else {
                label.text = ""
            }
        }
        if halo, let shownText = label.text, !shownText.isEmpty {
            label.addChild(haloNode(for: label, text: shownText, fontSize: fontSize))
        }
        return label
    }

    /// The halo behind a map label: copies of the label in the floor color,
    /// offset in eight directions by the halo width, so roads and floor
    /// artwork never cut through the text.
    ///
    /// The copies use the same font, wrap width, and alignment as the label,
    /// so they line up glyph for glyph. A stroked `attributedText` copy did
    /// not: SpriteKit draws attributed text with other metrics and clips the
    /// stroke at the glyph bounds, so the halo drew as a smear beside the
    /// text.
    private func haloNode(for label: SKLabelNode, text: String, fontSize: CGFloat) -> SKNode {
        let haloColor = appearance.palette.labelHalo
        let radius = UnifiedMapMarkerMetrics.labelHaloWidth
        let container = SKNode()
        container.name = "map-label-halo"
        container.zPosition = -0.05
        let diagonal = radius * 0.7071
        let offsets: [CGPoint] = [
            CGPoint(x: radius, y: 0), CGPoint(x: -radius, y: 0),
            CGPoint(x: 0, y: radius), CGPoint(x: 0, y: -radius),
            CGPoint(x: diagonal, y: diagonal), CGPoint(x: -diagonal, y: diagonal),
            CGPoint(x: diagonal, y: -diagonal), CGPoint(x: -diagonal, y: -diagonal),
        ]
        for offset in offsets {
            let copy = SKLabelNode(fontNamed: label.fontName)
            copy.text = text
            copy.fontSize = fontSize
            copy.fontColor = haloColor
            copy.numberOfLines = label.numberOfLines
            copy.lineBreakMode = label.lineBreakMode
            copy.preferredMaxLayoutWidth = label.preferredMaxLayoutWidth
            copy.horizontalAlignmentMode = label.horizontalAlignmentMode
            copy.verticalAlignmentMode = label.verticalAlignmentMode
            copy.position = offset
            container.addChild(copy)
        }
        return container
    }

    private func markerNode(
        icon: BigSightMapIcon,
        title: String,
        at position: CGPoint,
        iconSize: CGFloat,
        fontSize: CGFloat,
        titleColor: UIColor,
        zPosition: CGFloat,
        labelMaxWidth: CGFloat? = nil
    ) -> (node: SKNode, label: SKLabelNode) {
        let container = SKNode()
        let iconName = icon.rawValue
        container.name = "map-marker-\(iconName)-\(title)"
        container.position = position
        container.zPosition = zPosition

        let backingSize = UnifiedMapMarkerMetrics.backingSize(
            for: icon,
            iconSize: iconSize
        )
        let backing: SKShapeNode
        switch icon.backdrop {
        case .standard:
            backing = SKShapeNode(
                rectOf: CGSize(width: backingSize, height: backingSize),
                cornerRadius: Radius.xSmall
            )
            backing.fillColor = appearance.palette.iconBackground
            backing.strokeColor = appearance.palette.markerStroke
            backing.lineWidth = 0.75
        case .transitYellowCircle:
            backing = SKShapeNode(circleOfRadius: backingSize / 2)
            backing.fillColor = UIColor(
                red: 250.0 / 255.0,
                green: 192.0 / 255.0,
                blue: 44.0 / 255.0,
                alpha: 1
            )
            backing.strokeColor = .clear
            backing.lineWidth = 0
        case .venueBilingualBadge:
            backing = SKShapeNode(
                rectOf: CGSize(width: backingSize, height: backingSize),
                cornerRadius: UnifiedMapMarkerMetrics.venueBadgeCornerRadius(side: backingSize)
            )
            backing.fillColor = appearance.venueBadgeRim
            backing.strokeColor = appearance.venueBadgeRimStroke
            backing.lineWidth = 0.65
        }
        backing.name = "map-marker-backdrop-\(iconName)"
        backing.zPosition = 0
        container.addChild(backing)

        if let badge = icon.venueBadge {
            let inset = UnifiedMapMarkerMetrics.venueBadgePlateInset(side: backingSize)
            let plateSize = backingSize - inset * 2
            let plate = SKShapeNode(
                rectOf: CGSize(width: plateSize, height: plateSize),
                cornerRadius: UnifiedMapMarkerMetrics.venueBadgePlateRadius(side: backingSize)
            )
            plate.name = "map-marker-venue-color-\(iconName)"
            plate.fillColor = markerAccentColor(icon)
            plate.strokeColor = .clear
            plate.lineWidth = 0
            plate.zPosition = 0.5
            container.addChild(plate)

            addVenueBadgeText(
                badge,
                iconName: iconName,
                iconSize: iconSize,
                to: container
            )
        } else if let assetName = icon.assetName,
            let image = UIImage(named: assetName)
        {
            let texture = SKTexture(image: image)
            texture.filteringMode = .linear
            let sprite = SKSpriteNode(texture: texture)
            sprite.name = "map-marker-icon-\(iconName)"
            sprite.size = CGSize(width: iconSize, height: iconSize)
            sprite.color = markerIconColor(icon)
            sprite.colorBlendFactor = 1
            sprite.zPosition = 1
            container.addChild(sprite)
        } else {
            assertionFailure("Missing map marker content: \(iconName)")
        }

        let label = labelNode(
            text: title,
            at: .zero,
            fontSize: fontSize,
            color: titleColor,
            zPosition: 2,
            halo: true,
            maxWidth: labelMaxWidth
        )
        // Below the backing until the screen-space layout picks a side.
        label.position = CGPoint(
            x: 0,
            y: -(backingSize / 2 + UnifiedMapMarkerMetrics.labelClearance + label.frame.height / 2)
        )
        container.addChild(label)
        return (container, label)
    }

    private func markerIconColor(_ icon: BigSightMapIcon) -> UIColor {
        return switch icon.backdrop {
        case .standard:
            markerAccentColor(icon)
        case .transitYellowCircle:
            UIColor(red: 0.13, green: 0.09, blue: 0.08, alpha: 1)
        case .venueBilingualBadge:
            .white
        }
    }

    private func markerAccentColor(_ icon: BigSightMapIcon) -> UIColor {
        if let badge = icon.venueBadge {
            return UIColor(
                red: CGFloat(badge.color.red),
                green: CGFloat(badge.color.green),
                blue: CGFloat(badge.color.blue),
                alpha: 1
            )
        }

        return switch icon.accent {
        case .ink: UIColor(red: 0.13, green: 0.09, blue: 0.08, alpha: 1)
        case .red: UIColor(red: 0.85, green: 0.04, blue: 0.16, alpha: 1)
        case .green: UIColor(red: 0, green: 0.60, blue: 0.24, alpha: 1)
        case .blue: UIColor(red: 0, green: 0.34, blue: 0.63, alpha: 1)
        case .amber: UIColor(red: 0.82, green: 0.52, blue: 0.02, alpha: 1)
        case .taupe: UIColor(red: 0.47, green: 0.42, blue: 0.36, alpha: 1)
        }
    }

    private func addVenueBadgeText(
        _ badge: BigSightMapIcon.VenueBadge,
        iconName: String,
        iconSize: CGFloat,
        to container: SKNode
    ) {
        let japanese = labelNode(
            text: badge.japanese,
            at: CGPoint(x: 0, y: iconSize * 0.11),
            fontSize: iconSize * 0.54,
            color: .white,
            zPosition: 1
        )
        japanese.name = "map-marker-venue-kanji-\(iconName)"
        container.addChild(japanese)

        let english = labelNode(
            text: badge.english,
            at: CGPoint(x: 0, y: -iconSize * 0.31),
            fontSize: iconSize * 0.17,
            color: .white,
            zPosition: 1
        )
        english.name = "map-marker-venue-english-\(iconName)"
        container.addChild(english)
    }

    private func dividerSegment(
        for rect: CGRect,
        orientation: CatalogMapTable.Orientation
    ) -> (start: CGPoint, end: CGPoint) {
        switch orientation {
        case .aLeft, .aRight:
            (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
        case .aTop, .aBottom:
            (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY))
        }
    }

    private func subspaceRect(
        table: CatalogMapTable,
        subspace: Int,
        scene: CatalogMapScene
    ) -> CGRect {
        let rect = CGRect(origin: table.origin, size: scene.tableSize)
        switch table.orientation {
        case .aLeft:
            return subspace == 0
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
                : CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .aBottom:
            return subspace == 0
                ? CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .aRight:
            return subspace == 0
                ? CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .aTop:
            return subspace == 0
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
                : CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    private func subspace(
        at point: CGPoint,
        table: CatalogMapTable,
        scene: CatalogMapScene
    ) -> Int {
        let rect = CGRect(origin: table.origin, size: scene.tableSize)
        return switch table.orientation {
        case .aLeft: point.x < rect.midX ? 0 : 1
        case .aBottom: point.y >= rect.midY ? 0 : 1
        case .aRight: point.x >= rect.midX ? 0 : 1
        case .aTop: point.y < rect.midY ? 0 : 1
        }
    }

    private func normalizedRotation(_ radians: CGFloat) -> CGFloat {
        var value = radians.truncatingRemainder(dividingBy: .pi * 2)
        if value >= .pi { value -= .pi * 2 }
        if value < -.pi { value += .pi * 2 }
        return value
    }

    private func blockColor(_ blockID: Int) -> UIColor {
        UIColor(
            hue: CGFloat((blockID * 47) % 360) / 360,
            saturation: appearance == .dark ? 0.24 : 0.14,
            brightness: appearance == .dark ? 0.28 : 0.98,
            alpha: 1
        )
    }

    private func genreColor(_ genreID: Int) -> UIColor {
        UIColor(
            hue: CGFloat((genreID * 67) % 360) / 360, saturation: 0.58, brightness: 0.92, alpha: 1)
    }

}

extension SKNode {
    fileprivate func descendants<T: SKNode>(of type: T.Type) -> [T] {
        children.flatMap { child in
            let matchingChild = (child as? T).map { [$0] } ?? []
            return matchingChild + child.descendants(of: type)
        }
    }
}
