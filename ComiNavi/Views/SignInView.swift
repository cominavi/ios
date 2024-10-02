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
        let oauthState = String.random(ofLength: 16)
        guard let authURL = URL(string: "https://auth1-sandbox.circle.ms/OAuth2/?response_type=code&client_id=cominabiv9TZ4Nz096Ngl3DIBtyOQQ9ODQCIKc7C&scope=circle_read%20favorite_read%20favorite_write%20user_info&state=\(oauthState)") else {
            Toast.showError("Failed to authenticate", subtitle: "Invalid auth URL")
            return
        }
        let scheme = "cominavi"

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { responseURL, error in
            // Handle the callback.
            guard error == nil else {
                // see if it is a user cancelled error
                if (error! as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    self.state = .anonymous
                    return
                }
                Toast.showError("Failed to authenticate", subtitle: error?.localizedDescription)
                return
            }
            guard let url = responseURL else {
                Toast.showError("Failed to authenticate", subtitle: "No response URL")
                return
            }
            guard let accessToken = url.queryValue(for: "access_token") else { return }
            guard oauthState == url.queryValue(for: "state") else { return }
            AppData.user.accessToken = accessToken
        }

        session.presentationContextProvider = self
        session.start()
    }
}

struct SignInView: View {
    @ObservedObject var vm = SignInViewModel()

    var body: some View {
        VStack(alignment: .leading) {
            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                Image(.logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .primary.opacity(0.15), radius: 5, y: 2)
                    .padding(.bottom, 16)

                Text("Welcome to")
                    .font(.title2)
                    .foregroundStyle(.primary)

                Text("ComiNavi!")
                    .bold()
                    .font(.title)
                    .foregroundStyle(.accent)
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)

            Spacer()

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
    }
}

#Preview {
    SignInView()
}
