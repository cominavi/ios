import SwiftUI

struct BigSightCampusView: View {
    let scene: BigSightCampusScene
    let onSelectVenue: (Int) -> Void

    @State private var camera = MapCamera()
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnifyState = CampusMagnifyState()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = geometry.size
            let effectiveCamera = MapCameraMath.applyingGesture(
                to: camera,
                pan: dragTranslation,
                magnification: magnifyState.magnification,
                magnificationAnchor: magnifyState.startLocation,
                rotationAnchor: magnifyState.startLocation,
                geometry: cameraGeometry(viewportSize: viewportSize),
                tuning: .campus,
                allowsRubberBand: true
            )
            let transform = MapCameraMath.transform(
                camera: effectiveCamera,
                geometry: cameraGeometry(viewportSize: viewportSize)
            )
            let renderedScale = fitScale(viewportSize: viewportSize) * effectiveCamera.zoom

            Canvas(opaque: true, colorMode: .nonLinear) { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(canvasBackground)
                )
                context.concatenate(transform)
                drawGrid(in: &context, renderedScale: renderedScale)
                for venue in scene.venues {
                    draw(venue: venue, in: &context, renderedScale: renderedScale)
                }
                drawOpenStreetMapFeatures(in: &context, renderedScale: renderedScale)
            }
            .contentShape(Rectangle())
            .gesture(panGesture(viewportSize: viewportSize))
            .simultaneousGesture(magnifyGesture(viewportSize: viewportSize))
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        selectVenue(at: value.location, transform: transform)
                    }
            )
            .overlay {
                ZStack {
                    ForEach(scene.connections) { connection in
                        connectionLabel(connection, transform: transform)
                    }
                    ForEach(scene.venues) { venue in
                        venueLabel(venue, transform: transform)
                    }
                    ForEach(scene.facilities) { facility in
                        facilityLabel(facility, transform: transform)
                    }
                    entrancePlazaLabel(transform: transform)
                }
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("campus-map-canvas")
            .accessibilityLabel("Tokyo Big Sight campus overview")
            .accessibilityValue(
                "\(scene.venues.count) venues and \(scene.connections.count) walking connections, "
                    + accessibilityCameraValue
            )
            .accessibilityHint("Tap a venue to open its table map")
            .overlay(alignment: .topTrailing) {
                northIndicator
                    .padding(.top, 112)
                    .padding(.trailing, MapChromeLayout.trailingInset)
            }
            .overlay(alignment: .bottom) {
                campusLegend
                    .safeAreaPadding(.bottom, 10)
                    .padding(.horizontal, 16)
            }
        }
        .onChange(of: scene.id) {
            camera = MapCamera()
        }
    }

    private var accessibilityCameraValue: String {
        #if DEBUG
            return String(
                format: "north up, zoom %.2f times, camera offset %.1f %.1f",
                camera.zoom,
                camera.translation.width,
                camera.translation.height
            )
        #else
            return "north up, zoom \(camera.zoom) times"
        #endif
    }

    private var northIndicator: some View {
        VStack(spacing: 2) {
            LucideIcon("location.north.fill")
                .font(.headline)
                .foregroundStyle(Color(red: 0.04, green: 0.43, blue: 0.27))
            Text("N")
                .font(.caption2.bold())
        }
        .padding(9)
        .background(.ultraThinMaterial, in: .circle)
        .accessibilityLabel("North is up")
    }

    private var campusLegend: some View {
        HStack(spacing: 8) {
            LucideLabel("100 m grid", icon: "ruler")
            Spacer(minLength: 8)
            Text("Tap a venue · Positions © OpenStreetMap contributors")
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(.regularMaterial, in: .capsule)
    }

    private func panGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let target = MapCameraMath.projectedPan(
                    from: camera,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    geometry: cameraGeometry(viewportSize: viewportSize),
                    tuning: .campus
                )
                withAnimation(.interpolatingSpring(duration: 0.42, bounce: 0.06)) {
                    camera = target
                }
            }
    }

    private func magnifyGesture(viewportSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .updating($magnifyState) { value, state, _ in
                state = CampusMagnifyState(
                    magnification: value.magnification,
                    startLocation: value.startLocation
                )
            }
            .onEnded { value in
                let projectedMagnification = MapCameraMath.projectedMagnification(
                    value.magnification,
                    velocity: value.velocity,
                    tuning: .campus
                )
                let target = MapCameraMath.applyingGesture(
                    to: camera,
                    magnification: projectedMagnification,
                    magnificationAnchor: value.startLocation,
                    rotationAnchor: value.startLocation,
                    geometry: cameraGeometry(viewportSize: viewportSize),
                    tuning: .campus,
                    allowsRubberBand: false
                )
                withAnimation(.interpolatingSpring(duration: 0.34, bounce: 0.05)) {
                    camera = target
                }
            }
    }

    private func drawGrid(in context: inout GraphicsContext, renderedScale: CGFloat) {
        let spacing: CGFloat = 100
        let minX = floor(scene.bounds.minX / spacing) * spacing
        let maxX = ceil(scene.bounds.maxX / spacing) * spacing
        let minY = floor(scene.bounds.minY / spacing) * spacing
        let maxY = ceil(scene.bounds.maxY / spacing) * spacing
        var path = Path()

        for x in stride(from: minX, through: maxX, by: spacing) {
            path.move(to: CGPoint(x: x, y: minY))
            path.addLine(to: CGPoint(x: x, y: maxY))
        }
        for y in stride(from: minY, through: maxY, by: spacing) {
            path.move(to: CGPoint(x: minX, y: y))
            path.addLine(to: CGPoint(x: maxX, y: y))
        }
        context.stroke(
            path,
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.055)),
            lineWidth: 1 / renderedScale
        )
    }

    private func drawOpenStreetMapFeatures(
        in context: inout GraphicsContext,
        renderedScale: CGFloat
    ) {
        for feature in scene.openStreetMapFeatures where feature.points.count > 1 {
            var path = Path()
            path.move(to: feature.points[0])
            for point in feature.points.dropFirst() {
                path.addLine(to: point)
            }

            switch feature.kind {
            case .connectingBridge:
                path.closeSubpath()
                context.fill(path, with: .color(bridgeFill))
                context.stroke(
                    path,
                    with: .color(bridgeStroke),
                    style: StrokeStyle(
                        lineWidth: 1.1 / renderedScale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            case .footway, .steps:
                context.stroke(
                    path,
                    with: .color(pedestrianUnderlay),
                    style: StrokeStyle(
                        lineWidth: (feature.isIndoor || feature.isCovered ? 3.4 : 2.8)
                            / renderedScale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                context.stroke(
                    path,
                    with: .color(feature.kind == .steps ? pedestrianSteps : pedestrianFootway),
                    style: StrokeStyle(
                        lineWidth: (feature.kind == .steps ? 1.45 : 1.25) / renderedScale,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: feature.kind == .steps
                            ? [1.4 / renderedScale, 1.1 / renderedScale]
                            : []
                    )
                )
            }
        }
    }

    private func draw(
        venue: BigSightVenuePlacement,
        in context: inout GraphicsContext,
        renderedScale: CGFloat
    ) {
        let tint = venueColor(venue.kind)
        context.drawLayer { venueContext in
            venueContext.concatenate(venue.transform)
            let venueBounds = CGRect(origin: .zero, size: venue.scene.size)
            venueContext.fill(Path(venueBounds), with: .color(mapSurface))

            for table in venue.scene.tables {
                let rect = CGRect(origin: table.origin, size: venue.scene.tableSize)
                venueContext.fill(Path(rect), with: .color(tint.opacity(0.35)))
                venueContext.stroke(
                    Path(rect),
                    with: .color(tint.opacity(0.72)),
                    lineWidth: 3
                )
            }

            venueContext.stroke(
                Path(venueBounds),
                with: .color(tint),
                lineWidth: 12
            )
        }

        let dotSize = 7 / renderedScale
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: venue.center.x - dotSize / 2,
                    y: venue.center.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )),
            with: .color(tint)
        )
        context.stroke(
            Path(
                ellipseIn: CGRect(
                    x: venue.center.x - dotSize / 2,
                    y: venue.center.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )),
            with: .color(markerUnderlay),
            lineWidth: 2 / renderedScale
        )

    }

    private func venueLabel(
        _ venue: BigSightVenuePlacement,
        transform: CGAffineTransform
    ) -> some View {
        Label {
            Text(venue.kind.displayName)
        } icon: {
            BigSightVenueBadge(icon: venue.kind.icon)
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.primary)
        .labelStyle(BigSightMapLabelStyle(iconSize: 18))
        .padding(.horizontal, 7)
        .frame(height: 25)
        .background(markerSurface, in: .capsule)
        .overlay {
            Capsule()
                .stroke(venueColor(venue.kind).opacity(0.55), lineWidth: 1)
        }
        .position(venue.center.applying(transform))
        .offset(y: -21)
    }

    private func facilityLabel(
        _ facility: BigSightFacilityLocation,
        transform: CGAffineTransform
    ) -> some View {
        Label {
            if camera.zoom >= max(facility.minimumZoom, 1.8) {
                Text(facility.name)
            }
        } icon: {
            facilityIcon(facility.kind.icon)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.primary)
        .labelStyle(BigSightMapLabelStyle(iconSize: 17))
        .padding(4)
        .background(markerSurface, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.gray.opacity(0.22), lineWidth: 0.5)
        }
        .position(facility.center.applying(transform))
        .opacity(camera.zoom >= facility.minimumZoom ? 1 : 0)
    }

    private func facilityIcon(_ icon: BigSightMapIcon) -> some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(mapIconColor(icon))
    }

    private func mapIconColor(_ icon: BigSightMapIcon) -> Color {
        switch icon.accent {
        case .ink: Color(red: 0.13, green: 0.09, blue: 0.08)
        case .red: Color(red: 0.85, green: 0.04, blue: 0.16)
        case .green: Color(red: 0, green: 0.60, blue: 0.24)
        case .blue: Color(red: 0, green: 0.34, blue: 0.63)
        case .amber: Color(red: 0.82, green: 0.52, blue: 0.02)
        case .taupe: Color(red: 0.47, green: 0.42, blue: 0.36)
        }
    }

    private func entrancePlazaLabel(transform: CGAffineTransform) -> some View {
        LucideLabel("Entrance Plaza", icon: "figure.walk")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(red: 0.04, green: 0.43, blue: 0.27))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(markerSurface, in: .capsule)
            .position(
                BigSightCampusLayout.project(BigSightCampusLayout.entrancePlaza).applying(transform)
            )
            .offset(x: 165, y: -18)
    }

    private func connectionLabel(
        _ connection: BigSightCampusConnection,
        transform: CGAffineTransform
    ) -> some View {
        let label =
            camera.zoom > 1.35
            ? "\(connection.name) · ≈\(connection.distanceMeters) m"
            : "≈\(connection.distanceMeters) m"
        let point = connectionLabelPoint(connection).applying(transform)
        let offset = connectionLabelOffset(connection)

        return Text(label)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(markerSurface.opacity(0.96), in: .capsule)
            .position(point)
            .offset(offset)
    }

    private func connectionLabelPoint(_ connection: BigSightCampusConnection) -> CGPoint {
        switch connection.id {
        case "east-link-space":
            connection.points[1]
        case "east-entrance-concourse":
            connection.points[2]
        case "entrance-west-atrium":
            connection.points[1]
        case "entrance-south-concourse":
            midpoint(connection.points[1], connection.points[2])
        default:
            connection.points[connection.points.count / 2]
        }
    }

    private func connectionLabelOffset(_ connection: BigSightCampusConnection) -> CGSize {
        switch connection.id {
        case "east-link-space": CGSize(width: -48, height: -48)
        case "east-entrance-concourse": CGSize(width: 38, height: -18)
        case "entrance-west-atrium": CGSize(width: 45, height: 16)
        case "entrance-south-concourse": CGSize(width: -45, height: 16)
        default: .zero
        }
    }

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private func selectVenue(at screenPoint: CGPoint, transform: CGAffineTransform) {
        let campusPoint = screenPoint.applying(transform.inverted())
        for venue in scene.venues.reversed() {
            let venuePoint = campusPoint.applying(venue.transform.inverted())
            if CGRect(origin: .zero, size: venue.scene.size).contains(venuePoint) {
                onSelectVenue(venue.id)
                return
            }
        }
    }

    private func venueColor(_ kind: BigSightVenuePlacement.Kind) -> Color {
        switch kind {
        case .east123: Color(red: 0.03, green: 0.56, blue: 0.35)
        case .east456: Color(red: 0.02, green: 0.45, blue: 0.58)
        case .east7: Color(red: 0.20, green: 0.47, blue: 0.78)
        case .west: Color(red: 0.71, green: 0.39, blue: 0.19)
        case .south: Color(red: 0.64, green: 0.31, blue: 0.60)
        }
    }

    private var canvasBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.063, blue: 0.071)
            : Color(red: 0.925, green: 0.94, blue: 0.935)
    }

    private var mapSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.115, blue: 0.125)
            : Color.white.opacity(0.96)
    }

    private var markerSurface: Color {
        Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.94 : 0.9)
    }

    private var markerUnderlay: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.92)
    }

    private var pedestrianUnderlay: Color {
        colorScheme == .dark ? Color.black.opacity(0.72) : Color.white.opacity(0.86)
    }

    private var pedestrianFootway: Color {
        colorScheme == .dark ? Color.white.opacity(0.76) : Color.black.opacity(0.72)
    }

    private var pedestrianSteps: Color {
        colorScheme == .dark
            ? Color(red: 0.96, green: 0.57, blue: 0.28).opacity(0.9)
            : Color(red: 0.70, green: 0.34, blue: 0.13).opacity(0.84)
    }

    private var bridgeFill: Color {
        colorScheme == .dark ? Color(white: 0.25).opacity(0.96) : Color(white: 0.86).opacity(0.96)
    }

    private var bridgeStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.36)
    }

    private func fitScale(viewportSize: CGSize) -> CGFloat {
        min(
            viewportSize.width / scene.bounds.width,
            viewportSize.height / scene.bounds.height
        ) * 0.9
    }

    private func cameraGeometry(viewportSize: CGSize) -> MapCameraGeometry {
        MapCameraGeometry(
            contentSize: scene.bounds.size,
            contentCenter: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY),
            viewportSize: viewportSize,
            fittedScale: fitScale(viewportSize: viewportSize)
        )
    }
}

private struct BigSightMapLabelStyle: LabelStyle {
    let iconSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .frame(width: iconSize, height: iconSize)
            configuration.title
        }
    }
}

private struct CampusMagnifyState: Equatable {
    var magnification: CGFloat = 1
    var startLocation: CGPoint = .zero
}
