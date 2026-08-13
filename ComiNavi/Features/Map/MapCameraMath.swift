import CoreGraphics

struct MapCamera: Equatable {
    var translation: CGSize = .zero
    var zoom: CGFloat = 1
    var rotation: CGFloat = 0
}

struct MapCameraGeometry: Equatable {
    let contentSize: CGSize
    let contentCenter: CGPoint
    let viewportSize: CGSize
    let fittedScale: CGFloat

    init(
        contentSize: CGSize,
        contentCenter: CGPoint? = nil,
        viewportSize: CGSize,
        fittedScale: CGFloat
    ) {
        self.contentSize = contentSize
        self.contentCenter = contentCenter ?? CGPoint(
            x: contentSize.width / 2,
            y: contentSize.height / 2
        )
        self.viewportSize = viewportSize
        self.fittedScale = fittedScale
    }
}

struct MapCameraTuning: Equatable {
    /// Zoom relative to the fitted content scale, not an absolute pixel scale.
    let zoomRange: ClosedRange<CGFloat>
    /// Additional blank edge retained after allowing any map point to reach the viewport center,
    /// as a fraction of the shorter viewport side.
    let edgeMarginFraction: CGFloat
    /// Maximum inertial travel after release as a fraction of the shorter viewport side.
    let maximumPanProjectionFraction: CGFloat
    let maximumZoomVelocity: CGFloat
    let zoomVelocityInfluence: CGFloat
    let maximumRotationVelocity: CGFloat
    let rotationVelocityInfluence: CGFloat

    static let venue = MapCameraTuning(
        // Preserve a little overview context while allowing individual circle cuts to become legible.
        zoomRange: 0.9...64,
        // About 31 points on a 390-point phone: visible feedback without losing the floor plan.
        edgeMarginFraction: 0.08,
        // A fast fling advances less than half a screen, keeping dense aisle navigation controlled.
        maximumPanProjectionFraction: 0.48,
        maximumZoomVelocity: 3,
        zoomVelocityInfluence: 0.055,
        maximumRotationVelocity: 3,
        rotationVelocityInfluence: 0.035
    )

    static let campus = MapCameraTuning(
        // The campus has far less detail than a hall, so extreme zoom adds no useful information.
        zoomRange: 0.9...8,
        edgeMarginFraction: 0.08,
        maximumPanProjectionFraction: 0.42,
        maximumZoomVelocity: 2.5,
        zoomVelocityInfluence: 0.05,
        maximumRotationVelocity: 0,
        rotationVelocityInfluence: 0
    )
}

enum MapCameraMath {
    /// The point that remains visible when bottom chrome, such as a map sheet,
    /// obscures part of the full rendering surface.
    static func visibleViewportCenter(
        viewportSize: CGSize,
        bottomInset: CGFloat
    ) -> CGPoint {
        let visibleBottom = max(0, viewportSize.height - max(0, bottomInset))
        return CGPoint(x: viewportSize.width / 2, y: visibleBottom / 2)
    }

    /// Positions a SpriteKit camera so `scenePoint` renders at a requested
    /// UIKit screen point, including when the camera is scaled and rotated.
    static func spriteKitCameraPosition(
        focusing scenePoint: CGPoint,
        at screenPoint: CGPoint,
        viewportSize: CGSize,
        cameraScale: CGFloat,
        cameraRotation: CGFloat
    ) -> CGPoint {
        let viewOffset = CGPoint(
            x: screenPoint.x - viewportSize.width / 2,
            y: screenPoint.y - viewportSize.height / 2
        )
        let cameraLocalOffset = CGPoint(
            x: viewOffset.x * cameraScale,
            y: -viewOffset.y * cameraScale
        )
        let cosine = cos(cameraRotation)
        let sine = sin(cameraRotation)
        let sceneOffset = CGPoint(
            x: cameraLocalOffset.x * cosine - cameraLocalOffset.y * sine,
            y: cameraLocalOffset.x * sine + cameraLocalOffset.y * cosine
        )
        return CGPoint(
            x: scenePoint.x - sceneOffset.x,
            y: scenePoint.y - sceneOffset.y
        )
    }

