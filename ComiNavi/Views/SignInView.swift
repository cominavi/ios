//
//  SignInView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SpriteKit
import SwiftUI
import UIKit

enum DemoState {
    case anonymous
    case authenticating
}

struct ConventionFloorBlockCoordinate: Hashable {
    let column: Int
    let row: Int

    func distance(to other: Self) -> Int {
        abs(column - other.column) + abs(row - other.row)
    }
}

enum ConventionFloorRoutePlanning {
    static let targetBlockDistance = 2

    static func distance(
        fromIntersectionColumn column: Int,
        row: Int,
        to block: ConventionFloorBlockCoordinate
    ) -> Int {
        let adjacentBlocks = [
            ConventionFloorBlockCoordinate(column: column, row: row),
            ConventionFloorBlockCoordinate(column: column + 1, row: row),
            ConventionFloorBlockCoordinate(column: column, row: row + 1),
            ConventionFloorBlockCoordinate(column: column + 1, row: row + 1),
        ]
        return 1 + (adjacentBlocks.map { $0.distance(to: block) }.min() ?? 0)
    }

    static func preferredCandidateIndices(
        for distances: [Int],
        targetDistance: Int = targetBlockDistance
    ) -> [Int] {
        let exactMatches = distances.indices.filter { distances[$0] == targetDistance }
        if !exactMatches.isEmpty {
            return exactMatches
        }

        let fartherDistances = distances.filter { $0 > targetDistance }
        if let nearestFallback = fartherDistances.min() {
            return distances.indices.filter { distances[$0] == nearestFallback }
        }

        return Array(distances.indices)
    }
}

enum CirclemsAuthorizationURLBuilder {
    static func makeURL(
        serviceEnvironment: CirclemsServiceEnvironment,
        clientID: String,
        redirectURL: URL,
        state: String
    ) -> URL? {
        guard
            var components = URLComponents(
                url: serviceEnvironment.authenticationBaseURL.appending(path: "OAuth2/"),
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(
                name: "scope", value: "circle_read favorite_read favorite_write user_info"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url
    }
}

private enum SignInError: LocalizedError {
    case environmentChanged

    var errorDescription: String? {
        switch self {
        case .environmentChanged:
            String(
                localized: "The login response could not be verified. Please try again."
            )
        }
    }
}

@MainActor
class SignInViewModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var state: DemoState = .anonymous
    @Published var authenticationError: String?
    private var authenticationSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }

    func signIn() {
        guard state == .anonymous else { return }

        let environment = AppEnvironment.current
        let serviceEnvironment = environment.circlems
        let storageNamespace = environment.storageNamespace
        authenticationError = nil
        self.state = .authenticating

        Task {
            do {
                try await self.doSignIn(
                    environment: environment,
                    serviceEnvironment: serviceEnvironment
                )
                try await self.populateUserInfo(
                    serviceEnvironment: serviceEnvironment
                )
            } catch {
                self.state = .anonymous
                if AppEnvironment.current.storageNamespace == storageNamespace {
                    AppData.userState.user = nil
                }
                // see if it is a user cancelled error
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                {
                    return
                }

                self.authenticationError = error.localizedDescription
            }
        }
    }

