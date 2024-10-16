//
//  SignInView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SwifterSwift
import SwiftUI
import Toast

enum DemoState {
    case anonymous
    case authenticating
}

class SignInViewModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var state: DemoState = .anonymous

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
        let oauthState = String.random(ofLength: 16)
        guard let authURL = URL(string: "\(CirclemsAPI.authBaseURL)/OAuth2/?response_type=code&client_id=cominabiv9TZ4Nz096Ngl3DIBtyOQQ9ODQCIKc7C&scope=circle_read%20favorite_read%20favorite_write%20user_info&state=\(oauthState)") else {
            preconditionFailure("Failed to construct auth URL")
        }
        let scheme = "cominavi"

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { responseURL, error in
                if let error = error {
                    return continuation.resume(throwing: error)
                }
                guard let url = responseURL else {
                    continuation.resume(throwing: URLError(.badURL))
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
    @StateObject var vm = SignInViewModel()
    @State var screenSize = UIScreen.main.bounds.size

    @State var animationTrigger = false

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    LogoShape()
                        .frame(width: 52, height: 52)
                        .padding(.leading, 2)

                    Spacer()

                    Text("Welcome to")
                        .font(.title2)
                        .foregroundStyle(.primary)

                    Group {
                        Text("ComiNavi")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
                            .bold()
                            +
                            Text("!")
                            .font(.largeTitle)
                            .foregroundColor(.primary)
                            .bold()
                    }
                    .font(.title)
                    .foregroundStyle(.accent)

                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)

                Button {
                    self.vm.signIn()
                } label: {
                    HStack {
                        if vm.state == .authenticating {
                            Group {
                                ProgressView()
                                    .tint(.white)

                                Text("Authenticating...")
                            }
                        } else {
                            Text("Login via circle.ms")
                                .bold()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                    .flexibleFrame(.horizontal)
                    .padding(.vertical)
                    .background(vm.state == .authenticating ? .gray : .accent)
                    .cornerRadius(10)
                }
                .disabled(vm.state == .authenticating)
                .opacity(vm.state == .authenticating ? 0.5 : 1)
            }
            .padding()
            .background(
                HStack(alignment: .top, spacing: 40) {
                    ForEach(0 ..< 12) { colIdx in
                        VStack(spacing: 8) {
                            ForEach(0 ..< 12) { _ in
                                Rectangle()
                                    .strokeBorder(.gray.opacity(0.15), lineWidth: 1)
                                    .frame(width: 45, height: 180)
                            }
                        }
                        .padding(.leading, colIdx % 2 == 0 ? 0 : 90)
                        .offset(
                            y:
                            animationTrigger
                                ? 0
                                : (180 + 8))
                    }
                }
                .ignoresSafeArea()
                // move it along y axis from 0 to 180 indefinitely
                .animation(
                    .linear(duration: 40).repeatForever(autoreverses: false),
                    value: animationTrigger
                )
                .rotationEffect(
                    .radians(CGFloat.pi / 2 + atan(proxy.size.height / proxy.size.width))
                )
                .allowsHitTesting(false)
                .onAppear {
                    self.animationTrigger.toggle()
                }
            )
        }
    }
}

#Preview {
    SignInView()
        .environment(\.locale, .init(identifier: "ja"))
}
