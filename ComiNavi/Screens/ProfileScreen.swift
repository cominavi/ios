//
//  ProfileScreen.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/3/24.
//

import SwiftUI

struct ProfileScreen: View {
    @AppStorage(SharedLocationClipboardImporter.enabledDefaultsKey)
    private var automaticallyReadsSharedLocations = false
    @State private var isShowingLogoutConfirmation = false
    @State private var isLoggingOut = false
    @State private var userState = AppData.userState
    @State private var sharedLocationInbox: SharedLocationInbox
    let catalogLibrary: CatalogLibrary

    @MainActor
    init(
        catalogLibrary: CatalogLibrary = AppData.catalogLibrary,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox
    ) {
        self.catalogLibrary = catalogLibrary
        _sharedLocationInbox = State(initialValue: sharedLocationInbox)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    LucideIcon("person.circle", size: 32)
                        .foregroundStyle(.secondary)
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
                                LucideLabel(verbatim: mode.displayName, icon: "checkmark")
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

            if let dataSource = catalogLibrary.dataSource {
                Section("X followed circles") {
                    NavigationLink {
                        FollowingImportView(dataSource: dataSource)
                    } label: {
                        LabeledContent {
                            Text("Import")
                        } label: {
                            Label("Find followed circles", systemImage: "person.2")
                        }
                    }
                    .disabled(userState.user == nil)
                    .accessibilityIdentifier("profile-following-import")

                    Text(
                        userState.user == nil
                            ? "Log in to Circle.ms to use authenticated imports."
                            : "Import the public X accounts you follow and match them to this catalog on your device."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Shared locations") {
                Toggle(
                    "Detect locations from clipboard",
                    isOn: $automaticallyReadsSharedLocations
                )
                .accessibilityIdentifier("profile-auto-read-shared-location")

                Text(
                    "When enabled, ComiNavi checks new clipboard text while the app is active. iOS may ask before allowing access. Clipboard contents are never uploaded or saved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    sharedLocationInbox.receiveClipboardText(value)
                }
                .buttonBorderShape(.roundedRectangle)
                .accessibilityIdentifier("profile-paste-shared-location")
            }

            Section("Account") {
                Button {
                    if userState.user == nil {
                        returnToAuthentication()
                    } else {
                        isShowingLogoutConfirmation = true
                    }
                } label: {
                    HStack {
                        LucideIcon(userState.user == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.badge.minus")
                            .frame(width: 24, height: 24)

                        Text(userState.user == nil ? "Log In" : "Log Out")
                    }
                    .foregroundStyle(.red)
                }
                .accessibilityIdentifier("profile-account-action")
                .disabled(isLoggingOut)
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog(
            "Log out of Circle.ms?",
            isPresented: $isShowingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                returnToAuthentication()
            }
            .accessibilityIdentifier("profile-confirm-log-out")

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded Circle.ms catalog caches will be removed from this device.")
        }
    }

    private func returnToAuthentication() {
        let dataSource = AppData.circlems
        guard userState.user != nil else {
            withAnimation {
                catalogLibrary.reset()
            }
            return
        }
        guard !isLoggingOut else { return }
        isLoggingOut = true
        Task {
            try? await CominaviServiceClient.shared.disablePushDevice()
            try? await CominaviServiceClient.shared.revokeSession()
            await CominaviServiceClient.shared.invalidateSession()
            withAnimation {
                userState.user = nil
                catalogLibrary.reset()
                isLoggingOut = false
            }
            await dataSource?.cleanAllCaches()
        }
    }
}

#Preview {
    ProfileScreen()
}
