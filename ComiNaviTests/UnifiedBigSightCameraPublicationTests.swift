import CoreGraphics
import XCTest

@testable import ComiNavi

final class UnifiedBigSightCameraPublicationTests: XCTestCase {
    @MainActor
    func testReducedMotionCompassPublishesFinalRotationSynchronously() throws {
        let renderer = UnifiedBigSightScene(campus: makeGridAlignedCampus())
        renderer.reduceMotion = true
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = UnifiedBigSightMapView.Coordinator()
        var publishedRotation: CGFloat?
        coordinator.connect(host: host, renderer: renderer)
        coordinator.updateCallbacks(
            onSelectVenue: { _ in },
            onShowCampus: {},
            onSelectTable: { _, _ in },
            onSelectLocatedUser: {},
            onCameraRotationChange: { publishedRotation = $0 },
            onLocate: { _, _, _, _ in }
        )
        host.layoutIfNeeded()

        host.compassButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(
            renderer.cameraRotation,
            renderer.gridAlignedCameraRotation,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(publishedRotation),
            renderer.gridAlignedCameraRotation,
            accuracy: 0.000_001
        )
        XCTAssertTrue(host.compassButton.isGridAligned)
        XCTAssertEqual(
            host.compassButton.accessibilityValue,
            String(localized: "Grid aligned")
        )
        XCTAssertEqual(
            host.basemapView.direction,
            renderer.basemapCamera.direction,
            accuracy: 0.001
        )
        XCTAssertEqual(
            host.basemapView.centerCoordinate.latitude,
            renderer.basemapCamera.coordinate.latitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            host.basemapView.centerCoordinate.longitude,
            renderer.basemapCamera.coordinate.longitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            host.basemapView.zoomLevel,
            renderer.basemapCamera.zoomLevel,
            accuracy: 0.001
        )
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testEnablingReducedMotionStopsAnActiveCameraAnimation() {
        let renderer = UnifiedBigSightScene(campus: makeGridAlignedCampus())
        let host = UnifiedMapHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.layoutIfNeeded()
        host.mapView.presentScene(renderer)

        renderer.animatedZoom(
            by: 2,
            around: CGPoint(x: 195, y: 422),
            in: host.mapView
        )

        XCTAssertTrue(renderer.hasActiveCameraAnimation)

        renderer.reduceMotion = true

        XCTAssertFalse(renderer.hasActiveCameraAnimation)
    }

    private func makeGridAlignedCampus() -> BigSightCampusScene {
        let scene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "West Hall",
            size: CGSize(width: 4_680, height: 1_680),
            tableSize: CGSize(width: 40, height: 40),
            tables: []
        )
        let venue = BigSightVenuePlacement(
            kind: .west,
            scene: scene,
            coordinate: BigSightCampusLayout.eastBuilding,
            center: BigSightCampusLayout.project(BigSightCampusLayout.eastBuilding),
            rotation: CGFloat(146.97977914964463 * .pi / 180),
            metersPerMapPoint: BigSightCampusLayout.metersPerMapPoint
        )
        return BigSightCampusScene(
            id: .init(day: 1, mapIDs: [venue.id]),
            venues: [venue],
            connections: [],
            bounds: venue.bounds.insetBy(dx: -70, dy: -70)
        )
    }
}