    func doSignIn(
        environment: AppEnvironment = .current,
        serviceEnvironment: CirclemsServiceEnvironment? = nil
    ) async throws {
        let serviceEnvironment = serviceEnvironment ?? environment.circlems
        let oauthState = UUID().uuidString
        guard
            let authURL = CirclemsAuthorizationURLBuilder.makeURL(
                serviceEnvironment: serviceEnvironment,
                clientID: environment.circlemsClientID,
                redirectURL: environment.oauthRedirectURL,
                state: oauthState
            )
        else {
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
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "Authentication failed: \(errorCode)"
                                )
                            ]
                        ))
                }
                guard oauthState == url.queryValue(for: "state") else {
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized:
                                        "The login response could not be verified. Please try again."
                                )
                            ]
                        ))
                }
                guard let tokenType = url.queryValue(for: "token_type"), tokenType == "Bearer"
                else {
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "Circle.ms returned an unsupported login response."
                                )
                            ]
                        ))
                }
                guard let accessToken = url.queryValue(for: "access_token") else {
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "The login response did not include an access token."
                                )
                            ]
                        ))
                }
                guard let refreshToken = url.queryValue(for: "refresh_token") else {
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "The login response did not include a refresh token."
                                )
                            ]
                        ))
                }
                guard let expiresInSecondsStr = url.queryValue(for: "expires_in"),
                    let expiresInSeconds = Int(expiresInSecondsStr)
                else {
                    return continuation.resume(
                        throwing: NSError(
                            domain: "SignInViewModel",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized:
                                        "The login response did not include an expiration time."
                                )
                            ]
                        ))
                }
                guard AppEnvironment.current.circlems == serviceEnvironment else {
                    return continuation.resume(throwing: SignInError.environmentChanged)
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

    func populateUserInfo(
        serviceEnvironment: CirclemsServiceEnvironment = AppEnvironment.current.circlems
    ) async throws {
        guard AppEnvironment.current.circlems == serviceEnvironment,
            let authenticatedUser = AppData.userState.user,
            let refreshToken = authenticatedUser.refreshToken
        else {
            throw SignInError.environmentChanged
        }
        let userInfo = try await CirclemsAPI.getUserInfo()
        guard AppEnvironment.current.circlems == serviceEnvironment,
            AppData.userState.user?.refreshToken == refreshToken
        else {
            throw SignInError.environmentChanged
        }
        let newUser = User(
            accessToken: authenticatedUser.accessToken,
            accessTokenExpiresAt: authenticatedUser.accessTokenExpiresAt,
            refreshToken: refreshToken,
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
    #if DEBUG
        @State private var selectedCirclemsEnvironment = AppEnvironment.current.circlems
    #endif
    private let onUseDemoData: (() -> Void)?

    init(onUseDemoData: (() -> Void)? = nil) {
        self.onUseDemoData = onUseDemoData
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandMark

                    Spacer(minLength: 80)

                    hero

                    #if DEBUG
                        circlemsEnvironmentSelector
                            .padding(.top, 32)
                    #endif

                    loginButton
                        .padding(.top, loginButtonTopPadding)

                    if let authenticationError = vm.authenticationError {
                        HStack(alignment: .top, spacing: 10) {
                            LucideIcon("exclamationmark.circle.fill", size: 20)
                                .foregroundStyle(.red)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Authentication failed")
                                    .font(.subheadline.weight(.semibold))
                                Text(authenticationError)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 12)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sign-in-authentication-error")
                    }

                    #if DEBUG || COMINAVI_STAGING
                        if let onUseDemoData {
                            Button(action: onUseDemoData) {
                                LucideLabel("Explore C104 demo data", icon: "externaldrive")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .padding(.top, 12)
                            .accessibilityHint("Opens an offline catalog without logging in")
                            .accessibilityIdentifier("sign-in-demo-data")
                        }

                    #endif
                }
                .frame(
                    maxWidth: 620, minHeight: max(0, proxy.size.height - 48), alignment: .topLeading
                )
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
            Text("Welcome to ComiNavi!")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Color.accentColor)

            Text("Find circles. Know where they are.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var loginButtonTopPadding: CGFloat {
        #if DEBUG
            32
        #else
            48
        #endif
    }

    #if DEBUG
        private var circlemsEnvironmentSelector: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Circle.ms Environment")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Picker("Circle.ms Environment", selection: $selectedCirclemsEnvironment) {
                    ForEach(CirclemsServiceEnvironment.allCases) { environment in
                        Text(environment.displayName)
                            .tag(environment)
                            .accessibilityIdentifier(
                                "sign-in-circlems-environment-\(environment.rawValue)"
                            )
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(vm.state == .authenticating)
                .accessibilityLabel(Text("Circle.ms Environment"))
                .accessibilityHint(
                    Text(selectedCirclemsEnvironment.signInDescription)
                )
                .accessibilityIdentifier("sign-in-circlems-environment")

                Text(selectedCirclemsEnvironment.signInDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .onChange(of: selectedCirclemsEnvironment) { _, environment in
                AppData.selectCirclemsEnvironment(environment)
            }
        }
    #endif

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

                    LucideIcon("arrow.up.right")
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene = ConventionFloorScene()

    private var isSimulationPaused: Bool {
        accessibilityReduceMotion || scenePhase != .active
    }

    var body: some View {
        SpriteView(
            scene: scene,
            preferredFramesPerSecond: 30,
            options: [
                .allowsTransparency,
                .ignoresSiblingOrder,
                .shouldCullNonVisibleNodes,
            ],
            shouldRender: { _ in
                UIApplication.shared.applicationState == .active
            }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
        .onAppear {
            scene.setSimulationPaused(isSimulationPaused)
        }
        .onDisappear {
            scene.setSimulationPaused(true)
        }
        .onChange(of: isSimulationPaused) { _, isPaused in
            scene.setSimulationPaused(isPaused)
        }
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
    private let visitorDiameterRange: ClosedRange<CGFloat> = 2.2...3.2
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
        let bankLength: CGFloat
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

            bankLength =
                CGFloat(tablesPerBank) * tableLongSide
                + CGFloat(tablesPerBank - 1) * tableSpacing
            blockHeight = bankLength + tableShortSide * 2
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
        case enteredDestinationCorridor(DeskRoute)
        case reachedDestinationLane(DeskRoute)
        case reachedDestination(DeskRoute)
        case returnedToAisle(DeskRoute)
        case returnedToIntersection(column: Int, row: Int, incoming: WalkDirection)
    }

    private struct UserSegment {
        let start: CGPoint
        let control: CGPoint?
        let end: CGPoint
        let length: CGFloat
        let completion: UserSegmentCompletion
    }

    private struct DeskStop {
        let id: Int
        let block: ConventionFloorBlockCoordinate
        let aisleCenterX: CGFloat
        let y: CGFloat
        let stopPoint: CGPoint
        let tableRect: CGRect
    }

    private struct DeskRoute {
        let destination: DeskStop
        let aisleColumn: Int
        let approachRow: Int
        let approachDirection: WalkDirection
        let outboundLanePoint: CGPoint
        let returnLanePoint: CGPoint
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
    private var trackedUserDwellRemaining: TimeInterval = 0
    private var currentDeskRoute: DeskRoute?
    private var plannedDirections: [WalkDirection] = []
    private var plannedDeskStops: [DeskStop] = []
    private var routeCandidateStops: [DeskStop] = []
    private var visitedDeskIDs: Set<Int> = []
    private var plannedDeskHighlights: [SKShapeNode] = []
    private var intersectionXs: [CGFloat] = []
    private var intersectionYs: [CGFloat] = []
    private var allowedUserColumns: ClosedRange<Int> = 0...0
    private var allowedUserRows: ClosedRange<Int> = 0...0
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

    func setSimulationPaused(_ isPaused: Bool) {
        guard self.isPaused != isPaused else { return }
        self.isPaused = isPaused
        previousUpdateTime = nil
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
        trackedUserDwellRemaining = 0
        currentDeskRoute = nil
        plannedDirections.removeAll(keepingCapacity: true)
        plannedDeskStops.removeAll(keepingCapacity: true)
        routeCandidateStops.removeAll(keepingCapacity: true)
        visitedDeskIDs.removeAll(keepingCapacity: true)
        plannedDeskHighlights.removeAll(keepingCapacity: true)
        cameraHasSettled = false
        floorRoot = SKNode()
        floorRoot.position = CGPoint(x: size.width / 2, y: size.height / 2)
        floorRoot.zRotation = -.pi / 12
        addChild(floorRoot)

        let metrics = Metrics(canvasWidth: size.width)
        activeMetrics = metrics
        assertFloorClearances(metrics: metrics)

        let rotation = abs(floorRoot.zRotation)
        let projectedWidth =
            abs(size.width * cos(rotation))
            + abs(size.height * sin(rotation))
        let projectedHeight =
            abs(size.width * sin(rotation))
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

        var blockRow = 0
        var bandY = bounds.minY
        while bandY < bounds.maxY {
            var blockColumn = 0
            var blockX = bounds.minX

            while blockX < bounds.maxX {
                let origin = CGPoint(x: blockX, y: bandY)
                addBoothBlock(
                    to: deskPath,
                    origin: origin,
                    block: ConventionFloorBlockCoordinate(
                        column: blockColumn,
                        row: blockRow
                    ),
                    metrics: metrics
                )
                blockColumn += 1
                blockX += metrics.horizontalStride
            }

            blockRow += 1
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
        block: ConventionFloorBlockCoordinate,
        metrics: Metrics
    ) {
        let rightBankX = origin.x + metrics.blockWidth - metrics.tableShortSide
        let bankStartY = origin.y + metrics.tableShortSide

        for table in 0..<metrics.tablesPerBank {
            let tableY =
                bankStartY
                + CGFloat(table) * (metrics.tableLongSide + metrics.tableSpacing)
            let leftTableRect = CGRect(
                x: origin.x,
                y: tableY,
                width: metrics.tableShortSide,
                height: metrics.tableLongSide
            )
            let rightTableRect = CGRect(
                x: rightBankX,
                y: tableY,
                width: metrics.tableShortSide,
                height: metrics.tableLongSide
            )
            path.addRect(leftTableRect)
            path.addRect(rightTableRect)

            let tableCenterY = tableY + metrics.tableLongSide / 2
            deskStops.append(
                DeskStop(
                    id: deskStops.count,
                    block: block,
                    aisleCenterX: origin.x - metrics.narrowAisle / 2,
                    y: tableCenterY,
                    stopPoint: CGPoint(
                        x: origin.x - tableStopOffset,
                        y: tableCenterY
                    ),
                    tableRect: leftTableRect
                )
            )
            deskStops.append(
                DeskStop(
                    id: deskStops.count,
                    block: block,
                    aisleCenterX: origin.x + metrics.blockWidth + metrics.narrowAisle / 2,
                    y: tableCenterY,
                    stopPoint: CGPoint(
                        x: rightBankX + metrics.tableShortSide + tableStopOffset,
                        y: tableCenterY
                    ),
                    tableRect: rightTableRect
                )
            )
        }

        let endCapPairWidth = metrics.tableLongSide * 2
        let endCapPairX = origin.x + (metrics.blockWidth - endCapPairWidth) / 2
        let sideBankMidpointX = (origin.x + metrics.tableShortSide + rightBankX) / 2
        assert(
            abs(endCapPairX + endCapPairWidth / 2 - sideBankMidpointX) < 0.001,
            "The joined end-cap pair must remain centered between the side banks."
        )
        for endY in [origin.y, origin.y + metrics.blockHeight - metrics.tableShortSide] {
            path.addRect(
                CGRect(
                    x: endCapPairX,
                    y: endY,
                    width: metrics.tableLongSide,
                    height: metrics.tableShortSide
                )
            )
            path.addRect(
                CGRect(
                    x: endCapPairX + metrics.tableLongSide,
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
            guard visibleBounds.minY...visibleBounds.maxY ~= rowY else { continue }

            let visitorCount = max(
                180,
                Int((intersectionXs.last! - intersectionXs.first!) / bigAisleCrowdSpacing)
            )
            for visitor in 0..<visitorCount {
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
            for lowerRow in 0..<intersectionYs.count - 1 {
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
                for visitor in 0..<visitorCount {
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
        guard
            let segment = makeCorridorSegment(
                fromColumn: column,
                row: row,
                direction: direction,
                laneSeed: laneSeed,
                agentSeed: seed,
                decisions: 0,
                allowDeskVisit: false,
                metrics: metrics
            )
        else { return }

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
        guard
            let lowerRow = (0..<intersectionYs.count - 1).first(where: {
                intersectionYs[$0] <= stop.y && stop.y < intersectionYs[$0 + 1]
            })
        else { return }

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
        let diameter =
            visitorDiameterRange.lowerBound
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
        case .moving(let segment, let distance):
            node.position = point(on: segment, progress: distance / max(segment.length, 0.001))
        case .dwelling(let visit, _, _):
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
        case .dwelling(let visit, let remaining, let elapsed):
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
                guard case .moving(let segment, let distanceTravelled) = agent.state else { break }
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
        case .arrived(let column, let row, let incoming):
            agent.decisions += 1
            agent.deskVisitCooldown = max(0, agent.deskVisitCooldown - 1)
            startCrowdTurn(
                atColumn: column,
                row: row,
                incoming: incoming,
                agent: &agent,
                metrics: metrics
            )

        case .exited(let column, let row, let outgoing, let laneSeed):
            guard
                let segment = makeCorridorSegment(
                    fromColumn: column,
                    row: row,
                    direction: outgoing,
                    laneSeed: laneSeed,
                    agentSeed: agent.seed,
                    decisions: agent.decisions,
                    allowDeskVisit: agent.deskVisitCooldown == 0,
                    metrics: metrics
                )
            else {
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

        case .reachedDeskLane(let visit):
            agent.state = .moving(
                segment: makeCrowdSegment(
                    from: agent.node.position,
                    to: visit.stopPoint,
                    completion: .reachedDesk(visit)
                ),
                distance: 0
            )

        case .reachedDesk(let visit):
            agent.state = .dwelling(
                visit: visit,
                remaining: visit.dwellDuration,
                elapsed: 0
            )

        case .returnedFromDesk(let visit):
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
        let length =
            control.map {
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
        let corridorWidth =
            direction == .east || direction == .west
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
        allowedUserColumns =
            max(0, centerColumn - 2)...min(intersectionXs.count - 1, centerColumn + 2)
        allowedUserRows = max(0, centerRow - 2)...min(intersectionYs.count - 1, centerRow + 2)
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

        let initialIncoming = WalkDirection.east
        trackedUserNode.position = corridorExitPoint(
            atColumn: centerColumn,
            row: centerRow,
            traveling: initialIncoming,
            laneSeed: trackedLaneSeed(for: initialIncoming),
            metrics: metrics,
            forceLeft: true
        )
        trackedUserTangent = initialIncoming.vector

        let userScenePoint = floorRoot.convert(trackedUserNode.position, to: self)
        cameraNode.position = userScenePoint
        cameraHasSettled = false

        configurePlannedDeskStops(fromColumn: centerColumn, row: centerRow)
        beginNextDeskRoute(
            fromColumn: centerColumn,
            row: centerRow,
            incoming: initialIncoming
        )
    }

    private func updateTrackedUser(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }

        if trackedUserDwellRemaining > 0 {
            trackedUserDwellRemaining = max(0, trackedUserDwellRemaining - deltaTime)
            if trackedUserDwellRemaining == 0 {
                finishCurrentDeskVisit()
            }
            return
        }

        guard trackedUserSegment != nil else { return }

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
        case .arrived(let column, let row, let incoming):
            continuePlannedRoute(atColumn: column, row: row, incoming: incoming)

        case .exited(let column, let row, let outgoing):
            startCorridor(fromColumn: column, row: row, direction: outgoing)

        case .enteredDestinationCorridor(let route):
            startDestinationCorridor(route)

        case .reachedDestinationLane(let route):
            startDeskApproach(route)

        case .reachedDestination(let route):
            trackedUserSegment = nil
            trackedUserSegmentDistance = 0
            trackedUserDwellRemaining = 5
            currentDeskRoute = route

        case .returnedToAisle(let route):
            startReturnCorridor(route)

        case .returnedToIntersection(let column, let row, let incoming):
            currentDeskRoute = nil
            beginNextDeskRoute(fromColumn: column, row: row, incoming: incoming)
        }
    }

    private func configurePlannedDeskStops(
        fromColumn column: Int,
        row: Int
    ) {
        guard !intersectionXs.isEmpty, !intersectionYs.isEmpty else { return }

        let viewport = CGRect(
            x: cameraNode.position.x - size.width / 2,
            y: cameraNode.position.y - size.height / 2,
            width: size.width,
            height: size.height
        ).insetBy(dx: 18, dy: 32)
        let minimumRouteY = intersectionYs[allowedUserRows.lowerBound]
        let maximumRouteY = intersectionYs[allowedUserRows.upperBound]

        routeCandidateStops = deskStops.filter { stop in
            let aisleColumn = nearestIndex(to: stop.aisleCenterX, in: intersectionXs)
            guard allowedUserColumns.contains(aisleColumn),
                minimumRouteY < stop.y,
                stop.y < maximumRouteY
            else { return false }

            let scenePoint = floorRoot.convert(stop.stopPoint, to: self)
            return viewport.contains(scenePoint)
        }

        if routeCandidateStops.isEmpty {
            routeCandidateStops = deskStops.filter { stop in
                let aisleColumn = nearestIndex(to: stop.aisleCenterX, in: intersectionXs)
                return allowedUserColumns.contains(aisleColumn)
                    && minimumRouteY < stop.y
                    && stop.y < maximumRouteY
            }
        }

        let distances = routeCandidateStops.map { stop in
            ConventionFloorRoutePlanning.distance(
                fromIntersectionColumn: column,
                row: row,
                to: stop.block
            )
        }
        let preferredCandidates =
            ConventionFloorRoutePlanning
            .preferredCandidateIndices(for: distances)
            .map { routeCandidateStops[$0] }

        guard let firstDestination = preferredCandidates.randomElement() else { return }
        plannedDeskStops = [firstDestination]
        ensurePlanLookahead()
        refreshPlannedDeskHighlights()
    }

    private func ensurePlanLookahead() {
        while plannedDeskStops.count < 2 {
            guard let reference = plannedDeskStops.last else { return }
            let excludedIDs = visitedDeskIDs.union(plannedDeskStops.map(\.id))
            var candidates = routeCandidateStops.filter { !excludedIDs.contains($0.id) }

            if candidates.isEmpty {
                visitedDeskIDs.subtract(plannedDeskStops.map(\.id))
                let plannedIDs = Set(plannedDeskStops.map(\.id))
                candidates = routeCandidateStops.filter { !plannedIDs.contains($0.id) }
            }

            let distances = candidates.map { reference.block.distance(to: $0.block) }
            let preferredCandidates =
                ConventionFloorRoutePlanning
                .preferredCandidateIndices(for: distances)
                .map { candidates[$0] }

            guard
                let next = preferredCandidates.min(by: {
                    estimatedWalkingDistance(from: reference, to: $0)
                        < estimatedWalkingDistance(from: reference, to: $1)
                })
            else { return }
            plannedDeskStops.append(next)
        }
    }

    private func estimatedWalkingDistance(from source: DeskStop, to destination: DeskStop)
        -> CGFloat
    {
        guard let metrics = activeMetrics else { return .greatestFiniteMagnitude }
        let sourceColumn = nearestIndex(to: source.aisleCenterX, in: intersectionXs)
        let destinationColumn = nearestIndex(to: destination.aisleCenterX, in: intersectionXs)
        var shortest = CGFloat.greatestFiniteMagnitude

        for sourceRow in approachRows(for: source) {
            for destinationRow in approachRows(for: destination) {
                let gridDistance =
                    CGFloat(abs(sourceColumn - destinationColumn))
                    * metrics.horizontalStride
                    + CGFloat(abs(sourceRow - destinationRow)) * metrics.verticalStride
                let approachDistance =
                    abs(source.y - intersectionYs[sourceRow])
                    + abs(destination.y - intersectionYs[destinationRow])
                shortest = min(shortest, gridDistance + approachDistance)
            }
        }
        return shortest
    }

    private func approachRows(for stop: DeskStop) -> [Int] {
        let rows = allowedUserRows.filter { row in
            if row == allowedUserRows.lowerBound {
                return stop.y > intersectionYs[row]
            }
            if row == allowedUserRows.upperBound {
                return stop.y < intersectionYs[row]
            }
            return true
        }
        return rows.sorted {
            abs(stop.y - intersectionYs[$0]) < abs(stop.y - intersectionYs[$1])
        }
    }

    private func refreshPlannedDeskHighlights() {
        plannedDeskHighlights.forEach { $0.removeFromParent() }
        plannedDeskHighlights.removeAll(keepingCapacity: true)

        let accent = UIColor(named: "AccentColor") ?? .systemGreen
        for (index, stop) in plannedDeskStops.prefix(2).enumerated() {
            let highlight = SKShapeNode(
                rect: stop.tableRect,
                cornerRadius: min(stop.tableRect.width, stop.tableRect.height) * 0.18
            )
            highlight.fillColor = accent.withAlphaComponent(index == 0 ? 0.24 : 0.09)
            highlight.strokeColor = accent.withAlphaComponent(index == 0 ? 0.95 : 0.58)
            highlight.lineWidth = index == 0 ? 2.1 : 1.35
            highlight.zPosition = 100.5
            floorRoot.addChild(highlight)
            plannedDeskHighlights.append(highlight)
        }
    }

    private func beginNextDeskRoute(
        fromColumn column: Int,
        row: Int,
        incoming: WalkDirection
    ) {
        ensurePlanLookahead()
        refreshPlannedDeskHighlights()

        guard let destination = plannedDeskStops.first,
            let route = makeDeskRoute(
                to: destination,
                fromColumn: column,
                row: row
            )
        else {
            currentDeskRoute = nil
            plannedDirections.removeAll(keepingCapacity: true)
            startTurn(atColumn: column, row: row, incoming: incoming)
            return
        }

        currentDeskRoute = route
        plannedDirections = gridDirections(
            fromColumn: column,
            row: row,
            toColumn: route.aisleColumn,
            row: route.approachRow,
            incoming: incoming
        )
        continuePlannedRoute(atColumn: column, row: row, incoming: incoming)
    }

    private func makeDeskRoute(
        to destination: DeskStop,
        fromColumn column: Int,
        row: Int
    ) -> DeskRoute? {
        guard let metrics = activeMetrics else { return nil }
        let aisleColumn = nearestIndex(to: destination.aisleCenterX, in: intersectionXs)
        guard allowedUserColumns.contains(aisleColumn),
            let approachRow = approachRows(for: destination).min(by: { lhs, rhs in
                let lhsDistance =
                    CGFloat(abs(column - aisleColumn)) * metrics.horizontalStride
                    + CGFloat(abs(row - lhs)) * metrics.verticalStride
                    + abs(destination.y - intersectionYs[lhs])
                let rhsDistance =
                    CGFloat(abs(column - aisleColumn)) * metrics.horizontalStride
                    + CGFloat(abs(row - rhs)) * metrics.verticalStride
                    + abs(destination.y - intersectionYs[rhs])
                return lhsDistance < rhsDistance
            })
        else { return nil }

        let approachDirection: WalkDirection =
            destination.y > intersectionYs[approachRow]
            ? .north
            : .south
        let outboundOffset = trafficLaneOffset(
            toward: approachDirection,
            seed: trackedLaneSeed(for: approachDirection),
            metrics: metrics,
            forceLeft: true
        )
        let returnDirection = approachDirection.opposite
        let returnOffset = trafficLaneOffset(
            toward: returnDirection,
            seed: trackedLaneSeed(for: returnDirection),
            metrics: metrics,
            forceLeft: true
        )

        return DeskRoute(
            destination: destination,
            aisleColumn: aisleColumn,
            approachRow: approachRow,
            approachDirection: approachDirection,
            outboundLanePoint: CGPoint(
                x: intersectionXs[aisleColumn] + outboundOffset.dx,
                y: destination.y
            ),
            returnLanePoint: CGPoint(
                x: intersectionXs[aisleColumn] + returnOffset.dx,
                y: destination.y
            )
        )
    }

    private func gridDirections(
        fromColumn column: Int,
        row: Int,
        toColumn destinationColumn: Int,
        row destinationRow: Int,
        incoming: WalkDirection
    ) -> [WalkDirection] {
        let horizontalDirection: WalkDirection = destinationColumn >= column ? .east : .west
        let verticalDirection: WalkDirection = destinationRow >= row ? .north : .south
        let horizontal = Array(
            repeating: horizontalDirection,
            count: abs(destinationColumn - column)
        )
        let vertical = Array(
            repeating: verticalDirection,
            count: abs(destinationRow - row)
        )
        let candidates = [horizontal + vertical, vertical + horizontal]
        return candidates.min {
            turnCost(for: $0, incoming: incoming) < turnCost(for: $1, incoming: incoming)
        } ?? []
    }

    private func turnCost(
        for directions: [WalkDirection],
        incoming: WalkDirection
    ) -> Int {
        var previous = incoming
        return directions.reduce(into: 0) { cost, direction in
            if direction == previous.opposite {
                cost += 2
            } else if direction != previous {
                cost += 1
            }
            previous = direction
        }
    }

    private func continuePlannedRoute(
        atColumn column: Int,
        row: Int,
        incoming: WalkDirection
    ) {
        if let route = currentDeskRoute,
            plannedDirections.isEmpty,
            column == route.aisleColumn,
            row == route.approachRow
        {
            startDestinationTurn(route, incoming: incoming)
        } else {
            startTurn(atColumn: column, row: row, incoming: incoming)
        }
    }

    private func startDestinationTurn(
        _ route: DeskRoute,
        incoming _: WalkDirection
    ) {
        guard let metrics = activeMetrics else { return }
        let intersection = intersectionPoint(
            column: route.aisleColumn,
            row: route.approachRow
        )
        let destination = corridorEntryPoint(
            atColumn: route.aisleColumn,
            row: route.approachRow,
            traveling: route.approachDirection,
            laneSeed: trackedLaneSeed(for: route.approachDirection),
            metrics: metrics,
            forceLeft: true
        )
        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: intersection,
            end: destination,
            length: quadraticLength(from: start, control: intersection, to: destination),
            completion: .enteredDestinationCorridor(route)
        )
        trackedUserSegmentDistance = 0
    }

    private func startDestinationCorridor(_ route: DeskRoute) {
        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: nil,
            end: route.outboundLanePoint,
            length: distance(from: start, to: route.outboundLanePoint),
            completion: .reachedDestinationLane(route)
        )
        trackedUserSegmentDistance = 0
    }

    private func startDeskApproach(_ route: DeskRoute) {
        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: nil,
            end: route.destination.stopPoint,
            length: distance(from: start, to: route.destination.stopPoint),
            completion: .reachedDestination(route)
        )
        trackedUserSegmentDistance = 0
    }

    private func finishCurrentDeskVisit() {
        guard let route = currentDeskRoute else { return }
        visitedDeskIDs.insert(route.destination.id)
        plannedDeskStops.removeAll { $0.id == route.destination.id }
        ensurePlanLookahead()
        refreshPlannedDeskHighlights()

        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: nil,
            end: route.returnLanePoint,
            length: distance(from: start, to: route.returnLanePoint),
            completion: .returnedToAisle(route)
        )
        trackedUserSegmentDistance = 0
    }

    private func startReturnCorridor(_ route: DeskRoute) {
        guard let metrics = activeMetrics else { return }
        let returnDirection = route.approachDirection.opposite
        let destination = corridorExitPoint(
            atColumn: route.aisleColumn,
            row: route.approachRow,
            traveling: returnDirection,
            laneSeed: trackedLaneSeed(for: returnDirection),
            metrics: metrics,
            forceLeft: true
        )
        let start = trackedUserNode.position
        trackedUserSegment = UserSegment(
            start: start,
            control: nil,
            end: destination,
            length: distance(from: start, to: destination),
            completion: .returnedToIntersection(
                column: route.aisleColumn,
                row: route.approachRow,
                incoming: returnDirection
            )
        )
        trackedUserSegmentDistance = 0
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
        let outgoing =
            plannedDirections.isEmpty
            ? chooseDirection(fromColumn: column, row: row, incoming: incoming)
            : plannedDirections.removeFirst()
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
        var selection = Double.random(in: 0..<totalWeight)

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

        for step in 1...12 {
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
            "The attached end-cap pair must retain a two-table-wide opening beside it."
        )
        assert(
            abs(metrics.blockWidth - metrics.tableLongSide * 2 - metrics.endCapGap) < 0.001,
            "The two end-cap tables must remain attached as one pair."
        )
        assert(
            abs(metrics.blockHeight - metrics.bankLength - metrics.tableShortSide * 2) < 0.001,
            "End-cap tables must sit flush against both ends of each straight run."
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
