//
//  ProfileScreen.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/3/24.
//

import SwiftUI

struct ProfileScreen: View {
    @ObservedObject var userState = AppData.userState

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

                        Text(userState.user?.nickname ?? "Not Logged In")
                            .font(.title3)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Account") {
                Button {
                    withAnimation {
                        userState.user = nil

                        DispatchQueue.global(qos: .background).async {
                            AppData.circlems.cleanAllCaches()
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
