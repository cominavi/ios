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
    @StateObject var circle = AppData.circlems

    var body: some View {
        Group {
            switch circle.readiness {
            case .uninitialized:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Pending...")
                        .foregroundStyle(.secondary)
                }
            
            case .downloading(progresses: let progresses):
                VStack(spacing: 8) {
                    DownloadProgressView(progresses: progresses)
                        .padding(.horizontal)
                    
                    Text("Downloading databases, this may take a while...")
                        .foregroundStyle(.secondary)
                }
                .padding()
            
            case .initializing(let state):
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Initializing...")
                        .foregroundStyle(.secondary)
                    
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
                    
                    NavigationView {
                        ProfileScreen()
                    }
                    .tabItem {
                        Label("Profile", systemImage: "person.circle")
                    }
                }
                
            case .error(let error):
                VStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .resizable()
                        .frame(width: 32)
                        .foregroundStyle(.red)
                    
                    Text("Error: \(error)")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .animation(.default, value: circle.readiness)
    }
}

#Preview {
    ContentView()
}
