//
//  SignInView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SpriteKit
import SwiftUI
import Toast

enum DemoState {
    case anonymous
    case authenticating
}

class SignInViewModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var state: DemoState = .anonymous
    private var authenticationSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }

    func signIn() {
        self.state = .authenticating

        Task {
            do {
                try await self.doSignIn()
                try await self.populateUserInfo()
            } catch {
                self.state = .anonymous
                AppData.userState.user = nil
                // see if it is a user cancelled error
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    return
                }

                Toast.showError("Failed to authenticate", subtitle: error.localizedDescription)
            }
        }
    }

    func doSignIn() async throws {
        let environment = AppEnvironment.current
        let oauthState = UUID().uuidString
        var authURLComponents = URLComponents(
            url: environment.circlems.authenticationBaseURL.appending(path: "OAuth2/"),
            resolvingAgainstBaseURL: false
        )!
        authURLComponents.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: environment.circlemsClientID),
            URLQueryItem(name: "redirect_uri", value: environment.oauthRedirectURL.absoluteString),
            URLQueryItem(name: "scope", value: "circle_read favorite_read favorite_write user_info"),
            URLQueryItem(name: "state", value: oauthState),
        ]
        guard let authURL = authURLComponents.url else {
            preconditionFailure("Failed to construct the Circle.ms authorization URL.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: environment.oauthCallbackScheme
            ) { responseURL, error in
                self.authenticationSession = nil
                if let error = error {
                    return continuation.resume(throwing: error)
                }
                guard let url = responseURL else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }
                guard url.scheme == environment.oauthCallbackScheme,
                      url.host == "oauth",
                      url.path == "/circlems/landing"
                else {
                    continuation.resume(throwing: URLError(.redirectToNonExistentLocation))
                    return
                }
                guard let status = url.queryValue(for: "status"), status == "succeeded" else {
                    let errorCode = url.queryValue(for: "error") ?? "unknown"
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to authenticate: \(errorCode)"]))
                }
                guard oauthState == url.queryValue(for: "state") else {
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "OAuth state mismatch"]))
                }
                guard let tokenType = url.queryValue(for: "token_type"), tokenType == "Bearer" else {
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported token type"]))
                }
                guard let accessToken = url.queryValue(for: "access_token") else {
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get access_token from redirected URL"]))
                }
                guard let refreshToken = url.queryValue(for: "refresh_token") else {
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get refresh_token from redirected URL"]))
                }
                guard let expiresInSecondsStr = url.queryValue(for: "expires_in"), let expiresInSeconds = Int(expiresInSecondsStr) else {
                    return continuation.resume(throwing: NSError(domain: "SignInViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get expires_in from redirected URL"]))
                }

                AppData.userState.user = User(
                    accessToken: accessToken,
                    accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(expiresInSeconds)),
                    refreshToken: refreshToken
                )

                return continuation.resume()
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.authenticationSession = session
            session.start()
        }
    }

    func populateUserInfo() async throws {
        let userInfo = try await CirclemsAPI.getUserInfo()
        debugPrint(userInfo)
        let newUser = User(
            accessToken: AppData.userState.user?.accessToken,
            accessTokenExpiresAt: AppData.userState.user?.accessTokenExpiresAt,
            refreshToken: AppData.userState.user?.refreshToken,
            userId: userInfo.response.pid,
            nickname: userInfo.response.nickname,
            preferenceR18Enabled: userInfo.response.r18 == 1 ? true : false
        )
        AppData.userState.user = newUser
    }
}

struct SignInView: View {
    @ScaledMetric(relativeTo: .title) private var logoSize = 60.0
    @StateObject private var vm = SignInViewModel()

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandMark

                    Spacer(minLength: 80)

                    hero

                    loginButton
                        .padding(.top, 48)
                }
                .frame(maxWidth: 620, minHeight: max(0, proxy.size.height - 48), alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .background {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                ConventionFloorBackdrop()
            }
        }
    }

    private var brandMark: some View {
        LogoShape()
            .foregroundStyle(.primary)
            .frame(width: logoSize, height: logoSize)
            .accessibilityLabel("ComiNavi")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to")
                .font(.headline)
                .foregroundStyle(.secondary)

            Group {
                Text("ComiNavi")
                    .foregroundStyle(Color.accentColor)
                    +
                    Text("!")
                    .foregroundStyle(.primary)
            }
            .font(.system(.largeTitle, design: .rounded, weight: .bold))

            Text("Find circles. Plan your route.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var loginButton: some View {
        if #available(iOS 26.0, *) {
            loginButtonContent
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .tint(.accentColor)
        } else {
            loginButtonContent
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .tint(.accentColor)
        }
    }

    private var loginButtonContent: some View {
        Button(action: vm.signIn) {
            HStack(spacing: 10) {
                if vm.state == .authenticating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black.opacity(0.82))

                    Text("Authenticating...")
                } else {
                    Text("Login via circle.ms")

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
            }
            .font(.headline)
            .foregroundStyle(.black.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 8)
            .contentTransition(.opacity)
        }
        .disabled(vm.state == .authenticating)
        .accessibilityHint("Tap to log in")
        .animation(.easeInOut(duration: 0.2), value: vm.state == .authenticating)
    }

}

private struct ConventionFloorBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var scene = ConventionFloorScene()

    var body: some View {
        SpriteView(
            scene: scene,
            isPaused: accessibilityReduceMotion,
            preferredFramesPerSecond: 30,
            options: [
                .allowsTransparency,
                .ignoresSiblingOrder,
                .shouldCullNonVisibleNodes,
            ]
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
        .onChange(of: colorScheme, initial: true) { _, newColorScheme in
            scene.setVeilColor(for: newColorScheme)
        }
    }
}

