//
//  EntryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Alamofire
import SwiftUI
import Toast

struct EntryView: View {
    @ObservedObject var userState = AppData.userState
    @State var loadedMetadata = false

    func loadMetadata() async throws {
        let response = try await CirclemsAPI.getCatalogBase(eventId: 190)

        AppData.circlems = CirclemsDataSource(
            params: .init(
                main: .init(
                    digest: response.response.md5.textdbSqlite3UrlSsl,
                    remoteUrl: response.response.url.textdbSqlite3UrlSsl),
                image: .init(
                    digest: response.response.md5.imagedb1UrlSsl,
                    remoteUrl: response.response.url.imagedb1UrlSsl)),
            comiketId: "104")

        loadedMetadata = true
    }

    var body: some View {
        Group {
            if !userState.isLoggedIn {
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
                        do {
                            try await loadMetadata()
                        } catch {
                            Toast.showError("Failed to fetch metadata", subtitle: "\(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    EntryView()
}
