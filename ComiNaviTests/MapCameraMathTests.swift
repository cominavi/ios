import CoreGraphics
import XCTest
@testable import ComiNavi

final class MapCameraMathTests: XCTestCase {
    func testVisibleViewportCenterExcludesThePresentedBottomSheet() {
        XCTAssertEqual(
            MapCameraMath.visibleViewportCenter(
                viewportSize: CGSize(width: 390, height: 844),
                bottomInset: 430
            ),
            CGPoint(x: 195, y: 207)
        )
    }

    func testSpriteKitFocusPositionAccountsForRotationAndBottomInset() {
        let viewportSize = CGSize(width: 390, height: 844)
        let target = MapCameraMath.visibleViewportCenter(
            viewportSize: viewportSize,
            bottomInset: 430
        )
        let scenePoint = CGPoint(x: 1_240, y: -830)
        let scale: CGFloat = 0.38
        let rotation = CGFloat.pi / 5
        let cameraPosition = MapCameraMath.spriteKitCameraPosition(
            focusing: scenePoint,
            at: target,
            viewportSize: viewportSize,
            cameraScale: scale,
            cameraRotation: rotation
        )

        let sceneOffset = CGPoint(
            x: scenePoint.x - cameraPosition.x,
            y: scenePoint.y - cameraPosition.y
        )
        let cosine = cos(-rotation)
        let sine = sin(-rotation)
        let cameraLocalOffset = CGPoint(
            x: sceneOffset.x * cosine - sceneOffset.y * sine,
            y: sceneOffset.x * sine + sceneOffset.y * cosine
        )
        let projected = CGPoint(
            x: viewportSize.width / 2 + cameraLocalOffset.x / scale,
            y: viewportSize.height / 2 - cameraLocalOffset.y / scale
        )

        XCTAssertEqual(projected.x, target.x, accuracy: 0.000_001)
        XCTAssertEqual(projected.y, target.y, accuracy: 0.000_001)
    }

    func testNorthIndicatorUsesTheRenderedMapDirection() {
        for rotation in [CGFloat.pi / 3, -CGFloat.pi / 4] {
            let mapNorth = CGPoint(x: 0, y: -1).applying(
                CGAffineTransform(rotationAngle: rotation)
            )
            let indicatorNorth = CGPoint(x: 0, y: -1).applying(
                CGAffineTransform(
                    rotationAngle: MapCameraMath.northIndicatorRotation(
                        mapRotation: rotation
                    )
                )
            )

            XCTAssertEqual(indicatorNorth.x, mapNorth.x, accuracy: 0.000_001)
            XCTAssertEqual(indicatorNorth.y, mapNorth.y, accuracy: 0.000_001)
        }
    }

    func testHeadingIndicatorStaysAlignedWithTheRotatedMap() {
        let mapRotations: [CGFloat] = [0, .pi / 3, -.pi / 4]
        let headings = [0.0, 72.0, 180.0, 315.0]

        for mapRotation in mapRotations {
            for headingDegrees in headings {
                let headingRotation = CGFloat(headingDegrees * .pi / 180)
                let expectedDirection = CGPoint(x: 0, y: -1)
                    .applying(CGAffineTransform(rotationAngle: headingRotation))
                    .applying(CGAffineTransform(rotationAngle: mapRotation))
                let indicatorDirection = CGPoint(x: 0, y: -1).applying(
                    CGAffineTransform(
                        rotationAngle: MapCameraMath.headingIndicatorRotation(
                            headingDegrees: headingDegrees,
                            mapRotation: mapRotation
                        )
                    )
                )

                XCTAssertEqual(
                    indicatorDirection.x,
                    expectedDirection.x,
                    accuracy: 0.000_001
                )
                XCTAssertEqual(
                    indicatorDirection.y,
                    expectedDirection.y,
                    accuracy: 0.000_001
                )
            }
        }
    }

