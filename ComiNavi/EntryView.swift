//
//  EntryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI
import UIKit
import UserNotifications

enum EntryContentRoute: Equatable {
    case accountDeletion
    case signIn
    case catalogLoading
    case catalog
    case catalogIndependent

    static func resolve(
        accountDeletionPending: Bool,
        shouldShowSignIn: Bool,
        catalogIsPreparing _: Bool,
        hasCatalog: Bool
    ) -> Self {
        if accountDeletionPending { return .accountDeletion }
        if shouldShowSignIn { return .signIn }
        if hasCatalog { return .catalog }
        // CatalogIndependentContentView keeps plans and profile usable while
        // the catalog tab discovers or revalidates its last installed data.
        // An authenticated launch must never be held behind network work.
        return .catalogIndependent
    }
}

struct EntryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SharedLocationClipboardImporter.enabledDefaultsKey)
    private var automaticallyReadsSharedLocations = false
    @State private var catalogLibrary = AppData.catalogLibrary
    @State private var sharedLocationInbox = AppData.sharedLocationInbox
    @State private var invitationInbox = AppData.sharedPlanInvitationInbox
    @State private var profileStore = AppData.profileStore
    @State private var userState = AppData.userState
    @State private var showsInvitationConfirmation = false
    @State private var googleSpecialEntryActive = false
    @State private var accountDeletionPending = AppData.isAccountDeletionPending
    @State private var accountDeletionIssue: String?
    @State private var showsCatalogResetConfirmation = false
    @State private var isResettingAfterCatalogError = false
    @State private var catalogResetIssue: String?
    #if DEBUG
        @State private var isForcingSignInForTesting = ProcessInfo.processInfo.arguments.contains(
            "-cominavi-ui-testing-show-sign-in"
        )
    #endif

    private var verifiedProfileID: String? {
        guard profileStore.isIdentityVerified else { return nil }
        return profileStore.profile?.id
    }

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
        if googleSpecialEntryActive {
            return true
        }
        if profileStore.requiresReauthentication {
            return true
        }
        return verifiedProfileID == nil
    }

    var body: some View {
        appContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onOpenURL { url in
                if GoogleSignInIDTokenProvider.handle(url) {
                    return
                } else if receiveAppleSpecialEntry(url) {
                    return
                } else if receiveGoogleSpecialEntry(url) {
                    return
                } else if AppData.receiveCirclemsAuthorizationCallback(url) {
                    return
                } else if invitationInbox.receive(url: url) {
                    showsInvitationConfirmation = true
                } else {
                    sharedLocationInbox.receive(url: url)
                }
            }
            .task {
                let deletionPending = await retryPendingAccountDeletionIfNeeded()
                guard !deletionPending else { return }
                let logoutPending = await retryPendingLogoutIfNeeded()
                guard !logoutPending else { return }
                await recoverCompletedCirclemsFlowIfPossible()
                await recoverCompletedGoogleFlowIfPossible()
                await recoverCompletedAppleFlowIfPossible()
                await profileStore.load()
                if !shouldShowSignIn, catalogLibrary.phase == .idle {
                    catalogLibrary.start()
                }
                if profileStore.isIdentityVerified,
                   let userID = profileStore.profile?.id
                {
                    await AppData.sharedPlanStore(for: userID).load()
                }
                showsInvitationConfirmation = invitationInbox.pending != nil
                if let flow = try? AppData.pendingGoogleAuthenticationFlow(),
                   flow.entryContext == .special
                {
                    googleSpecialEntryActive = true
                }
                if let flow = try? AppData.pendingAppleAuthenticationFlow(),
                   flow.entryContext == .special
                {
                    googleSpecialEntryActive = true
                }
            }
            .task {
                var wasReachable = false
                for await isReachable in SharedPlanNetworkReachability.updates() {
                    defer { wasReachable = isReachable }
                    guard isReachable, !wasReachable else { continue }
                    let deletionPending = await retryPendingAccountDeletionIfNeeded()
                    guard !deletionPending else { continue }
                    let logoutPending = await retryPendingLogoutIfNeeded()
                    guard !logoutPending else { continue }
                    await recoverCompletedCirclemsFlowIfPossible()
                    await recoverCompletedGoogleFlowIfPossible()
                    await recoverCompletedAppleFlowIfPossible()
                    try? await profileStore.drainPendingMutation()
                    guard profileStore.isIdentityVerified,
                          let userID = profileStore.profile?.id else { continue }
                    await AppData.sharedPlanStore(for: userID).networkBecameReachable()
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                importSharedLocationFromClipboardIfEnabled()
                Task {
                    let deletionPending = await retryPendingAccountDeletionIfNeeded()
                    guard !deletionPending else { return }
                    let logoutPending = await retryPendingLogoutIfNeeded()
                    guard !logoutPending else { return }
                    await recoverCompletedCirclemsFlowIfPossible()
                    await recoverCompletedGoogleFlowIfPossible()
                    await recoverCompletedAppleFlowIfPossible()
                    try? await profileStore.drainPendingMutation()
                    guard profileStore.isIdentityVerified,
                          let userID = profileStore.profile?.id else { return }
                    await AppData.sharedPlanStore(for: userID).drainRESTOutbox()
                }
            }
            .onChange(of: automaticallyReadsSharedLocations) { _, enabled in
                guard enabled else { return }
                importSharedLocationFromClipboardIfEnabled()
            }
            .onChange(of: verifiedProfileID, initial: true) { _, userID in
                guard let userID else { return }
                googleSpecialEntryActive = false
                if catalogLibrary.phase == .idle {
                    catalogLibrary.start()
                }
                if invitationInbox.pending != nil {
                    showsInvitationConfirmation = true
                }
                Task {
                    await AppData.sharedPlanStore(for: userID).refresh()
                    let settings = await UNUserNotificationCenter.current()
                        .notificationSettings()
                    if [.authorized, .provisional, .ephemeral].contains(
                        settings.authorizationStatus
                    ) {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
            .onChange(of: profileStore.requiresReauthentication) { _, required in
                guard required, AppData.isAccountDeletionPending else { return }
                accountDeletionPending = true
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
            .sheet(isPresented: $showsInvitationConfirmation) {
                if let pending = invitationInbox.pending {
                    SharedPlanInvitationSheet(
                        pending: pending,
                        profileStore: profileStore,
                        invitationInbox: invitationInbox,
                        onDismiss: { showsInvitationConfirmation = false }
                    )
                }
            }
            .confirmationDialog(
                "Log out and reset ComiNavi?",
                isPresented: $showsCatalogResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Log Out & Reset", role: .destructive) {
                    logOutAndResetAfterCatalogError()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes this account's Shared Plans, unsent changes, and downloaded catalog data.")
            }
    }

    @MainActor
    private func retryPendingLogoutIfNeeded() async -> Bool {
        try? await CominaviServiceClient.shared.resumePendingLogout()
        return await CominaviServiceClient.shared.hasPendingLogout()
    }

    @MainActor
    private func retryPendingAccountDeletionIfNeeded() async -> Bool {
        let wasPending = await CominaviServiceClient.shared.hasPendingAccountDeletion()
        guard wasPending else {
            accountDeletionPending = false
            return false
        }
        accountDeletionPending = true
        do {
            _ = try await CominaviServiceClient.shared.resumePendingAccountDeletion()
            _ = try await AppData.finishAccountDeletionLocalCleanupIfNeeded()
            let remainsPending = await CominaviServiceClient.shared
                .hasPendingAccountDeletion()
            accountDeletionPending = remainsPending
            if !remainsPending { accountDeletionIssue = nil }
            return remainsPending
        } catch {
            accountDeletionIssue = error.localizedDescription
        }
        return true
    }

    @MainActor
    private func recoverCompletedCirclemsFlowIfPossible() async {
        guard let persisted = await CominaviServiceClient.shared
            .storedCirclemsAuthorizationCompletion()
        else { return }
        do {
            if try AppData.recoverCompletedCirclemsAuthorizationFlow(persisted) {
                try await CominaviServiceClient.shared.clearCirclemsAuthorizationCompletion(
                    flowRequestID: persisted.marker.flowRequestID
                )
            } else if try AppData.pendingCirclemsAuthorizationFlow() == nil {
                // The flow was already scrubbed and only the final marker-clear
                // write was interrupted.
                try await CominaviServiceClient.shared.clearCirclemsAuthorizationCompletion(
                    flowRequestID: persisted.marker.flowRequestID
                )
            }
        } catch {
            // Leave both protected records intact for the next lifecycle or
            // reachability retry. No legacy credential rotation is re-enabled.
        }
    }

    @MainActor
    private func recoverCompletedGoogleFlowIfPossible() async {
        guard let marker = await CominaviServiceClient.shared
            .storedGoogleAuthenticationCompletion()
        else { return }
        do {
            if let flow = try AppData.pendingGoogleAuthenticationFlow() {
                guard flow.requestID == marker.flowRequestID else {
                    throw CominaviServiceError.invalidResponse
                }
                try AppData.clearGoogleAuthenticationFlow()
            }
            try await CominaviServiceClient.shared.clearGoogleAuthenticationCompletion(
                flowRequestID: marker.flowRequestID
            )
        } catch {
            // Retain both protected records. A later lifecycle/reachability
            // pass finishes local cleanup without submitting the ID token again.
        }
    }

    @MainActor
    private func recoverCompletedAppleFlowIfPossible() async {
        guard let marker = await CominaviServiceClient.shared
            .storedAppleAuthenticationCompletion()
        else { return }
        do {
            if let flow = try AppData.pendingAppleAuthenticationFlow() {
                guard flow.requestID == marker.flowRequestID else {
                    throw CominaviServiceError.invalidResponse
                }
                try AppData.clearAppleAuthenticationFlow()
            }
            try await CominaviServiceClient.shared.clearAppleAuthenticationCompletion(
                flowRequestID: marker.flowRequestID
            )
        } catch {
            // Retain the protected code/token and completion marker until local
            // cleanup can finish without repeating Apple authorization.
        }
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-show-explore-onboarding"
            ) {
                ExploreOnboardingUITestSurface()
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-catalog-loading"
            ) {
                CatalogStatusSurface(
                    symbolName: "map",
                    eyebrow: "C108",
                    title: String(localized: "Preparing catalog…"),
                    subtitle: String(localized: "Opening catalog…")
                ) {
                    CatalogActivityIndicator(
                        accessibilityLabel: String(localized: "Preparing catalog…")
                    )
                }
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-catalog-download"
            ) {
                CatalogStatusSurface(
                    symbolName: "arrow.down.circle.fill",
                    eyebrow: "C108",
                    title: String(localized: "Downloading\ncatalog"),
                    subtitle: String(localized: "Downloading the catalog, this may take a while…")
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
                    FocusedActionButton {
                        // This debug action is intentionally inert; it exists only
                        // for screenshot and accessibility review.
                    } label: {
                        LucideLabel("Try Again", icon: "arrow.clockwise")
                    }

                    FocusedActionButton(
                        role: .destructive,
                        emphasis: .secondary,
                        tint: .red,
                        action: {}
                    ) {
                        LucideLabel(
                            "Log Out & Reset",
                            icon: "person.crop.circle.badge.minus"
                        )
                    }
                }
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-shinagaki-lightbox"
            ) {
                ShinagakiLightbox(
                    pages: [
                        ShinagakiLightboxPage(
                            id: "test-page-1",
                            image: Self.shinagakiTestImage,
                            accessibilityLabel: "Test Shinagaki page 1"
                        ),
                        ShinagakiLightboxPage(
                            id: "test-page-2",
                            image: Self.shinagakiWideTestImage,
                            accessibilityLabel: "Test Shinagaki page 2"
                        ),
                    ],
                    selectedPageID: "test-page-1"
                )
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-no-catalog-shell"
            ) {
                CatalogIndependentContentView(
                    catalogLibrary: catalogLibrary,
                    sharedLocationInbox: sharedLocationInbox
                )
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-shared-plan-purchases"
            ) {
                SharedPlanPurchaseUITestSurface()
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-shared-plan-list"
            ) {
                SharedPlanListUITestSurface()
            } else if ProcessInfo.processInfo.arguments.contains(
                "-cominavi-ui-testing-shared-plan-empty"
            ) {
                SharedPlanEmptyUITestSurface()
            } else {
                regularAppContent
            }
        #else
            regularAppContent
        #endif
    }

    @ViewBuilder
    private var regularAppContent: some View {
        switch EntryContentRoute.resolve(
            accountDeletionPending: accountDeletionPending,
            shouldShowSignIn: shouldShowSignIn,
            catalogIsPreparing: catalogIsPreparing,
            hasCatalog: catalogIsReady
        ) {
        case .accountDeletion:
            AccountDeletionPendingView(
                issue: accountDeletionIssue,
                retry: {
                    Task { _ = await retryPendingAccountDeletionIfNeeded() }
                }
            )
        case .signIn:
            SignInView(
                googleInvitation: invitationInbox.isGoogleEntryEligible
                    ? invitationInbox.pending
                    : nil,
                googleSpecialEntry: googleSpecialEntryActive
            )
        case .catalogLoading:
            catalogLoadingView
        case .catalog:
            ContentView(
                catalogLibrary: catalogLibrary,
                sharedLocationInbox: sharedLocationInbox
            )
        case .catalogIndependent:
            CatalogIndependentContentView(
                catalogLibrary: catalogLibrary,
                sharedLocationInbox: sharedLocationInbox
            )
        }
    }

    private var catalogIsReady: Bool {
        catalogLibrary.dataSource?.readiness == .ready
    }

    private var catalogIsPreparing: Bool {
        guard !catalogIsReady else { return false }
        return switch catalogLibrary.phase {
        case .idle, .discovering, .loading, .downloading:
            true
        case .ready:
            true
        case .failed:
            false
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

        private static let shinagakiWideTestImage = UIGraphicsImageRenderer(
            size: CGSize(width: 1_188, height: 600)
        ).image { context in
            UIColor.systemBackground.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1_188, height: 600))

            UIColor.systemRed.setStroke()
            context.cgContext.setLineWidth(12)
            context.cgContext.stroke(
                CGRect(x: 80, y: 80, width: 1_028, height: 440)
            )

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.label,
            ]
            NSString(string: "PAGE 2")
                .draw(at: CGPoint(x: 450, y: 250), withAttributes: attributes)
        }
    #endif

    @MainActor
    private func receiveGoogleSpecialEntry(_ url: URL) -> Bool {
        if GoogleSpecialEntryLink.isTrigger(url) {
            do {
                _ = try AppData.prepareGoogleAuthenticationFlow(entryContext: .special)
                googleSpecialEntryActive = true
            } catch {
                googleSpecialEntryActive = true
            }
            return true
        }
        guard GoogleEntryGrantCallbackParser.isCallbackURL(url) else { return false }
        googleSpecialEntryActive = true
        Task {
            // Publication stays inside the service actor. A logout ordered
            // before this task clears the stored flow and rejects the callback.
            try? await CominaviServiceClient.shared
                .recordPendingGoogleEntryGrantCallback(url)
        }
        return true
    }

    @MainActor
    private func receiveAppleSpecialEntry(_ url: URL) -> Bool {
        if AppleSpecialEntryLink.isTrigger(url) {
            do {
                _ = try AppData.prepareAppleAuthenticationFlow(entryContext: .special)
                googleSpecialEntryActive = true
            } catch {
                googleSpecialEntryActive = true
            }
            return true
        }
        guard AppleEntryGrantCallbackParser.isCallbackURL(url) else { return false }
        googleSpecialEntryActive = true
        Task {
            try? await CominaviServiceClient.shared
                .recordPendingAppleEntryGrantCallback(url)
        }
        return true
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
                String(localized: "The C%d catalog is not available."),
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
                title: String(localized: "Catalog unavailable"),
                message: catalogResetIssue ?? message,
                advice: String(localized: "Please try again.")
            ) {
                FocusedActionButton {
                    catalogLibrary.retry()
                } label: {
                    LucideLabel("Try Again", icon: "arrow.clockwise")
                }

                FocusedActionButton(
                    role: .destructive,
                    emphasis: .secondary,
                    tint: .red,
                    action: { showsCatalogResetConfirmation = true }
                ) {
                    if isResettingAfterCatalogError {
                        ProgressView()
                    } else {
                        LucideLabel(
                            "Log Out & Reset",
                            icon: "person.crop.circle.badge.minus"
                        )
                    }
                }
                .disabled(isResettingAfterCatalogError)
            }
        case .loading(let event):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                CatalogActivityIndicator(
                    accessibilityLabel: String(localized: "Opening catalog…")
                )
            }
        case .downloading(let event, let progress):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Downloading catalog…"),
                subtitle: String(localized: "Downloading the catalog, this may take a while…")
            ) {
                DownloadProgressView(progresses: [progress])
            }
        case .idle, .discovering, .ready:
            CatalogStatusSurface(
                symbolName: "sparkles",
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Finding available catalogs…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                CatalogActivityIndicator(
                    accessibilityLabel: String(localized: "Finding available catalogs…")
                )
            }
        }
    }

    private func logOutAndResetAfterCatalogError() {
        guard !isResettingAfterCatalogError else { return }
        AppTrack.userIntent(
            .signOutStarted,
            data: ["reason": "catalog_error_reset"]
        )
        isResettingAfterCatalogError = true
        catalogResetIssue = nil
        let dataSource = AppData.circlems

        Task {
            let coordinator = ProfileLogoutCoordinator(
                revokeSession: {
                    try await CominaviServiceClient.shared.revokeSession()
                },
                clearLocalUserData: {
                    await AppData.clearSharedPlanUserData()
                    profileStore.clear()
                }
            )
            do {
                try await coordinator.perform()
            } catch {
                catalogResetIssue = error.localizedDescription
                isResettingAfterCatalogError = false
                return
            }

            userState.user = nil
            catalogLibrary.reset()
            await dataSource?.cleanAllCaches()
            do {
                try await CominaviCatalogInstaller.removeAllDownloadedData()
            } catch {
                catalogResetIssue = error.localizedDescription
            }
            isResettingAfterCatalogError = false
        }
    }
}

#if DEBUG
private struct ExploreOnboardingUITestSurface: View {
    @State private var catalogLibrary = CatalogLibrary(initialMode: .demo)
    @State private var selectedDay = 1

    var body: some View {
        Group {
            if let dataSource = catalogLibrary.dataSource,
               dataSource.readiness == .ready
            {
                ExploreView(dataSource: dataSource, selectedDay: $selectedDay) {
                    EmptyView()
                }
            } else {
                ProgressView("Preparing Explore…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if catalogLibrary.phase == .idle {
                catalogLibrary.start()
            }
        }
    }
}
#endif

private struct AccountDeletionPendingView: View {
    let issue: String?
    let retry: () -> Void

    var body: some View {
        FocusedActionSurface(
            symbolName: "person.crop.circle.badge.xmark",
            tint: issue == nil ? .accentColor : .orange
        ) {
            Text("Deleting your account")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))

            if let issue {
                Text(issue)
                    .foregroundStyle(.orange)
                    .padding(.top, 18)
            }

            FocusedActionButton(action: retry) {
                LucideLabel("Try again", icon: "arrow.clockwise")
            }
                .padding(.top, 28)
                .accessibilityIdentifier("account-deletion-retry")
        }
    }
}

#Preview {
    EntryView()
}
