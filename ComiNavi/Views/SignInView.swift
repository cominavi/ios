//
//  SignInView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SwifterSwift
import SwiftUI

enum DemoState {
    case anonymous
    case authenticating
    case authenticated(accessToken: String)
    case userInfoFetched(userInfo: String)
}

class SignInViewModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var state: DemoState = .anonymous

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }

    func signIn() {
        self.state = .authenticating
        guard let authURL = URL(string: "https://auth1-sandbox.circle.ms/OAuth2/?response_type=code&client_id=cominabiv9TZ4Nz096Ngl3DIBtyOQQ9ODQCIKc7C&scope=circle_read%20favorite_read%20favorite_write%20user_info&state=0") else { return }
        let scheme = "cominavi"

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { responseURL, error in
            // Handle the callback.
            print("authentication outcome: \(responseURL) \(error)")
            guard let url = responseURL else { return }
            guard let accessToken = url.queryValue(for: "access_token") else { return }
            self.state = .authenticated(accessToken: accessToken)
            self.fetchUserInfo()
        }

        session.presentationContextProvider = self
        session.start()
    }

    func fetchUserInfo() {
        guard case .authenticated(let token) = self.state else { return }

        // request using URLSession to get "https://api1-sandbox.circle.ms/User/Info/?access_token=" + token
        // and update self.state to .userInfoFetched(userInfo: userInfo)
        // implement below
        let url = URL(string: "https://api1-sandbox.circle.ms/User/Info/?access_token=\(token)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { return }
            let userInfo = String(data: data, encoding: .utf8) ?? "Failed to parse user info"
            DispatchQueue.main.async {
                self.state = .userInfoFetched(userInfo: userInfo)
            }
        }.resume()
    }
}

struct SignInView: View {
    @ObservedObject var vm = SignInViewModel()

    var body: some View {
        Group {
            switch self.vm.state {
            case .anonymous:
                Button {
                    self.vm.signIn()
                } label: {
                    Text("Login via circle.ms")
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .cornerRadius(8)
                }
            case .authenticating:
                VStack {
                    ProgressView()

                    Text("Authenticating...")
                        .foregroundStyle(.secondary)
                }
            case .authenticated(let accessToken):
                VStack {
                    ProgressView()

                    Text("Fetching user info...")
                        .foregroundStyle(.secondary)
                }
            case .userInfoFetched(let userInfo):
                VStack {
                    Text("Authenticated")
                        .foregroundStyle(.primary)

                    Text(userInfo)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }
}

#Preview {
    SignInView()
}
