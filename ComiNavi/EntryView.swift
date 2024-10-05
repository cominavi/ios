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
        // FIXME: hardcoded eventId
        let response = try await CirclemsAPI.getCatalogBase(eventId: 190)

        AppData.circlems = CirclemsDataSource(
            params: .init(
                main: .init(
                    digest: response.response.md5.textdbSqlite3UrlSsl,
                    remoteUrl: response.response.url.textdbSqlite3UrlSsl),
                image: .init(
                    digest: response.response.md5.imagedb1UrlSsl,
                    remoteUrl: response.response.url.imagedb1UrlSsl)),
            // FIXME: hardcoded comiketId
            comiketId: "104")

        loadedMetadata = true
    }

    var body: some View {
        Group {
            // TODO: this is to make sure we request the user info and catalog base API data sequentially, but it really shouldn't be done this way.
            if userState.user?.userId == nil {
                SignInView()
            } else if loadedMetadata {
                ContentView()
            } else {
                VStack(spacing: 8) {
                    ProgressView()

                    Text("Checking updates...")
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