@MainActor
private final class ConventionFloorScene: SKScene {
    private let smallAisleCrowdSpacing: CGFloat = 5.5
    private let bigAisleCrowdSpacing: CGFloat = 2.6
    private let deskLineWidth: CGFloat = 1.45
    private let visitorDiameterRange: ClosedRange<CGFloat> = 2.2 ... 3.2
    private let maximumVisitorRadius: CGFloat = 1.6
    private let tableStopOffset: CGFloat = 3.6
    private let trackedUserDiameter: CGFloat = 6.2
    private let trackedUserSpeed: CGFloat = 5.4
    private let leftTrafficProbability: CGFloat = 0.84
    private let veilOpacity: CGFloat = 0.78

    private struct Metrics {
        let tableShortSide: CGFloat
        let tableLongSide: CGFloat
        let tableSpacing: CGFloat
        let tablesPerBank: Int
        let deskColumnsPerBlock: Int
        let endCapGap: CGFloat
        let narrowAisle: CGFloat
        let bigAisle: CGFloat
        let blockWidth: CGFloat
        let blockHeight: CGFloat
        let horizontalStride: CGFloat
        let verticalStride: CGFloat

        init(canvasWidth: CGFloat) {
            tableShortSide = min(max(canvasWidth / 72, 4.6), 6.4)
            tableLongSide = tableShortSide * 2.65
            tableSpacing = tableShortSide * 0.32
            tablesPerBank = 10
            deskColumnsPerBlock = 2

            endCapGap = tableShortSide * 2
            narrowAisle = tableLongSide * 1.2
            bigAisle = tableLongSide * 3.25
            blockWidth = tableLongSide * 2 + endCapGap

            let bankLength = CGFloat(tablesPerBank) * tableLongSide
                + CGFloat(tablesPerBank - 1) * tableSpacing
            blockHeight = bankLength + (tableShortSide + tableSpacing) * 2
            horizontalStride = blockWidth + narrowAisle
            verticalStride = blockHeight + bigAisle
        }
    }

    private enum WalkDirection: CaseIterable {
        case north
        case east
        case south
        case west

        var columnOffset: Int {
            switch self {
            case .east: 1
            case .west: -1
            case .north, .south: 0
            }
        }

        var rowOffset: Int {
            switch self {
            case .north: 1
            case .south: -1
            case .east, .west: 0
            }
        }

        var vector: CGVector {
            CGVector(dx: CGFloat(columnOffset), dy: CGFloat(rowOffset))
        }

        var opposite: WalkDirection {
            switch self {
            case .north: .south
            case .east: .west
            case .south: .north
            case .west: .east
            }
        }
    }

    private enum UserSegmentCompletion {
        case arrived(column: Int, row: Int, incoming: WalkDirection)
        case exited(column: Int, row: Int, outgoing: WalkDirection)
    }

    private struct UserSegment {
        let start: CGPoint
        let control: CGPoint?
        let end: CGPoint
        let length: CGFloat
        let completion: UserSegmentCompletion
    }

    private struct DeskStop {
        let aisleCenterX: CGFloat
        let y: CGFloat
        let stopPoint: CGPoint
    }

    private struct CrowdContinuation {
        let destinationColumn: Int
        let destinationRow: Int
        let incoming: WalkDirection
        let destinationPoint: CGPoint
    }

    private struct DeskVisit {
        let lanePoint: CGPoint
        let stopPoint: CGPoint
        let continuation: CrowdContinuation
        let dwellDuration: TimeInterval
    }

    private enum CrowdSegmentCompletion {
        case arrived(column: Int, row: Int, incoming: WalkDirection)
        case exited(column: Int, row: Int, outgoing: WalkDirection, laneSeed: Int)
        case reachedDeskLane(DeskVisit)
        case reachedDesk(DeskVisit)
        case returnedFromDesk(DeskVisit)
    }

    private struct CrowdSegment {
        let start: CGPoint
        let control: CGPoint?
        let end: CGPoint
        let length: CGFloat
        let completion: CrowdSegmentCompletion
    }

    private enum CrowdState {
        case moving(segment: CrowdSegment, distance: CGFloat)
        case dwelling(visit: DeskVisit, remaining: TimeInterval, elapsed: TimeInterval)
    }

    private struct CrowdAgent {
        let node: SKSpriteNode
        var state: CrowdState
        let speed: CGFloat
        let seed: Int
        var decisions: Int
        var deskVisitCooldown: Int
    }

    private var floorRoot = SKNode()
    private var agents: [CrowdAgent] = []
    private var deskStops: [DeskStop] = []
    private var previousUpdateTime: TimeInterval?
    private var activeMetrics: Metrics?

    private var cameraNode = SKCameraNode()
    private var veilNode = SKSpriteNode()
    private var trackedUserNode = SKSpriteNode()
    private var trackedUserSegment: UserSegment?
    private var trackedUserSegmentDistance: CGFloat = 0
    private var trackedUserTangent = CGVector(dx: 1, dy: 0)
    private var intersectionXs: [CGFloat] = []
    private var intersectionYs: [CGFloat] = []
    private var allowedUserColumns: ClosedRange<Int> = 0 ... 0
    private var allowedUserRows: ClosedRange<Int> = 0 ... 0
    private var turnRadius: CGFloat = 5
    private var cameraHasSettled = false

