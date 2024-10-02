//
//  EntryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Alamofire
import SwiftUI

struct EntryView: View {
    @ObservedObject var user = AppData.user
    @State var loadedMetadata = false

    func loadMetadata() async {
        let response = await AF.request("https://api1-sandbox.circle.ms/CatalogBase/All/?event_Id=190", headers: [
            "Authorization": "Bearer \(AppData.user.accessToken ?? "")"
        ])
        .validate()
        .cURLDescription(calling: { cURL in
            print(cURL)
        })
        .serializingDecodable(GetWebCatalogDBResponse.self)
        .response

        guard let result = try? response.result.get() else {
            NSLog("Failed to load metadata: \(String(describing: response.error))")
            return
        }

        AppData.circlems = CirclemsDataSource(
            params: .init(
                main: .init(
                    digest: result.response.md5.textdbSqlite3URLSSL,
                    remoteUrl: result.response.url.textdbSqlite3URLSSL),
                image: .init(
                    digest: result.response.md5.imagedb1URLSSL,
                    remoteUrl: result.response.url.imagedb1URLSSL)), comiketId: "104")

        loadedMetadata = true
    }

    var body: some View {
        Group {
            if !user.isLoggedIn {
                SignInView()
            } else if loadedMetadata {
                ContentView()
            } else {
                VStack(spacing: 8) {
                    ProgressView()

                    Text("Fetching metadata...")
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    Task {
                        await loadMetadata()
                    }
                }
            }
        }
    }
}

#Preview {
    EntryView()
}