    func testScalingKeepsTheGestureOriginStationary() {
        let viewport = CGSize(width: 390, height: 844)
        let anchor = CGPoint(x: 74, y: 637)
        let originalTranslation = CGSize(width: 31, height: -47)
        let scale: CGFloat = 2.4

        let translated = MapCameraMath.translation(
            originalTranslation,
            scaledBy: scale,
            around: anchor,
            viewportSize: viewport
        )

        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let originalContentOffset = CGPoint(
            x: anchor.x - center.x - originalTranslation.width,
            y: anchor.y - center.y - originalTranslation.height
        )
        let screenPointAfterScaling = CGPoint(
            x: center.x + translated.width + originalContentOffset.x * scale,
            y: center.y + translated.height + originalContentOffset.y * scale
        )

        XCTAssertEqual(screenPointAfterScaling.x, anchor.x, accuracy: 0.000_001)
        XCTAssertEqual(screenPointAfterScaling.y, anchor.y, accuracy: 0.000_001)
    }

    func testIncrementalPinchUpdatesDoNotDriftFromTheGestureOrigin() {
        let viewport = CGSize(width: 430, height: 932)
        let anchor = CGPoint(x: 338, y: 202)
        let originalTranslation = CGSize(width: -26, height: 19)

        let firstUpdate = MapCameraMath.translation(
            originalTranslation,
            scaledBy: 1.2,
            around: anchor,
            viewportSize: viewport
        )
        let secondUpdate = MapCameraMath.translation(
            firstUpdate,
            scaledBy: 1.25,
            around: anchor,
            viewportSize: viewport
        )
        let combinedUpdate = MapCameraMath.translation(
            originalTranslation,
            scaledBy: 1.5,
            around: anchor,
            viewportSize: viewport
        )

        XCTAssertEqual(secondUpdate.width, combinedUpdate.width, accuracy: 0.000_001)
        XCTAssertEqual(secondUpdate.height, combinedUpdate.height, accuracy: 0.000_001)
    }

    func testUnitScaleDoesNotMoveTheCamera() {
        let translation = CGSize(width: -124, height: 87)

        XCTAssertEqual(
            MapCameraMath.translation(
                translation,
                scaledBy: 1,
                around: CGPoint(x: 12, y: 700),
                viewportSize: CGSize(width: 390, height: 844)
            ),
            translation
        )
    }

    func testCombinedZoomAndRotationKeepGestureOriginStationary() {
        let geometry = generousGeometry
        let camera = MapCamera(
            translation: CGSize(width: 31, height: -47),
            zoom: 2,
            rotation: 0.22
        )

        for anchor in anchors(in: geometry.viewportSize) {
            let contentPoint = anchor.applying(
                MapCameraMath.transform(camera: camera, geometry: geometry).inverted()
            )
            let updated = MapCameraMath.applyingGesture(
                to: camera,
                magnification: 1.35,
                magnificationAnchor: anchor,
                rotation: 0.31,
                rotationAnchor: anchor,
                geometry: geometry,
                tuning: .venue,
                allowsRubberBand: false
            )
            let projectedPoint = contentPoint.applying(
                MapCameraMath.transform(camera: updated, geometry: geometry)
            )

            XCTAssertEqual(projectedPoint.x, anchor.x, accuracy: 0.000_01)
            XCTAssertEqual(projectedPoint.y, anchor.y, accuracy: 0.000_01)
        }
    }

    func testLiveAndSettledPinchUseTheSameZoomLimits() {
        let camera = MapCamera(zoom: 4)
        let anchor = CGPoint(x: 100, y: 200)

        let liveMaximum = MapCameraMath.applyingGesture(
            to: camera,
            magnification: 100,
            magnificationAnchor: anchor,
            rotationAnchor: anchor,
            geometry: generousGeometry,
            tuning: .venue,
            allowsRubberBand: true
        )
        let settledMaximum = MapCameraMath.applyingGesture(
            to: camera,
            magnification: 100,
            magnificationAnchor: anchor,
            rotationAnchor: anchor,
            geometry: generousGeometry,
            tuning: .venue,
            allowsRubberBand: false
        )
        let minimum = MapCameraMath.applyingGesture(
            to: camera,
            magnification: 0.000_1,
            magnificationAnchor: anchor,
            rotationAnchor: anchor,
            geometry: generousGeometry,
            tuning: .venue,
            allowsRubberBand: false
        )

        XCTAssertEqual(liveMaximum.zoom, MapCameraTuning.venue.zoomRange.upperBound)
        XCTAssertEqual(settledMaximum.zoom, liveMaximum.zoom)
        XCTAssertEqual(minimum.zoom, MapCameraTuning.venue.zoomRange.lowerBound)
    }