    /// The north indicator rotates with map content so its tip continues to
    /// point toward geographic north on screen. Camera APIs often expose the
    /// inverse bearing, which is not the angle the indicator itself needs.
    static func northIndicatorRotation(mapRotation: CGFloat) -> CGFloat {
        normalizedRotation(mapRotation)
    }

    /// Produces the camera displayed while fingers are on screen. Scaling and
    /// rotation are both anchored to their gesture origins, while translation
    /// uses a UIKit-style rubber band beyond the strict content limits.
    static func applyingGesture(
        to camera: MapCamera,
        pan: CGSize = .zero,
        magnification: CGFloat = 1,
        magnificationAnchor: CGPoint,
        rotation: CGFloat = 0,
        rotationAnchor: CGPoint,
        geometry: MapCameraGeometry,
        tuning: MapCameraTuning,
        allowsRubberBand: Bool
    ) -> MapCamera {
        let targetZoom = clamp(camera.zoom * magnification, to: tuning.zoomRange)
        let appliedMagnification = camera.zoom == 0 ? 1 : targetZoom / camera.zoom
        var targetTranslation = translation(
            camera.translation,
            scaledBy: appliedMagnification,
            around: magnificationAnchor,
            viewportSize: geometry.viewportSize
        )
        targetTranslation = translation(
            targetTranslation,
            rotatedBy: rotation,
            around: rotationAnchor,
            viewportSize: geometry.viewportSize
        ) + pan

        var result = MapCamera(
            translation: targetTranslation,
            zoom: targetZoom,
            rotation: camera.rotation + rotation
        )
        result.translation = constrainedTranslation(
            result.translation,
            camera: result,
            geometry: geometry,
            tuning: tuning,
            allowsRubberBand: allowsRubberBand
        )
        return result
    }

    static func constrained(
        _ camera: MapCamera,
        geometry: MapCameraGeometry,
        tuning: MapCameraTuning,
        allowsRubberBand: Bool = false
    ) -> MapCamera {
        var result = camera
        result.zoom = clamp(result.zoom, to: tuning.zoomRange)
        result.rotation = normalizedRotation(result.rotation)
        result.translation = constrainedTranslation(
            result.translation,
            camera: result,
            geometry: geometry,
            tuning: tuning,
            allowsRubberBand: allowsRubberBand
        )
        return result
    }

    static func projectedPan(
        from camera: MapCamera,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        geometry: MapCameraGeometry,
        tuning: MapCameraTuning
    ) -> MapCamera {
        let residual = predictedEndTranslation - translation
        let maximumProjection = min(
            geometry.viewportSize.width,
            geometry.viewportSize.height
        ) * tuning.maximumPanProjectionFraction
        let projectedResidual = residual.limited(to: maximumProjection)
        var result = camera
        result.translation = camera.translation + translation + projectedResidual
        return constrained(result, geometry: geometry, tuning: tuning)
    }

    static func projectedMagnification(
        _ magnification: CGFloat,
        velocity: CGFloat,
        tuning: MapCameraTuning
    ) -> CGFloat {
        let velocity = min(max(velocity, -tuning.maximumZoomVelocity), tuning.maximumZoomVelocity)
        return magnification * exp(velocity * tuning.zoomVelocityInfluence)
    }

    static func projectedRotation(
        _ rotation: CGFloat,
        velocity: CGFloat,
        tuning: MapCameraTuning
    ) -> CGFloat {
        let velocity = min(
            max(velocity, -tuning.maximumRotationVelocity),
            tuning.maximumRotationVelocity
        )
        return rotation + velocity * tuning.rotationVelocityInfluence
    }

    static func transform(
        camera: MapCamera,
        geometry: MapCameraGeometry
    ) -> CGAffineTransform {
        let scale = geometry.fittedScale * camera.zoom
        return CGAffineTransform.identity
            .translatedBy(
                x: geometry.viewportSize.width / 2 + camera.translation.width,
                y: geometry.viewportSize.height / 2 + camera.translation.height
            )
            .rotated(by: camera.rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -geometry.contentCenter.x, y: -geometry.contentCenter.y)
    }

