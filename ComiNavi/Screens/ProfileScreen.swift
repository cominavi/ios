//
//  ProfileScreen.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/3/24.
//

import SwiftUI

struct ProfileScreen: View {
    @State private var userState = AppData.userState
    let catalogLibrary: CatalogLibrary

    @MainActor
    init(catalogLibrary: CatalogLibrary = AppData.catalogLibrary) {
        self.catalogLibrary = catalogLibrary
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "person.circle")
                        .resizable()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        .padding(.trailing, 8)

                    VStack(alignment: .leading) {
                        Text(userState.user != nil ? "Logged in as" : "Tap to log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(userState.user?.nickname ?? String(localized: "Not logged in"))
                            .font(.title3)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Data source") {
                Menu {
                    ForEach(catalogLibrary.availableModes, id: \.self) { mode in
                        Button {
                            catalogLibrary.selectMode(mode)
                        } label: {
                            if mode == catalogLibrary.mode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    LabeledContent("Source", value: catalogLibrary.mode.displayName)
                }
                .disabled(catalogLibrary.availableModes.count < 2 || catalogLibrary.isSwitching)
                .accessibilityIdentifier("profile-catalog-data-source")

                Text(catalogLibrary.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                Button {
                    withAnimation {
                        let dataSource = AppData.circlems
                        userState.user = nil
                        catalogLibrary.reset()
                        Task {
                            await dataSource?.cleanAllCaches()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: userState.user == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.badge.minus")
                            .frame(width: 24, height: 24)

                        Text(userState.user == nil ? "Log In" : "Log Out")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Profile")
    }
}

#Preview {
    ProfileScreen()
}