    func testZeroVelocityHasNoReleaseDiscontinuity() {
        let camera = MapCamera(
            translation: CGSize(width: -35, height: 18),
            zoom: 3,
            rotation: -0.2
        )
        let anchor = CGPoint(x: 280, y: 180)
        let magnification: CGFloat = 1.4
        let projected = MapCameraMath.projectedMagnification(
            magnification,
            velocity: 0,
            tuning: .venue
        )
        let live = MapCameraMath.applyingGesture(
            to: camera,
            magnification: magnification,
            magnificationAnchor: anchor,
            rotationAnchor: anchor,
            geometry: generousGeometry,
            tuning: .venue,
            allowsRubberBand: true
        )
        let settled = MapCameraMath.applyingGesture(
            to: camera,
            magnification: projected,
            magnificationAnchor: anchor,
            rotationAnchor: anchor,
            geometry: generousGeometry,
            tuning: .venue,
            allowsRubberBand: false
        )

        XCTAssertEqual(live.zoom, settled.zoom, accuracy: 0.000_001)
        XCTAssertEqual(live.translation.width, settled.translation.width, accuracy: 0.000_001)
        XCTAssertEqual(live.translation.height, settled.translation.height, accuracy: 0.000_001)
    }

    func testPanProjectionIsCappedToAViewportRelativeDistance() {
        let tuning = MapCameraTuning.venue
        let actual = CGSize(width: 12, height: -5)
        let target = MapCameraMath.projectedPan(
            from: MapCamera(zoom: 12),
            translation: actual,
            predictedEndTranslation: CGSize(width: 10_000, height: -8_000),
            geometry: generousGeometry,
            tuning: tuning
        )
        let projectedDistance = hypot(
            target.translation.width - actual.width,
            target.translation.height - actual.height
        )
        let maximum = min(
            generousGeometry.viewportSize.width,
            generousGeometry.viewportSize.height
        ) * tuning.maximumPanProjectionFraction

        XCTAssertLessThanOrEqual(projectedDistance, maximum + 0.000_001)
    }

    func testZoomAndRotationVelocityProjectionAreCapped() {
        let tuning = MapCameraTuning.venue

        XCTAssertEqual(
            MapCameraMath.projectedMagnification(2, velocity: 100, tuning: tuning),
            MapCameraMath.projectedMagnification(
                2,
                velocity: tuning.maximumZoomVelocity,
                tuning: tuning
            ),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapCameraMath.projectedRotation(0.2, velocity: 100, tuning: tuning),
            0.2 + tuning.maximumRotationVelocity * tuning.rotationVelocityInfluence,
            accuracy: 0.000_001
        )
    }

    func testSettledCameraIsStrictlyConstrainedForEveryQuarterTurn() {
        let geometry = MapCameraGeometry(
            contentSize: CGSize(width: 1_200, height: 800),
            viewportSize: CGSize(width: 390, height: 844),
            fittedScale: 0.32
        )

        for rotation in stride(from: -CGFloat.pi, through: .pi, by: .pi / 4) {
            let unconstrained = MapCamera(
                translation: CGSize(width: 100_000, height: -100_000),
                zoom: 5,
                rotation: rotation
            )
            let constrained = MapCameraMath.constrained(
                unconstrained,
                geometry: geometry,
                tuning: .venue
            )
            let limits = MapCameraMath.translationLimits(
                camera: constrained,
                geometry: geometry,
                tuning: .venue
            )

            XCTAssertLessThanOrEqual(abs(constrained.translation.width), limits.width + 0.000_001)
            XCTAssertLessThanOrEqual(abs(constrained.translation.height), limits.height + 0.000_001)
            XCTAssertGreaterThanOrEqual(constrained.rotation, -.pi)
            XCTAssertLessThan(constrained.rotation, .pi)
        }
    }