    /// Adjusts a center-relative camera translation so the content currently
    /// beneath `anchor` remains beneath that same screen point after scaling.
    static func translation(
        _ translation: CGSize,
        scaledBy scale: CGFloat,
        around anchor: CGPoint,
        viewportSize: CGSize
    ) -> CGSize {
        guard scale != 1 else { return translation }

        let center = viewportCenter(viewportSize)
        return CGSize(
            width: anchor.x - center.x
                + (center.x + translation.width - anchor.x) * scale,
            height: anchor.y - center.y
                + (center.y + translation.height - anchor.y) * scale
        )
    }

    /// Adjusts translation so rotation occurs around a screen-space point
    /// instead of around the center of the viewport.
    static func translation(
        _ translation: CGSize,
        rotatedBy angle: CGFloat,
        around anchor: CGPoint,
        viewportSize: CGSize
    ) -> CGSize {
        guard angle != 0 else { return translation }

        let center = viewportCenter(viewportSize)
        let x = center.x + translation.width - anchor.x
        let y = center.y + translation.height - anchor.y
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGSize(
            width: anchor.x - center.x + x * cosine - y * sine,
            height: anchor.y - center.y + x * sine + y * cosine
        )
    }

    static func translationLimits(
        camera: MapCamera,
        geometry: MapCameraGeometry,
        tuning: MapCameraTuning
    ) -> CGSize {
        let scale = geometry.fittedScale * camera.zoom
        let cosine = abs(cos(camera.rotation))
        let sine = abs(sin(camera.rotation))
        let rotatedWidth = (geometry.contentSize.width * cosine
            + geometry.contentSize.height * sine) * scale
        let rotatedHeight = (geometry.contentSize.width * sine
            + geometry.contentSize.height * cosine) * scale
        let margin = min(
            geometry.viewportSize.width,
            geometry.viewportSize.height
        ) * tuning.edgeMarginFraction
        // Use the full rotated content extent instead of keeping the content
        // rectangle inside the viewport. This lets a circle at any map edge
        // be placed at the center of the screen at every zoom level.
        return CGSize(
            width: rotatedWidth / 2 + margin,
            height: rotatedHeight / 2 + margin
        )
    }

    static func normalizedRotation(_ radians: CGFloat) -> CGFloat {
        guard radians.isFinite else { return 0 }
        let fullTurn = CGFloat.pi * 2
        var result = radians.truncatingRemainder(dividingBy: fullTurn)
        if result >= .pi { result -= fullTurn }
        if result < -.pi { result += fullTurn }
        return result
    }

    private static func constrainedTranslation(
        _ translation: CGSize,
        camera: MapCamera,
        geometry: MapCameraGeometry,
        tuning: MapCameraTuning,
        allowsRubberBand: Bool
    ) -> CGSize {
        let limits = translationLimits(camera: camera, geometry: geometry, tuning: tuning)
        if allowsRubberBand {
            return CGSize(
                width: rubberBanded(
                    translation.width,
                    limit: limits.width,
                    dimension: geometry.viewportSize.width
                ),
                height: rubberBanded(
                    translation.height,
                    limit: limits.height,
                    dimension: geometry.viewportSize.height
                )
            )
        }
        return CGSize(
            width: min(max(translation.width, -limits.width), limits.width),
            height: min(max(translation.height, -limits.height), limits.height)
        )
    }

    private static func rubberBanded(
        _ value: CGFloat,
        limit: CGFloat,
        dimension: CGFloat
    ) -> CGFloat {
        let overshoot = abs(value) - limit
        guard overshoot > 0, dimension > 0 else { return value }
        let resisted = dimension * (1 - 1 / (overshoot * 0.38 / dimension + 1))
        return value.sign == .minus ? -(limit + resisted) : limit + resisted
    }

    private static func viewportCenter(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private static func clamp(
        _ value: CGFloat,
        to range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }

    func limited(to maximumLength: CGFloat) -> CGSize {
        let length = hypot(width, height)
        guard length > maximumLength, length > 0 else { return self }
        let scale = maximumLength / length
        return CGSize(width: width * scale, height: height * scale)
    }
}
