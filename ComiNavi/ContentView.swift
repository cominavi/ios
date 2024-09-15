//
//  ContentView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var circle = CirclemsDataSource.shared

    var body: some View {
        switch circle.readiness {
        case .uninitialized:
            VStack {
                ProgressView()
                Text("Pending...")
                    .foregroundStyle(.secondary)
            }
        case .initializing:
            VStack {
                ProgressView()
                Text("Initializing...")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            TabView {
                GalleryViewControllerWrappedView()
                    .ignoresSafeArea()
                    .tabItem {
                        Label("Gallery", systemImage: "square.grid.2x2")
                    }

                NavigationView {
                    MapView()
                }
                .tabItem {
                    Label("Map", systemImage: "map")
                }
            }

        case .error(let error):
            VStack {
                Image(systemName: "xmark.octagon.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.red)

                Text("Error: \(error.localizedDescription)")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
