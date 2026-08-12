//
//  ProfileScreen.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/3/24.
//

import AuthenticationServices
import ImageIO
import SwiftUI
import UIKit

/// Keeps the durable service logout as the first suspension/failure boundary.
/// The backend revokes the auth epoch and push registrations atomically; local
/// account caches are cleared only after the protected logout command exists.
@MainActor
struct ProfileLogoutCoordinator {
    let revokeSession: () async throws -> Void
    let clearLocalUserData: () async -> Void

    func perform() async throws {
        try await revokeSession()
        try Task.checkCancellation()
        await clearLocalUserData()
    }
}

struct ProfileScreen: View {
    private struct ProfileEditorPresentation: Identifiable {
        let id: String
    }

    @AppStorage(SharedLocationClipboardImporter.enabledDefaultsKey)
    private var automaticallyReadsSharedLocations = false
    @State private var isShowingLogoutConfirmation = false
    @State private var isLoggingOut = false
    @State private var isShowingAccountDeletionConfirmation = false
    @State private var isDeletingAccount = false
    @State private var userState = AppData.userState
    @State private var profileStore = AppData.profileStore
    let sharedLocationInbox: SharedLocationInbox
    @State private var profileIssue: String?
    @State private var isShowingPendingMutationDiscardConfirmation = false
    @State private var profileEditorPresentation: ProfileEditorPresentation?
    @State private var favoriteRecoveries: [QuarantinedCanonicalFavoriteMutation] = []
    @State private var favoriteRecoveryIssue: String?
    @State private var favoriteRecoveryPendingDiscard: QuarantinedCanonicalFavoriteMutation?
    @StateObject private var circlemsLinkViewModel = SignInViewModel()
    let catalogLibrary: CatalogLibrary

