//
//  EntryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI
#if DEBUG
import UIKit
#endif

struct EntryView: View {
    @State private var userState = AppData.userState
    @State private var catalogLibrary = AppData.catalogLibrary
    #if DEBUG
    @State private var isForcingSignInForTesting = ProcessInfo.processInfo.arguments.contains(
        "-cominavi-ui-testing-show-sign-in"
    )
    #endif

    private var shouldShowSignIn: Bool {
        #if DEBUG
        if isForcingSignInForTesting {
            return true
        }
        #endif
        #if DEBUG || COMINAVI_STAGING
        if catalogLibrary.mode == .demo || catalogLibrary.mode == .crawl {
            return false
        }
        #endif
        return userState.user?.userId == nil
    }

    var body: some View {
        appContent
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-cominavi-ui-testing-shinagaki-lightbox"
        ) {
            ShinagakiLightbox(
                image: Self.shinagakiTestImage,
                accessibilityLabel: "Test Shinagaki"
            )
        } else {
            regularAppContent
        }
        #else
        regularAppContent
        #endif
    }

    @ViewBuilder
    private var regularAppContent: some View {
        // TODO: this is to make sure we request the user info and catalog base API data sequentially, but it really shouldn't be done this way.
        if shouldShowSignIn {
            SignInView(
                onUseDemoData: {
                    leaveForcedSignIn()
                    #if DEBUG || COMINAVI_STAGING
                    catalogLibrary.selectMode(.demo)
                    #endif
                },
                onUseCrawlData: {
                    leaveForcedSignIn()
                    #if DEBUG || COMINAVI_STAGING
                    catalogLibrary.selectMode(.crawl)
                    #endif
                }
            )
        } else if catalogLibrary.dataSource != nil {
            ContentView(catalogLibrary: catalogLibrary)
        } else {
            catalogLoadingView
                .task {
                    catalogLibrary.start()
                }
        }
    }

    #if DEBUG
    private static let shinagakiTestImage = UIGraphicsImageRenderer(
        size: CGSize(width: 840, height: 1_188)
    ).image { context in
        UIColor.systemBackground.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 840, height: 1_188))

        UIColor.systemGreen.setStroke()
        context.cgContext.setLineWidth(12)
        context.cgContext.stroke(
            CGRect(x: 80, y: 80, width: 680, height: 1_028)
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: UIColor.label,
        ]
        NSString(string: "SHINAGAKI")
            .draw(at: CGPoint(x: 150, y: 500), withAttributes: attributes)
    }
    #endif

    private func leaveForcedSignIn() {
        #if DEBUG
        isForcingSignInForTesting = false
        #endif
    }

    @ViewBuilder
    private var catalogLoadingView: some View {
        switch catalogLibrary.phase {
        case .failed(let message):
            ContentUnavailableView {
                Label("Catalogs unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    catalogLibrary.retry()
                }
            }
        case .loading(let event):
            ProgressView("Opening \(event.shortName)…")
        case .idle, .discovering, .ready:
            ProgressView("Finding available catalogs…")
        }
    }
}

#Preview {
    EntryView()
}