    private lazy var visitorTexture: SKTexture = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }()

    override init(size: CGSize) {
        super.init(size: size)
        configureScene()
    }

    override convenience init() {
        self.init(size: CGSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        view.isOpaque = false
        rebuildFloor()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width > 1, size.height > 1 else { return }
        rebuildFloor()
    }

    override func update(_ currentTime: TimeInterval) {
        if previousUpdateTime == nil { previousUpdateTime = currentTime }
        let deltaTime = min(max(currentTime - (previousUpdateTime ?? currentTime), 0), 1.0 / 15.0)
        previousUpdateTime = currentTime
        updateAgents(deltaTime: deltaTime)
        updateTrackedUser(deltaTime: deltaTime)
        updateCamera(deltaTime: deltaTime)
    }

    private func configureScene() {
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    private func rebuildFloor() {
        removeAllChildren()
        agents.removeAll(keepingCapacity: true)
        deskStops.removeAll(keepingCapacity: true)
        previousUpdateTime = nil
        trackedUserSegment = nil
        trackedUserSegmentDistance = 0
        cameraHasSettled = false
        floorRoot = SKNode()
        floorRoot.position = CGPoint(x: size.width / 2, y: size.height / 2)
        floorRoot.zRotation = -.pi / 12
        addChild(floorRoot)

        let metrics = Metrics(canvasWidth: size.width)
        activeMetrics = metrics
        assertFloorClearances(metrics: metrics)

        let rotation = abs(floorRoot.zRotation)
        let projectedWidth = abs(size.width * cos(rotation))
            + abs(size.height * sin(rotation))
        let projectedHeight = abs(size.width * sin(rotation))
            + abs(size.height * cos(rotation))
        let halfWorldWidth = projectedWidth / 2 + metrics.horizontalStride
        let halfWorldHeight = projectedHeight / 2 + metrics.verticalStride
        let crowdBounds = CGRect(
            x: -projectedWidth / 2 - metrics.horizontalStride,
            y: -projectedHeight / 2 - metrics.verticalStride,
            width: projectedWidth + metrics.horizontalStride * 2,
            height: projectedHeight + metrics.verticalStride * 2
        )
        let bounds = CGRect(
            x: -halfWorldWidth,
            y: -halfWorldHeight,
            width: halfWorldWidth * 2,
            height: halfWorldHeight * 2
        )
        let deskPath = CGMutablePath()

        intersectionXs.removeAll(keepingCapacity: true)
        var intersectionBlockX = bounds.minX
        while intersectionBlockX < bounds.maxX {
            intersectionXs.append(
                intersectionBlockX + metrics.blockWidth + metrics.narrowAisle / 2
            )
            intersectionBlockX += metrics.horizontalStride
        }

        intersectionYs.removeAll(keepingCapacity: true)
        var intersectionBandY = bounds.minY
        while intersectionBandY < bounds.maxY {
            intersectionYs.append(
                intersectionBandY + metrics.blockHeight + metrics.bigAisle / 2
            )
            intersectionBandY += metrics.verticalStride
        }

        var bandY = bounds.minY
        while bandY < bounds.maxY {
            var blockX = bounds.minX

            while blockX < bounds.maxX {
                let origin = CGPoint(x: blockX, y: bandY)
                addBoothBlock(
                    to: deskPath,
                    origin: origin,
                    metrics: metrics
                )
                blockX += metrics.horizontalStride
            }

            bandY += metrics.verticalStride
        }

        let desks = SKShapeNode(path: deskPath)
        desks.strokeColor = .secondaryLabel
        desks.lineWidth = deskLineWidth
        desks.fillColor = .clear
        desks.zPosition = 1
        floorRoot.addChild(desks)

        populateCrowd(metrics: metrics, visibleBounds: crowdBounds)
        configureCameraAndTrackedUser(metrics: metrics)
    }

    private func addBoothBlock(
        to path: CGMutablePath,
        origin: CGPoint,
        metrics: Metrics
    ) {
        let rightBankX = origin.x + metrics.blockWidth - metrics.tableShortSide
        let bankStartY = origin.y + metrics.tableShortSide + metrics.tableSpacing

        for table in 0 ..< metrics.tablesPerBank {
            let tableY = bankStartY
                + CGFloat(table) * (metrics.tableLongSide + metrics.tableSpacing)
            path.addRect(
                CGRect(
                    x: origin.x,
                    y: tableY,
                    width: metrics.tableShortSide,
                    height: metrics.tableLongSide
                )
            )
            path.addRect(
                CGRect(
                    x: rightBankX,
                    y: tableY,
                    width: metrics.tableShortSide,
                    height: metrics.tableLongSide
                )
            )

            let tableCenterY = tableY + metrics.tableLongSide / 2
            deskStops.append(
                DeskStop(
                    aisleCenterX: origin.x - metrics.narrowAisle / 2,
                    y: tableCenterY,
                    stopPoint: CGPoint(
                        x: origin.x - tableStopOffset,
                        y: tableCenterY
                    )
                )
            )
            deskStops.append(
                DeskStop(
                    aisleCenterX: origin.x + metrics.blockWidth + metrics.narrowAisle / 2,
                    y: tableCenterY,
                    stopPoint: CGPoint(
                        x: rightBankX + metrics.tableShortSide + tableStopOffset,
                        y: tableCenterY
                    )
                )
            )
        }

        for endY in [origin.y, origin.y + metrics.blockHeight - metrics.tableShortSide] {
            path.addRect(
                CGRect(
                    x: origin.x,
                    y: endY,
                    width: metrics.tableLongSide,
                    height: metrics.tableShortSide
                )
            )
            path.addRect(
                CGRect(
                    x: origin.x + metrics.blockWidth - metrics.tableLongSide,
                    y: endY,
                    width: metrics.tableLongSide,
                    height: metrics.tableShortSide
                )
            )
        }
    }

    private func populateCrowd(metrics: Metrics, visibleBounds: CGRect) {
        guard intersectionXs.count >= 2, intersectionYs.count >= 2 else { return }

        for row in intersectionYs.indices {
            let rowY = intersectionYs[row]
            guard visibleBounds.minY ... visibleBounds.maxY ~= rowY else { continue }

            let visitorCount = max(
                180,
                Int((intersectionXs.last! - intersectionXs.first!) / bigAisleCrowdSpacing)
            )
            for visitor in 0 ..< visitorCount {
                let seed = row * 70_001 + visitor * 509
                let segmentIndex = min(
                    intersectionXs.count - 2,
                    Int(unit(seed + 1) * CGFloat(intersectionXs.count - 1))
                )
                let direction: WalkDirection = seed.isMultiple(of: 2) ? .east : .west
                let sourceColumn = direction == .east ? segmentIndex : segmentIndex + 1
                addMovingAgent(
                    column: sourceColumn,
                    row: row,
                    direction: direction,
                    seed: seed,
                    progress: unit(seed + 2),
                    metrics: metrics
                )
            }
        }

        for column in intersectionXs.indices {
            for lowerRow in 0 ..< intersectionYs.count - 1 {
                let segmentBounds = CGRect(
                    x: intersectionXs[column] - metrics.narrowAisle / 2,
                    y: intersectionYs[lowerRow],
                    width: metrics.narrowAisle,
                    height: intersectionYs[lowerRow + 1] - intersectionYs[lowerRow]
                )
                guard segmentBounds.intersects(visibleBounds) else { continue }

                let visitorCount = max(
                    12,
                    Int(segmentBounds.height / smallAisleCrowdSpacing)
                )
                for visitor in 0 ..< visitorCount {
                    let seed = column * 90_001 + lowerRow * 7_001 + visitor * 401
                    let direction: WalkDirection = seed.isMultiple(of: 2) ? .north : .south
                    let sourceRow = direction == .north ? lowerRow : lowerRow + 1
                    addMovingAgent(
                        column: column,
                        row: sourceRow,
                        direction: direction,
                        seed: seed,
                        progress: unit(seed + 2),
                        metrics: metrics
                    )
                }
            }
        }

        let visibleDeskStops = deskStops.filter { stop in
            visibleBounds.insetBy(dx: -metrics.narrowAisle, dy: -metrics.bigAisle)
                .contains(stop.stopPoint)
        }
        for (index, stop) in visibleDeskStops.enumerated() where index.isMultiple(of: 6) {
            addInitiallyDwellingAgent(at: stop, seed: 120_011 + index * 313, metrics: metrics)
        }
    }

    private func addMovingAgent(
        column: Int,
        row: Int,
        direction: WalkDirection,
        seed: Int,
        progress: CGFloat,
        metrics: Metrics
    ) {
        let laneSeed = seed + 31
        guard let segment = makeCorridorSegment(
            fromColumn: column,
            row: row,
            direction: direction,
            laneSeed: laneSeed,
            agentSeed: seed,
            decisions: 0,
            allowDeskVisit: false,
            metrics: metrics
        ) else { return }

        addAgent(
            state: .moving(
                segment: segment,
                distance: segment.length * min(max(progress, 0), 0.999)
            ),
            seed: seed,
            speed: 2.1 + 3.5 * unit(seed + 3)
        )
    }

    private func addInitiallyDwellingAgent(
        at stop: DeskStop,
        seed: Int,
        metrics: Metrics
    ) {
        let column = nearestIndex(to: stop.aisleCenterX, in: intersectionXs)
        guard let lowerRow = (0 ..< intersectionYs.count - 1).first(where: {
            intersectionYs[$0] <= stop.y && stop.y < intersectionYs[$0 + 1]
        }) else { return }

        let direction: WalkDirection = seed.isMultiple(of: 2) ? .north : .south
        let destinationRow = direction == .north ? lowerRow + 1 : lowerRow
        let laneSeed = seed + 31
        let laneOffset = trafficLaneOffset(
            toward: direction,
            seed: laneSeed,
            metrics: metrics
        )
        let lanePoint = CGPoint(
            x: intersectionXs[column] + laneOffset.dx,
            y: stop.y
        )
        let destination = corridorExitPoint(
            atColumn: column,
            row: destinationRow,
            traveling: direction,
            laneSeed: laneSeed,
            metrics: metrics
        )
        let visit = DeskVisit(
            lanePoint: lanePoint,
            stopPoint: stop.stopPoint,
            continuation: CrowdContinuation(
                destinationColumn: column,
                destinationRow: destinationRow,
                incoming: direction,
                destinationPoint: destination
            ),
            dwellDuration: 8 + 22 * TimeInterval(unit(seed + 4))
        )
        addAgent(
            state: .dwelling(
                visit: visit,
                remaining: 8 + 22 * TimeInterval(unit(seed + 5)),
                elapsed: 20 * TimeInterval(unit(seed + 6))
            ),
            seed: seed,
            speed: 2.1 + 2.4 * unit(seed + 7),
            deskVisitCooldown: 4
        )
    }

    private func addAgent(
        state: CrowdState,
        seed: Int,
        speed: CGFloat,
        deskVisitCooldown: Int = 0
    ) {
        let diameter = visitorDiameterRange.lowerBound
            + (visitorDiameterRange.upperBound - visitorDiameterRange.lowerBound) * unit(seed + 11)
        let node = SKSpriteNode(
            texture: visitorTexture,
            color: visitorColor(seed: seed),
            size: CGSize(width: diameter, height: diameter)
        )
        node.colorBlendFactor = 1
        node.zPosition = 2
        floorRoot.addChild(node)
        switch state {
        case let .moving(segment, distance):
            node.position = point(on: segment, progress: distance / max(segment.length, 0.001))
        case let .dwelling(visit, _, _):
            node.position = visit.stopPoint
        }
        agents.append(
            CrowdAgent(
                node: node,
                state: state,
                speed: speed,
                seed: seed,
                decisions: 0,
                deskVisitCooldown: deskVisitCooldown
            )
        )
    }

    private func updateAgents(deltaTime: TimeInterval) {
        guard deltaTime > 0, let metrics = activeMetrics else { return }

        for index in agents.indices {
            var agent = agents[index]
            advance(agent: &agent, deltaTime: deltaTime, metrics: metrics)
            agents[index] = agent
        }
    }

    private func advance(agent: inout CrowdAgent, deltaTime: TimeInterval, metrics: Metrics) {
        switch agent.state {
        case let .dwelling(visit, remaining, elapsed):
            let nextElapsed = elapsed + deltaTime
            agent.node.position = CGPoint(
                x: visit.stopPoint.x,
                y: visit.stopPoint.y + CGFloat(sin(nextElapsed * 0.42)) * 0.28
            )
            if remaining > deltaTime {
                agent.state = .dwelling(
                    visit: visit,
                    remaining: remaining - deltaTime,
                    elapsed: nextElapsed
                )
            } else {
                agent.state = .moving(
                    segment: makeCrowdSegment(
                        from: agent.node.position,
                        to: visit.lanePoint,
                        completion: .returnedFromDesk(visit)
                    ),
                    distance: 0
                )
            }

        case .moving:
            var travelRemaining = agent.speed * CGFloat(deltaTime)
            var transitions = 0

            while travelRemaining > 0, transitions < 5 {
                guard case let .moving(segment, distanceTravelled) = agent.state else { break }
                let remaining = max(0, segment.length - distanceTravelled)
                if travelRemaining < remaining {
                    let nextDistance = distanceTravelled + travelRemaining
                    agent.node.position = point(
                        on: segment,
                        progress: nextDistance / max(segment.length, 0.001)
                    )
                    agent.state = .moving(segment: segment, distance: nextDistance)
                    break
                }

                travelRemaining -= remaining
                agent.node.position = segment.end
                handle(segment.completion, agent: &agent, metrics: metrics)
                transitions += 1
            }
        }
    }

    private func handle(
        _ completion: CrowdSegmentCompletion,
        agent: inout CrowdAgent,
        metrics: Metrics
    ) {
        switch completion {
        case let .arrived(column, row, incoming):
            agent.decisions += 1
            agent.deskVisitCooldown = max(0, agent.deskVisitCooldown - 1)
            startCrowdTurn(
                atColumn: column,
                row: row,
                incoming: incoming,
                agent: &agent,
                metrics: metrics
            )

        case let .exited(column, row, outgoing, laneSeed):
            guard let segment = makeCorridorSegment(
                fromColumn: column,
                row: row,
                direction: outgoing,
                laneSeed: laneSeed,
                agentSeed: agent.seed,
                decisions: agent.decisions,
                allowDeskVisit: agent.deskVisitCooldown == 0,
                metrics: metrics
            ) else {
                startCrowdTurn(
                    atColumn: column,
                    row: row,
                    incoming: outgoing.opposite,
                    agent: &agent,
                    metrics: metrics
                )
                return
            }
            if case .reachedDeskLane = segment.completion {
                agent.deskVisitCooldown = 4
            }
            agent.state = .moving(segment: segment, distance: 0)

        case let .reachedDeskLane(visit):
            agent.state = .moving(
                segment: makeCrowdSegment(
                    from: agent.node.position,
                    to: visit.stopPoint,
                    completion: .reachedDesk(visit)
                ),
                distance: 0
            )

        case let .reachedDesk(visit):
            agent.state = .dwelling(
                visit: visit,
                remaining: visit.dwellDuration,
                elapsed: 0
            )

        case let .returnedFromDesk(visit):
            agent.state = .moving(
                segment: makeCrowdSegment(
                    from: agent.node.position,
                    to: visit.continuation.destinationPoint,
                    completion: .arrived(
                        column: visit.continuation.destinationColumn,
                        row: visit.continuation.destinationRow,
                        incoming: visit.continuation.incoming
                    )
                ),
                distance: 0
            )
        }
    }

    private func startCrowdTurn(
        atColumn column: Int,
        row: Int,
        incoming: WalkDirection,
        agent: inout CrowdAgent,
        metrics: Metrics
    ) {
        let outgoing = chooseCrowdDirection(
            fromColumn: column,
            row: row,
            incoming: incoming,
            seed: agent.seed + agent.decisions * 7_919
        )
        let laneSeed = agent.seed + agent.decisions * 3_571 + 43
        let intersection = intersectionPoint(column: column, row: row)
        let destination = corridorEntryPoint(
            atColumn: column,
            row: row,
            traveling: outgoing,
            laneSeed: laneSeed,
            metrics: metrics
        )
        agent.state = .moving(
            segment: makeCrowdSegment(
                from: agent.node.position,
                control: intersection,
                to: destination,
                completion: .exited(
                    column: column,
                    row: row,
                    outgoing: outgoing,
                    laneSeed: laneSeed
                )
            ),
            distance: 0
        )
    }

    private func makeCorridorSegment(
        fromColumn column: Int,
        row: Int,
        direction: WalkDirection,
        laneSeed: Int,
        agentSeed: Int,
        decisions: Int,
        allowDeskVisit: Bool,
        metrics: Metrics
    ) -> CrowdSegment? {
        let nextColumn = column + direction.columnOffset
        let nextRow = row + direction.rowOffset
        guard intersectionXs.indices.contains(nextColumn),
              intersectionYs.indices.contains(nextRow)
        else { return nil }

        let start = corridorEntryPoint(
            atColumn: column,
            row: row,
            traveling: direction,
            laneSeed: laneSeed,
            metrics: metrics
        )
        let destination = corridorExitPoint(
            atColumn: nextColumn,
            row: nextRow,
            traveling: direction,
            laneSeed: laneSeed,
            metrics: metrics
        )
        let arrival: CrowdSegmentCompletion = .arrived(
            column: nextColumn,
            row: nextRow,
            incoming: direction
        )

        guard allowDeskVisit,
              direction == .north || direction == .south,
              unit(agentSeed + decisions * 997 + 17) < 0.22
        else {
            return makeCrowdSegment(from: start, to: destination, completion: arrival)
        }

        let lowerY = min(start.y, destination.y) + turnRadius
        let upperY = max(start.y, destination.y) - turnRadius
        let candidates = deskStops.filter {
            abs($0.aisleCenterX - intersectionXs[column]) < 0.5
                && lowerY < $0.y
                && $0.y < upperY
        }
        guard !candidates.isEmpty else {
            return makeCrowdSegment(from: start, to: destination, completion: arrival)
        }

        let choice = min(
            candidates.count - 1,
            Int(unit(agentSeed + decisions * 1_009 + 23) * CGFloat(candidates.count))
        )
        let stop = candidates[choice]
        let lanePoint = CGPoint(x: start.x, y: stop.y)
        let visit = DeskVisit(
            lanePoint: lanePoint,
            stopPoint: stop.stopPoint,
            continuation: CrowdContinuation(
                destinationColumn: nextColumn,
                destinationRow: nextRow,
                incoming: direction,
                destinationPoint: destination
            ),
            dwellDuration: 8 + 22 * TimeInterval(unit(agentSeed + decisions * 1_021 + 29))
        )
        return makeCrowdSegment(
            from: start,
            to: lanePoint,
            completion: .reachedDeskLane(visit)
        )
    }

    private func makeCrowdSegment(
        from start: CGPoint,
        control: CGPoint? = nil,
        to end: CGPoint,
        completion: CrowdSegmentCompletion
    ) -> CrowdSegment {
        let length = control.map {
            quadraticLength(from: start, control: $0, to: end)
        } ?? distance(from: start, to: end)
        return CrowdSegment(
            start: start,
            control: control,
            end: end,
            length: max(length, 0.001),
            completion: completion
        )
    }

    private func chooseCrowdDirection(
        fromColumn column: Int,
        row: Int,
        incoming: WalkDirection,
        seed: Int
    ) -> WalkDirection {
        let candidates = WalkDirection.allCases.filter {
            intersectionXs.indices.contains(column + $0.columnOffset)
                && intersectionYs.indices.contains(row + $0.rowOffset)
        }
        guard !candidates.isEmpty else { return incoming.opposite }

        let weighted = candidates.map { direction in
            var weight: CGFloat = direction == .east || direction == .west ? 2.4 : 1
            if direction == incoming { weight *= 1.7 }
            if direction == incoming.opposite { weight *= 0.08 }
            return (direction, weight)
        }
        let total = weighted.reduce(CGFloat.zero) { $0 + $1.1 }
        var selection = unit(seed) * total
        for (direction, weight) in weighted {
            if selection < weight { return direction }
            selection -= weight
        }
        return weighted.last?.0 ?? incoming
    }

    private func corridorEntryPoint(
        atColumn column: Int,
        row: Int,
        traveling direction: WalkDirection,
        laneSeed: Int,
        metrics: Metrics,
        forceLeft: Bool = false
    ) -> CGPoint {
        let intersection = intersectionPoint(column: column, row: row)
        let lateral = trafficLaneOffset(
            toward: direction,
            seed: laneSeed,
            metrics: metrics,
            forceLeft: forceLeft
        )
        return CGPoint(
            x: intersection.x + direction.vector.dx * turnRadius + lateral.dx,
            y: intersection.y + direction.vector.dy * turnRadius + lateral.dy
        )
    }

    private func corridorExitPoint(
        atColumn column: Int,
        row: Int,
        traveling direction: WalkDirection,
        laneSeed: Int,
        metrics: Metrics,
        forceLeft: Bool = false
    ) -> CGPoint {
        let intersection = intersectionPoint(column: column, row: row)
        let lateral = trafficLaneOffset(
            toward: direction,
            seed: laneSeed,
            metrics: metrics,
            forceLeft: forceLeft
        )
        return CGPoint(
            x: intersection.x - direction.vector.dx * turnRadius + lateral.dx,
            y: intersection.y - direction.vector.dy * turnRadius + lateral.dy
        )
    }

    private func trafficLaneOffset(
        toward direction: WalkDirection,
        seed: Int,
        metrics: Metrics,
        forceLeft: Bool = false
    ) -> CGVector {
        let corridorWidth = direction == .east || direction == .west
            ? metrics.bigAisle
            : metrics.narrowAisle
        let followsLeft = forceLeft || unit(seed + 5) < leftTrafficProbability
        let side: CGFloat = followsLeft ? 1 : -1
        let maximumOffset = max(
            1,
            corridorWidth / 2 - maximumVisitorRadius - deskLineWidth
        )
        let magnitude = min(
            maximumOffset,
            corridorWidth * (0.16 + 0.24 * unit(seed + 7))
        )
        let left = CGVector(dx: -direction.vector.dy, dy: direction.vector.dx)
        return CGVector(
            dx: left.dx * magnitude * side,
            dy: left.dy * magnitude * side
        )
    }

    private func point(on segment: CrowdSegment, progress: CGFloat) -> CGPoint {
        let progress = min(max(progress, 0), 1)
        guard let control = segment.control else {
            return interpolate(from: segment.start, to: segment.end, progress: progress)
        }
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * segment.start.x
                + 2 * inverse * progress * control.x
                + progress * progress * segment.end.x,
            y: inverse * inverse * segment.start.y
                + 2 * inverse * progress * control.y
                + progress * progress * segment.end.y
        )
    }

    func setVeilColor(for colorScheme: ColorScheme) {
        let userInterfaceStyle: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        veilNode.color = UIColor.systemBackground.resolvedColor(with: traits)
    }

    private func configureCameraAndTrackedUser(metrics: Metrics) {
        guard intersectionXs.count >= 3, intersectionYs.count >= 3 else { return }

        let centerColumn = nearestIndex(to: 0, in: intersectionXs)
        let centerRow = nearestIndex(to: 0, in: intersectionYs)
        allowedUserColumns = max(0, centerColumn - 1)
            ... min(intersectionXs.count - 1, centerColumn + 1)
        allowedUserRows = max(0, centerRow - 1)
            ... min(intersectionYs.count - 1, centerRow + 1)
        turnRadius = min(metrics.narrowAisle * 0.34, metrics.bigAisle * 0.14)

        cameraNode = SKCameraNode()
        addChild(cameraNode)
        camera = cameraNode

        veilNode = SKSpriteNode(
            color: .systemBackground,
            size: CGSize(width: size.width + 4, height: size.height + 4)
        )
        veilNode.alpha = veilOpacity
        veilNode.zPosition = 100
        cameraNode.addChild(veilNode)

        trackedUserNode = SKSpriteNode(
            texture: visitorTexture,
            color: UIColor(named: "AccentColor") ?? .systemGreen,
            size: CGSize(width: trackedUserDiameter, height: trackedUserDiameter)
        )
        trackedUserNode.colorBlendFactor = 1
        trackedUserNode.zPosition = 101
        floorRoot.addChild(trackedUserNode)

        let initialDirection = [WalkDirection.east, .north, .west, .south]
            .first { canTravel(fromColumn: centerColumn, row: centerRow, toward: $0) }
            ?? .east
        trackedUserNode.position = corridorEntryPoint(
            atColumn: centerColumn,
            row: centerRow,
            traveling: initialDirection,
            laneSeed: trackedLaneSeed(for: initialDirection),
            metrics: metrics,
            forceLeft: true
        )
        trackedUserTangent = initialDirection.vector
        startCorridor(
            fromColumn: centerColumn,
            row: centerRow,
            direction: initialDirection
        )

        let userScenePoint = floorRoot.convert(trackedUserNode.position, to: self)
        cameraNode.position = userScenePoint
        cameraHasSettled = false
    }

    private func updateTrackedUser(deltaTime: TimeInterval) {
        guard deltaTime > 0, trackedUserSegment != nil else { return }

        var travelRemaining = trackedUserSpeed * CGFloat(deltaTime)
        var transitions = 0

        while travelRemaining > 0, let segment = trackedUserSegment, transitions < 4 {
            let segmentRemaining = max(0, segment.length - trackedUserSegmentDistance)

            if travelRemaining < segmentRemaining {
                trackedUserSegmentDistance += travelRemaining
                let progress = trackedUserSegmentDistance / max(segment.length, 0.001)
                trackedUserNode.position = point(on: segment, progress: progress)
                trackedUserTangent = tangent(on: segment, progress: progress)
                break
            }

            travelRemaining -= segmentRemaining
            trackedUserNode.position = segment.end
            trackedUserTangent = tangent(on: segment, progress: 1)
            trackedUserSegmentDistance = 0
            handle(segment.completion)
            transitions += 1
        }
    }

    private func updateCamera(deltaTime: TimeInterval) {
        guard trackedUserNode.parent != nil else { return }

        let userScenePoint = floorRoot.convert(trackedUserNode.position, to: self)
        let tangentWorldPoint = CGPoint(
            x: trackedUserNode.position.x + trackedUserTangent.dx,
            y: trackedUserNode.position.y + trackedUserTangent.dy
        )
        let tangentScenePoint = floorRoot.convert(tangentWorldPoint, to: self)
        let sceneDirection = normalized(
            CGVector(
                dx: tangentScenePoint.x - userScenePoint.x,
                dy: tangentScenePoint.y - userScenePoint.y
            )
        )
        let lookAhead: CGFloat = 14
        let target = CGPoint(
            x: userScenePoint.x + sceneDirection.dx * lookAhead,
            y: userScenePoint.y + sceneDirection.dy * lookAhead
        )

        guard cameraHasSettled, deltaTime > 0 else {
            cameraNode.position = target
            cameraHasSettled = true
            return
        }

        let followAmount = CGFloat(1 - exp(-1.65 * deltaTime))
        cameraNode.position = interpolate(
            from: cameraNode.position,
            to: target,
            progress: followAmount
        )
    }

    private func handle(_ completion: UserSegmentCompletion) {
        switch completion {
        case let .arrived(column, row, incoming):
            startTurn(atColumn: column, row: row, incoming: incoming)

        case let .exited(column, row, outgoing):
            startCorridor(fromColumn: column, row: row, direction: outgoing)
        }
    }

    private func startCorridor(
        fromColumn column: Int,
        row: Int,
        direction: WalkDirection
    ) {
        guard let metrics = activeMetrics else { return }
        let nextColumn = column + direction.columnOffset
        let nextRow = row + direction.rowOffset
        guard allowedUserColumns.contains(nextColumn), allowedUserRows.contains(nextRow) else {
            startTurn(atColumn: column, row: row, incoming: direction.opposite)
            return
        }

        let destination = corridorExitPoint(
            atColumn: nextColumn,
            row: nextRow,
            traveling: direction,
            laneSeed: trackedLaneSeed(for: direction),
            metrics: metrics,
            forceLeft: true
        )
        trackedUserSegment = UserSegment(
            start: trackedUserNode.position,
            control: nil,
            end: destination,
            length: distance(from: trackedUserNode.position, to: destination),
            completion: .arrived(
                column: nextColumn,
                row: nextRow,
                incoming: direction
            )
        )
        trackedUserSegmentDistance = 0
    }

    private func startTurn(
        atColumn column: Int,
        row: Int,
        incoming: WalkDirection
    ) {
        guard let metrics = activeMetrics else { return }
        let outgoing = chooseDirection(fromColumn: column, row: row, incoming: incoming)
        let intersection = intersectionPoint(column: column, row: row)
        let destination = corridorEntryPoint(
            atColumn: column,
            row: row,
            traveling: outgoing,
            laneSeed: trackedLaneSeed(for: outgoing),
            metrics: metrics,
            forceLeft: true
        )
        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: intersection,
            end: destination,
            length: quadraticLength(from: start, control: intersection, to: destination),
            completion: .exited(column: column, row: row, outgoing: outgoing)
        )
        trackedUserSegmentDistance = 0
    }

    private func trackedLaneSeed(for direction: WalkDirection) -> Int {
        switch direction {
        case .north: 201
        case .east: 202
        case .south: 203
        case .west: 204
        }
    }

    private func chooseDirection(
        fromColumn column: Int,
        row: Int,
        incoming: WalkDirection
    ) -> WalkDirection {
        let candidates = WalkDirection.allCases.filter {
            canTravel(fromColumn: column, row: row, toward: $0)
        }
        guard !candidates.isEmpty else { return incoming.opposite }

        let weightedCandidates = candidates.map { direction in
            let weight: Double
            if direction == incoming {
                weight = 0.56
            } else if direction == incoming.opposite {
                weight = 0.06
            } else {
                weight = 0.19
            }
            return (direction, weight)
        }
        let totalWeight = weightedCandidates.reduce(0) { $0 + $1.1 }
        var selection = Double.random(in: 0 ..< totalWeight)

        for (direction, weight) in weightedCandidates {
            if selection < weight {
                return direction
            }
            selection -= weight
        }
        return weightedCandidates.last?.0 ?? incoming
    }

    private func canTravel(
        fromColumn column: Int,
        row: Int,
        toward direction: WalkDirection
    ) -> Bool {
        allowedUserColumns.contains(column + direction.columnOffset)
            && allowedUserRows.contains(row + direction.rowOffset)
    }

    private func intersectionPoint(column: Int, row: Int) -> CGPoint {
        CGPoint(x: intersectionXs[column], y: intersectionYs[row])
    }

    private func nearestIndex(to value: CGFloat, in values: [CGFloat]) -> Int {
        values.indices.min {
            abs(values[$0] - value) < abs(values[$1] - value)
        } ?? values.startIndex
    }

    private func point(on segment: UserSegment, progress: CGFloat) -> CGPoint {
        let progress = min(max(progress, 0), 1)
        guard let control = segment.control else {
            return interpolate(from: segment.start, to: segment.end, progress: progress)
        }

        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * segment.start.x
                + 2 * inverse * progress * control.x
                + progress * progress * segment.end.x,
            y: inverse * inverse * segment.start.y
                + 2 * inverse * progress * control.y
                + progress * progress * segment.end.y
        )
    }

    private func tangent(on segment: UserSegment, progress: CGFloat) -> CGVector {
        guard let control = segment.control else {
            return normalized(
                CGVector(
                    dx: segment.end.x - segment.start.x,
                    dy: segment.end.y - segment.start.y
                )
            )
        }

        let progress = min(max(progress, 0), 1)
        let inverse = 1 - progress
        return normalized(
            CGVector(
                dx: 2 * inverse * (control.x - segment.start.x)
                    + 2 * progress * (segment.end.x - control.x),
                dy: 2 * inverse * (control.y - segment.start.y)
                    + 2 * progress * (segment.end.y - control.y)
            )
        )
    }

    private func quadraticLength(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let sampleSegment = UserSegment(
            start: start,
            control: control,
            end: end,
            length: 0,
            completion: .exited(column: 0, row: 0, outgoing: .east)
        )
        var length: CGFloat = 0
        var previousPoint = start

        for step in 1 ... 12 {
            let nextPoint = point(on: sampleSegment, progress: CGFloat(step) / 12)
            length += distance(from: previousPoint, to: nextPoint)
            previousPoint = nextPoint
        }
        return max(length, 0.001)
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func normalized(_ vector: CGVector) -> CGVector {
        let length = hypot(vector.dx, vector.dy)
        guard length > 0.0001 else { return .zero }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private func assertFloorClearances(metrics: Metrics) {
        let deskInset = deskLineWidth / 2
        assert(
            metrics.deskColumnsPerBlock == 2,
            "Each booth block must remain exactly two desk columns wide."
        )
        assert(
            abs(metrics.endCapGap - metrics.tableShortSide * 2) < 0.001,
            "The two end-cap tables must retain a two-table-wide opening."
        )
        assert(
            tableStopOffset - maximumVisitorRadius > deskInset,
            "Table-stop visitors must remain outside desk strokes."
        )

        for aisleWidth in [metrics.narrowAisle, metrics.bigAisle] {
            let maximumLaneOffset = aisleWidth / 2 - maximumVisitorRadius - deskLineWidth
            assert(
                maximumLaneOffset + maximumVisitorRadius + deskInset < aisleWidth / 2,
                "Visitor lanes must remain clear of desk strokes."
            )
        }
    }

    private func visitorColor(seed _: Int) -> UIColor {
        .secondaryLabel
    }

    private func interpolate(
        from start: CGPoint,
        to end: CGPoint,
        progress: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func unit(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43_758.5453
        return CGFloat(value - floor(value))
    }
}

#Preview {
    SignInView()
        .environment(\.locale, .init(identifier: "ja"))
}