    @MainActor
    init(
        catalogLibrary: CatalogLibrary = AppData.catalogLibrary,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox
    ) {
        self.catalogLibrary = catalogLibrary
        self.sharedLocationInbox = sharedLocationInbox
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    AuthenticatedProfileAvatar(
                        url: profileStore.profile?.avatarURL,
                        size: 88,
                        revision: profileStore.profile?.revision
                    )
                    .accessibilityIdentifier("profile-avatar")
                    .padding(.trailing, 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLoggedIn ? "ComiNaviアカウント" : "ログインしていません")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(
                            profileStore.profile?.displayName
                                ?? userState.user?.nickname
                                ?? String(localized: "Not logged in")
                        )
                            .font(.title3)

                        if let profile = profileStore.profile {
                            HStack(spacing: 12) {
                                if let identity = profile.identities.first(where: {
                                    $0.provider == "circlems"
                                }) {
                                    Label {
                                        Text("Circle.ms · \(identity.profileDisplayDetail)")
                                            .lineLimit(1)
                                    } icon: {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("profile-circlems-status")
                                } else {
                                    Button {
                                        linkCirclemsIdentity(profile.id)
                                    } label: {
                                        if circlemsLinkViewModel.state == .authenticating {
                                            HStack(spacing: 5) {
                                                ProgressView()
                                                Text("Circle.msを連携中…")
                                            }
                                        } else {
                                            Label("Circle.msを連携", systemImage: "link")
                                        }
                                    }
                                    .disabled(
                                        !profileStore.isIdentityVerified
                                            || circlemsLinkViewModel.state == .authenticating
                                    )
                                    .accessibilityIdentifier("profile-link-circlems")
                                }

                                Spacer(minLength: 0)

                                Button {
                                    profileEditorPresentation = .init(id: profile.id)
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                .disabled(!profileStore.isIdentityVerified)
                                .accessibilityIdentifier("profile-edit")
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .padding(.top, 5)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            if !nonCirclemsIdentities.isEmpty {
                Section("プロフィール") {
                    ForEach(nonCirclemsIdentities, id: \.stableID) { identity in
                        LabeledContent(
                            providerDisplayName(identity.provider),
                            value: identity.profileDisplayDetail
                        )
                    }
                }
            }

            if let profileIssue {
                Section {
                    Text(profileIssue)
                        .foregroundStyle(.orange)
                }
            }

            if let issue = profileStore.issueMessage, issue != profileIssue {
                Section {
                    Text(issue)
                        .foregroundStyle(.orange)
                }
            }

            if profileStore.hasPendingMutation {
                Section("送信待ちのプロフィール変更") {
                    if let description = profileStore.pendingMutationDescription {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }

                    Button("再送する") {
                        retryPendingProfileMutation()
                    }
                    .disabled(profileStore.isSaving || !profileStore.isIdentityVerified)

                    Button("この変更を破棄", role: .destructive) {
                        isShowingPendingMutationDiscardConfirmation = true
                    }
                    .disabled(profileStore.isSaving)
                }
            }

            if !favoriteRecoveries.isEmpty {
                Section("お気に入り変更の確認") {
                    ForEach(favoriteRecoveries) { recovery in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("送信できなかったお気に入り変更")
                                .font(.subheadline.weight(.semibold))
                            Text(recovery.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !recovery.affectedPublicCircleIDs.isEmpty {
                                Text(
                                    "Affected circles: \(recovery.affectedPublicCircleIDs.count)"
                                )
                                .font(.caption.monospacedDigit())
                                .textSelection(.enabled)
                            }

                            HStack {
                                ShareLink(item: favoriteRecoveryExport(recovery)) {
                                    Label("書き出す", systemImage: "square.and.arrow.up")
                                }

                                Spacer()

                                Button("破棄", role: .destructive) {
                                    favoriteRecoveryPendingDiscard = recovery
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }

            if let favoriteRecoveryIssue {
                Section {
                    Text(favoriteRecoveryIssue)
                        .foregroundStyle(.orange)
                }
            }

            if let dataSource = catalogLibrary.dataSource {
                Section("X followed circles") {
                    NavigationLink {
                        FollowingImportView(dataSource: dataSource)
                    } label: {
                        HStack(spacing: 12) {
                            LucideIcon("users", size: 24)
                                .foregroundStyle(Color.accentColor)
                            Text("Find followed circles")
                            Spacer()
                            Text("Import")
                        }
                    }
                    .accessibilityIdentifier("profile-following-import")
                }
            }

            Section("Shared locations") {
                Toggle(
                    "Detect locations from clipboard",
                    isOn: $automaticallyReadsSharedLocations
                )
                .accessibilityIdentifier("profile-auto-read-shared-location")

                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    sharedLocationInbox.receiveClipboardText(value)
                }
                .buttonBorderShape(.roundedRectangle)
                .accessibilityIdentifier("profile-paste-shared-location")
            }

            Section("ツール") {
                NavigationLink {
                    ComiketToolboxView()
                } label: {
                    Label("コミケツールボックス", systemImage: "square.grid.2x2")
                }
            }

            Section("Account") {
                Button {
                    if !isLoggedIn {
                        returnToAuthentication()
                    } else {
                        isShowingLogoutConfirmation = true
                    }
                } label: {
                    HStack {
                        LucideIcon(isLoggedIn ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
                            .frame(width: 24, height: 24)

                        Text(isLoggedIn ? "ログアウト" : "ログイン")
                    }
                    .foregroundStyle(isLoggedIn ? Color.red : Color.primary)
                }
                .accessibilityIdentifier("profile-account-action")
                .disabled(isLoggingOut || isDeletingAccount)

                if profileStore.profile != nil {
                    Button("Delete ComiNavi account", role: .destructive) {
                        isShowingAccountDeletionConfirmation = true
                    }
                    .disabled(
                        isLoggingOut || isDeletingAccount
                            || !profileStore.isIdentityVerified
                    )
                    .accessibilityIdentifier("profile-delete-account")
                }
            }
        }
        .navigationTitle("Profile")
        .sheet(item: $profileEditorPresentation) { _ in
            NavigationStack {
                ProfileEditorScreen(profileStore: profileStore)
            }
        }
        .fullScreenCover(isPresented: $isShowingAccountDeletionConfirmation) {
            AccountDeletionConfirmationView {
                deleteAccount()
            }
        }
        .task {
            guard let flow = try? AppData.pendingCirclemsAuthorizationFlow(),
                  flow.purpose == .link,
                  flow.isReadyToComplete,
                  let userID = profileStore.profile?.id,
                  profileStore.isIdentityVerified
            else { return }
            await linkCirclemsIdentityAndWait(userID)
        }
        .task(id: catalogLibrary.dataSource?.comiket.number) {
            await loadFavoriteRecoveries()
        }
        .confirmationDialog(
            "ComiNaviからログアウトしますか？",
            isPresented: $isShowingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("ログアウト", role: .destructive) {
                returnToAuthentication()
            }
            .accessibilityIdentifier("profile-confirm-log-out")

            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このアカウントの共有プラン、未送信の変更、ダウンロード済みカタログを削除します。")
        }
        .confirmationDialog(
            "送信待ちのプロフィール変更を破棄しますか？",
            isPresented: $isShowingPendingMutationDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("変更を破棄", role: .destructive) {
                do {
                    try profileStore.discardPendingMutation()
                    profileIssue = nil
                } catch {
                    profileIssue = error.localizedDescription
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("未送信の変更は復元できません。")
        }
        .confirmationDialog(
            "このお気に入り変更を破棄しますか？",
            isPresented: Binding(
                get: { favoriteRecoveryPendingDiscard != nil },
                set: { if !$0 { favoriteRecoveryPendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("変更を破棄", role: .destructive) {
                discardFavoriteRecovery()
            }
            Button("キャンセル", role: .cancel) {
                favoriteRecoveryPendingDiscard = nil
            }
        } message: {
            Text("書き出していない変更内容は復元できません。")
        }
    }

    private var isLoggedIn: Bool {
        profileStore.profile != nil || userState.user != nil
    }

    private var nonCirclemsIdentities: [CominaviProfileIdentity] {
        profileStore.profile?.identities.filter { $0.provider != "circlems" } ?? []
    }

    private func returnToAuthentication() {
        let dataSource = AppData.circlems
        guard isLoggedIn else {
            withAnimation {
                catalogLibrary.reset()
            }
            return
        }
        guard !isLoggingOut else { return }
        isLoggingOut = true
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
                profileIssue = error.localizedDescription
                isLoggingOut = false
                return
            }
            withAnimation {
                userState.user = nil
                catalogLibrary.reset()
                isLoggingOut = false
            }
            await dataSource?.cleanAllCaches()
        }
    }

    private func deleteAccount() {
        guard !isDeletingAccount, profileStore.isIdentityVerified else { return }
        isDeletingAccount = true
        Task {
            do {
                _ = try await CominaviServiceClient.shared.requestAccountDeletion()
                _ = try await AppData.finishAccountDeletionLocalCleanupIfNeeded()
                profileIssue = nil
            } catch {
                // The protected exact request remains queued for lifecycle and
                // reachability recovery. Do not clear caches before a 202.
                profileIssue = error.localizedDescription
            }
            isDeletingAccount = false
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "circlems": "Circle.ms"
        case "google": "Google"
        case "apple": "Apple"
        default: provider
        }
    }

    private func retryPendingProfileMutation() {
        Task {
            do {
                try await profileStore.drainPendingMutation()
                profileIssue = nil
            } catch {
                profileIssue = error.localizedDescription
            }
        }
    }

    private func loadFavoriteRecoveries() async {
        guard let dataSource = catalogLibrary.dataSource else {
            favoriteRecoveries = []
            return
        }
        do {
            favoriteRecoveries = try await dataSource.userPlanStore
                .quarantinedCanonicalFavoriteMutations(
                    eventNumber: dataSource.comiket.number
                )
            favoriteRecoveryIssue = nil
        } catch {
            favoriteRecoveryIssue = error.localizedDescription
        }
    }

    private func discardFavoriteRecovery() {
        guard let recovery = favoriteRecoveryPendingDiscard,
              let dataSource = catalogLibrary.dataSource
        else { return }
        favoriteRecoveryPendingDiscard = nil
        Task {
            do {
                try await dataSource.userPlanStore
                    .discardQuarantinedCanonicalFavoriteMutation(
                        eventNumber: recovery.mutation.eventNumber,
                        mutationID: recovery.mutation.mutationID
                    )
                await loadFavoriteRecoveries()
            } catch {
                favoriteRecoveryIssue = error.localizedDescription
            }
        }
    }

    private func favoriteRecoveryExport(
        _ recovery: QuarantinedCanonicalFavoriteMutation
    ) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recovery),
              let value = String(data: data, encoding: .utf8)
        else { return recovery.message }
        return value
    }

    private func linkCirclemsIdentity(_ userID: String) {
        Task { await linkCirclemsIdentityAndWait(userID) }
    }

    private func linkCirclemsIdentityAndWait(_ userID: String) async {
        do {
            _ = try await circlemsLinkViewModel.linkCirclems(publicUserID: userID)
            await profileStore.load()
            profileIssue = nil
        } catch {
            let value = error as NSError
            if value.code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                profileIssue = error.localizedDescription
            }
        }
    }
}

extension CominaviProfileIdentity {
    var profileDisplayDetail: String {
        if provider == "circlems" {
            return email ?? String(localized: "連携済み")
        }
        return email ?? environment ?? String(localized: "連携済み")
    }
}

struct AuthenticatedProfileAvatar: View {
    let url: URL?
    let size: CGFloat
    let revision: Int?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(url: URL?, size: CGFloat, revision: Int? = nil) {
        self.url = url
        self.size = size
        self.revision = revision
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.original)
            } else {
                LucideIcon("circle-user", size: Double(size))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel("プロフィール画像")
        .task(id: loadID) {
            image = nil
            guard let url,
                  let data = try? await CominaviServiceClient.shared.loadAvatarData(from: url)
            else { return }
            image = AvatarImageProcessor.circularImage(
                from: data,
                pointSize: size,
                displayScale: displayScale
            )
        }
    }

    private var loadID: String {
        "\(url?.relativeString ?? "")#\(revision.map(String.init) ?? "")#\(size)x\(displayScale)"
    }
}

extension AvatarImageProcessor {
    /// Tab bars use the underlying image dimensions and can discard SwiftUI
    /// sizing and clipping modifiers. Produce a correctly sized circular image
    /// so an avatar remains bounded even when used as a tab label icon.
    static func circularImage(
        from data: Data,
        pointSize: CGFloat,
        displayScale: CGFloat
    ) -> UIImage? {
        guard !data.isEmpty, pointSize > 0, displayScale > 0 else { return nil }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }

        let maximumPixelDimension = ceil(pointSize * displayScale)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }

        let sourceImage = UIImage(cgImage: thumbnail)
        let bounds = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        let sourceSize = sourceImage.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let fillScale = max(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let drawSize = CGSize(
            width: sourceSize.width * fillScale,
            height: sourceSize.height * fillScale
        )
        let drawRect = CGRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = displayScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            UIBezierPath(ovalIn: bounds).addClip()
            sourceImage.draw(in: drawRect)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

enum AccountDeletionConfirmationStep: Equatable {
    case accountSeparation
    case consequences
}

enum AccountDeletionConfirmationEvent: Equatable {
    case showConsequences
    case showSystemConfirmation
}

struct AccountDeletionConfirmationFlow: Equatable {
    static let countdownDuration = 5

    private(set) var step = AccountDeletionConfirmationStep.accountSeparation
    private(set) var secondsRemaining = Self.countdownDuration
    private(set) var isFinalConfirmationAvailable = false

    mutating func tick() -> AccountDeletionConfirmationEvent? {
        guard secondsRemaining > 0 else { return nil }
        secondsRemaining -= 1
        guard secondsRemaining == 0 else { return nil }

        switch step {
        case .accountSeparation:
            step = .consequences
            secondsRemaining = Self.countdownDuration
            return .showConsequences
        case .consequences:
            isFinalConfirmationAvailable = true
            return .showSystemConfirmation
        }
    }

    mutating func returnToAccountSeparation() {
        step = .accountSeparation
        secondsRemaining = Self.countdownDuration
        isFinalConfirmationAvailable = false
    }
}

private struct AccountDeletionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow = AccountDeletionConfirmationFlow()
    @State private var isShowingFinalConfirmation = false
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .accountSeparation:
                    accountSeparationPage
                case .consequences:
                    consequencesPage
                }
            }
            .toolbar {
                if flow.step == .consequences {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") {
                            returnToAccountSeparation()
                        }
                        .accessibilityIdentifier("profile-account-deletion-back")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .accessibilityIdentifier("profile-cancel-delete-account-top")
                }
            }
        }
        .interactiveDismissDisabled()
        .task(id: flow.step) {
            await runCountdown(for: flow.step)
        }
        .alert("Delete only your ComiNavi account?", isPresented: $isShowingFinalConfirmation) {
            Button("Delete ComiNavi account", role: .destructive) {
                onDelete()
                dismiss()
            }
            .accessibilityIdentifier("profile-confirm-delete-account")

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your ComiNavi account and its data. Your Circle.ms account will not be deleted, even if you connected it to ComiNavi.")
        }
    }

    private var accountSeparationPage: some View {
        FocusedActionSurface(
            symbolName: "person.crop.circle.badge.questionmark",
            tint: .orange
        ) {
            Text("Step 1 of 2")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("ComiNavi and Circle.ms are separate accounts")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Text("Deleting your ComiNavi account will not delete your Circle.ms account. If you connected Circle.ms, you can continue using that account directly on Circle.ms.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            VStack(spacing: 0) {
                AccountDeletionScopeRow(
                    title: "ComiNavi account",
                    status: "Will be deleted",
                    systemImage: "trash.fill",
                    tint: .red
                )

                Divider()

                AccountDeletionScopeRow(
                    title: "Circle.ms account",
                    status: "Will not be deleted",
                    systemImage: "checkmark.shield.fill",
                    tint: .green
                )
            }
            .padding(.horizontal, 18)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding(.top, 28)

            countdownStatus(
                title: "Reviewing account separation…",
                countdown: "Consequences shown in \(flow.secondsRemaining) seconds"
            )
            .padding(.top, 28)

            FocusedActionButton(
                role: .cancel,
                emphasis: .secondary,
                tint: .secondary,
                action: dismiss.callAsFunction
            ) {
                Text("Cancel")
            }
            .accessibilityIdentifier("profile-cancel-delete-account")
            .padding(.top, 28)
        }
        .accessibilityIdentifier("profile-account-deletion-separation")
    }

    private var consequencesPage: some View {
        FocusedActionSurface(
            symbolName: "person.crop.circle.badge.xmark",
            tint: .red
        ) {
            Text("Step 2 of 2")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.red)

            Text("Deleting your ComiNavi account cannot be undone")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Text("Owned Shared Plans will be deleted, and you will leave joined plans. Your profile, favorites, notifications, and pending changes will also be deleted. This cannot be undone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Label {
                Text("Your Circle.ms account will not be deleted.")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
            .padding(.top, 22)

            countdownStatus(
                title: flow.isFinalConfirmationAvailable
                    ? "Final confirmation is ready."
                    : "Reviewing deletion consequences…",
                countdown: "System confirmation shown in \(flow.secondsRemaining) seconds"
            )
            .padding(.top, 28)

            VStack(spacing: 12) {
                if flow.isFinalConfirmationAvailable {
                    FocusedActionButton(
                        role: .destructive,
                        tint: .red,
                        action: {
                            isShowingFinalConfirmation = true
                        }
                    ) {
                        Label("Show final confirmation", systemImage: "exclamationmark.triangle")
                    }
                    .accessibilityIdentifier("profile-show-final-account-deletion-confirmation")
                    .accessibilityHint("Opens the system confirmation. Your Circle.ms account will not be deleted.")
                }

                FocusedActionButton(
                    role: .cancel,
                    emphasis: .secondary,
                    tint: .secondary,
                    action: dismiss.callAsFunction
                ) {
                    Text("Cancel")
                }
                .accessibilityIdentifier("profile-cancel-delete-account")
            }
            .padding(.top, 28)
        }
        .accessibilityIdentifier("profile-account-deletion-consequences")
    }

    private func countdownStatus(
        title: LocalizedStringKey,
        countdown: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if flow.secondsRemaining > 0 {
                ProgressView(
                    value: Double(
                        AccountDeletionConfirmationFlow.countdownDuration
                            - flow.secondsRemaining
                    ),
                    total: Double(AccountDeletionConfirmationFlow.countdownDuration)
                )
                .tint(flow.step == .accountSeparation ? .orange : .red)

                Text(countdown)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func runCountdown(for expectedStep: AccountDeletionConfirmationStep) async {
        while flow.secondsRemaining > 0, flow.step == expectedStep {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard flow.step == expectedStep, let event = flow.tick() else { continue }
            switch event {
            case .showConsequences:
                break
            case .showSystemConfirmation:
                isShowingFinalConfirmation = true
            }
            return
        }
    }

    private func returnToAccountSeparation() {
        isShowingFinalConfirmation = false
        withAnimation(.snappy) {
            flow.returnToAccountSeparation()
        }
    }
}

private struct AccountDeletionScopeRow: View {
    let title: LocalizedStringKey
    let status: LocalizedStringKey
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(tint)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ProfileScreen()
}
