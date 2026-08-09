//
//  EntryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI
import UIKit
import UserNotifications

struct EntryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SharedLocationClipboardImporter.enabledDefaultsKey)
    private var automaticallyReadsSharedLocations = false
    @State private var userState = AppData.userState
    @State private var catalogLibrary = AppData.catalogLibrary
    @State private var sharedLocationInbox = AppData.sharedLocationInbox
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
            if catalogLibrary.mode == .demo {
                return false
            }
        #endif
        return userState.user?.userId == nil
    }

    var body: some View {
        appContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onOpenURL { url in
                sharedLocationInbox.receive(url: url)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                importSharedLocationFromClipboardIfEnabled()
            }
            .onChange(of: automaticallyReadsSharedLocations) { _, enabled in
                guard enabled else { return }
                importSharedLocationFromClipboardIfEnabled()
            }
            .onChange(of: userState.user?.userId, initial: true) { _, userID in
                guard userID != nil else { return }
                Task {
                    let settings = await UNUserNotificationCenter.current()
                        .notificationSettings()
                    if [.authorized, .provisional, .ephemeral].contains(
                        settings.authorizationStatus
                    ) {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
            .alert(
                sharedLocationIssueTitle,
                isPresented: Binding(
                    get: { sharedLocationInbox.issue != nil },
                    set: { if !$0 { sharedLocationInbox.issue = nil } }
                )
            ) {
                Button("OK") {
                    sharedLocationInbox.issue = nil
                }
            } message: {
                Text(sharedLocationIssueMessage)
            }
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-catalog-download"
            ) {
                CatalogStatusSurface(
                    symbolName: "arrow.down.circle.fill",
                    eyebrow: "C108",
                    title: String(localized: "Downloading\ndatabases"),
                    subtitle: String.localizedStringWithFormat(
                        String(localized: "Downloading %@ databases…"),
                        "C108"
                    )
                ) {
                    DownloadProgressView(progresses: [
                        .init(
                            type: .main,
                            totalBytes: 4_880_130,
                            completedBytes: 2_600_000,
                            bytesPerSecond: 840_000
                        ),
                        .init(
                            type: .image,
                            totalBytes: 341_840_565,
                            completedBytes: 94_000_000,
                            bytesPerSecond: 7_650_000
                        ),
                    ])
                }
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-catalog-error"
            ) {
                CatalogErrorSurface(
                    symbolName: "exclamationmark.triangle.fill",
                    title: String(localized: "Catalog unavailable"),
                    message: String(
                        localized: "Failed to load the Comiket catalog information."
                    ),
                    advice: String(localized: "Please try again.")
                ) {
                    Button {
                        // This debug action is intentionally inert; it exists only
                        // for screenshot and accessibility review.
                    } label: {
                        LucideLabel("Try Again", icon: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.accentColor)
                }
            } else if ProcessInfo.processInfo.arguments.contains(
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
                }
            )
        } else if catalogLibrary.dataSource != nil {
            ContentView(
                catalogLibrary: catalogLibrary,
                sharedLocationInbox: sharedLocationInbox
            )
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

    private func importSharedLocationFromClipboardIfEnabled() {
        guard automaticallyReadsSharedLocations else { return }
        AppData.sharedLocationClipboardImporter.importIfChanged(into: sharedLocationInbox)
    }

    private var sharedLocationIssueTitle: String {
        switch sharedLocationInbox.issue {
        case .invalidLink:
            String(localized: "Invalid shared location")
        case .clipboardDoesNotContainLocation:
            String(localized: "No shared location found")
        case .unsupportedEvent:
            String(localized: "Catalog unavailable")
        case .locationUnavailable:
            String(localized: "Location unavailable")
        case nil:
            ""
        }
    }

    private var sharedLocationIssueMessage: String {
        switch sharedLocationInbox.issue {
        case .invalidLink:
            String(localized: "This ComiNavi location link is invalid or unsupported.")
        case .clipboardDoesNotContainLocation:
            String(localized: "The clipboard does not contain a ComiNavi location link.")
        case .unsupportedEvent(let eventNumber):
            String.localizedStringWithFormat(
                String(localized: "The C%d catalog is not available on this device."),
                eventNumber
            )
        case .locationUnavailable:
            String(localized: "This location could not be found in the official catalog.")
        case nil:
            ""
        }
    }

    @ViewBuilder
    private var catalogLoadingView: some View {
        switch catalogLibrary.phase {
        case .failed(let message):
            CatalogErrorSurface(
                symbolName: "exclamationmark.triangle.fill",
                title: String(localized: "Catalogs unavailable"),
                message: message,
                advice: String(localized: "Please try again.")
            ) {
                Button {
                    catalogLibrary.retry()
                } label: {
                    LucideLabel("Try Again", icon: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.accentColor)
            }
        case .loading(let event):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(String(localized: "Opening catalog…")))
            }
        case .idle, .discovering, .ready:
            CatalogStatusSurface(
                symbolName: "sparkles",
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Finding available catalogs…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(String(localized: "Finding available catalogs…")))
            }
        }
    }
}

#Preview {
    EntryView()
}