    func testMapEdgesCanReachViewportCenterAtEveryZoom() {
        let geometry = MapCameraGeometry(
            contentSize: CGSize(width: 1_200, height: 800),
            viewportSize: CGSize(width: 390, height: 844),
            fittedScale: 0.32
        )

        for zoom in [MapCameraTuning.venue.zoomRange.lowerBound, 8, 64] {
            for rotation in [CGFloat.zero, .pi / 4] {
                let camera = MapCamera(zoom: zoom, rotation: rotation)
                let limits = MapCameraMath.translationLimits(
                    camera: camera,
                    geometry: geometry,
                    tuning: .venue
                )
                let scale = geometry.fittedScale * zoom
                let cosine = abs(cos(rotation))
                let sine = abs(sin(rotation))
                let rotatedWidth = (geometry.contentSize.width * cosine
                    + geometry.contentSize.height * sine) * scale
                let rotatedHeight = (geometry.contentSize.width * sine
                    + geometry.contentSize.height * cosine) * scale

                XCTAssertGreaterThanOrEqual(limits.width, rotatedWidth / 2)
                XCTAssertGreaterThanOrEqual(limits.height, rotatedHeight / 2)
            }
        }
    }

    func testLiveOverscrollUsesResistanceBeforeSettling() {
        let geometry = MapCameraGeometry(
            contentSize: CGSize(width: 1_000, height: 700),
            viewportSize: CGSize(width: 390, height: 844),
            fittedScale: 0.39
        )
        let raw = MapCamera(translation: CGSize(width: 5_000, height: 5_000), zoom: 2)
        let strict = MapCameraMath.constrained(raw, geometry: geometry, tuning: .venue)
        let elastic = MapCameraMath.constrained(
            raw,
            geometry: geometry,
            tuning: .venue,
            allowsRubberBand: true
        )

        XCTAssertGreaterThan(elastic.translation.width, strict.translation.width)
        XCTAssertGreaterThan(elastic.translation.height, strict.translation.height)
        XCTAssertLessThan(elastic.translation.width, raw.translation.width)
        XCTAssertLessThan(elastic.translation.height, raw.translation.height)
    }

    func testCameraTransformRoundTripsContentPoints() {
        let camera = MapCamera(
            translation: CGSize(width: 84, height: -102),
            zoom: 7.5,
            rotation: 1.1
        )
        let transform = MapCameraMath.transform(camera: camera, geometry: generousGeometry)

        for point in [
            CGPoint.zero,
            CGPoint(x: 530, y: 720),
            CGPoint(x: 3_999, y: 2_999),
        ] {
            let roundTrip = point.applying(transform).applying(transform.inverted())
            XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.000_01)
            XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.000_01)
        }
    }

    func testTuningKeepsBlankEdgeAllowanceSmallAndCampusZoomPurposeful() {
        XCTAssertEqual(MapCameraTuning.venue.edgeMarginFraction, 0.08)
        XCTAssertEqual(MapCameraTuning.campus.edgeMarginFraction, 0.08)
        XCTAssertEqual(MapCameraTuning.venue.zoomRange, 0.9...64)
        XCTAssertEqual(MapCameraTuning.campus.zoomRange, 0.9...8)
    }

    private var generousGeometry: MapCameraGeometry {
        MapCameraGeometry(
            contentSize: CGSize(width: 4_000, height: 3_000),
            viewportSize: CGSize(width: 430, height: 932),
            fittedScale: 0.25
        )
    }

    private func anchors(in viewport: CGSize) -> [CGPoint] {
        [
            CGPoint(x: viewport.width / 2, y: viewport.height / 2),
            CGPoint(x: 40, y: 70),
            CGPoint(x: viewport.width - 35, y: 95),
            CGPoint(x: 58, y: viewport.height - 80),
            CGPoint(x: viewport.width - 45, y: viewport.height - 60),
        ]
    }
}
