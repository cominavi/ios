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
    private enum PresentedSheet: Identifiable {
        case profileEditor(userID: String)
        case issueReport
        case signIn

        var id: String {
            switch self {
            case .profileEditor(let userID): "profile-editor-\(userID)"
            case .issueReport: "issue-report"
            case .signIn: "sign-in"
            }
        }
    }

    private enum FavoriteSyncState: Equatable {
        case idle
        case syncing
        case succeeded
        case failed(message: String)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var presentedSheet: PresentedSheet?
    @State private var favoriteRecoveries: [QuarantinedCanonicalFavoriteMutation] = []
    @State private var favoriteRecoveryIssue: String?
    @State private var favoriteRecoveryPendingDiscard: QuarantinedCanonicalFavoriteMutation?
    @State private var favoriteSyncState = FavoriteSyncState.idle
    let favoriteColorLabelStore: FavoriteColorLabelStore
    @StateObject private var circlemsLinkViewModel = SignInViewModel()
    let catalogLibrary: CatalogLibrary

    @MainActor
    init(
        catalogLibrary: CatalogLibrary = AppData.catalogLibrary,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox,
        favoriteColorLabelStore: FavoriteColorLabelStore =
            AppData.favoriteColorLabelStore
    ) {
        self.catalogLibrary = catalogLibrary
        self.sharedLocationInbox = sharedLocationInbox
        self.favoriteColorLabelStore = favoriteColorLabelStore
    }

    var body: some View {
        Form {
            accountHeaderSection

            if !nonCirclemsIdentities.isEmpty {
                Section("Linked accounts") {
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
                        .foregroundStyle(.red)
                }
            }

            // The sign-in card already asks a signed-out person to sign in, so a
            // stored session issue is only shown for an account that exists.
            if isLoggedIn, let issue = profileStore.issueMessage, issue != profileIssue {
                Section {
                    Text(issue)
                        .foregroundStyle(.red)
                }
            }

            if profileStore.hasPendingMutation {
                Section("Unsent profile changes") {
                    if let description = profileStore.pendingMutationDescription {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }

                    Button("Send Again") {
                        retryPendingProfileMutation()
                    }
                    .disabled(profileStore.isSaving || !profileStore.isIdentityVerified)

                    Button("Discard This Change", role: .destructive) {
                        isShowingPendingMutationDiscardConfirmation = true
                    }
                    .disabled(profileStore.isSaving)
                }
            }

            if !favoriteRecoveries.isEmpty {
                Section("Review favorite changes") {
                    ForEach(favoriteRecoveries) { recovery in
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Text("Favorite change not sent")
                                .font(.rowTitle)
                            Text(recovery.message)
                                .font(.meta)
                                .foregroundStyle(.secondary)
                                .wrapsFully()
                            if !recovery.affectedPublicCircleIDs.isEmpty {
                                Text(
                                    "Affected circles: \(recovery.affectedPublicCircleIDs.count)"
                                )
                                .font(.meta.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            }

                            // Equal-width buttons that stack when a translated
                            // title would wrap next to a one-line sibling.
                            AdaptiveButtonRow(spacing: Spacing.small) {
                                ShareLink(item: favoriteRecoveryExport(recovery)) {
                                    Label {
                                        Text("Export")
                                    } icon: {
                                        LucideIcon("square.and.arrow.up", size: IconSize.inline)
                                    }
                                }
                                .buttonStyle(.secondaryAction)

                                Button(role: .destructive) {
                                    favoriteRecoveryPendingDiscard = recovery
                                } label: {
                                    Text("Discard")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.secondaryAction)
                            }
                            .padding(.top, Spacing.xSmall)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }

            if let favoriteRecoveryIssue {
                Section {
                    Text(favoriteRecoveryIssue)
                        .foregroundStyle(.red)
                }
            }

            if let dataSource = catalogLibrary.dataSource {
                favoritesSection(dataSource)
            }

            // Image cache sits with Toolbox so that every card on the screen
            // has a header and the section rhythm stays regular.
            Section("Tools") {
                NavigationLink {
                    ComiketToolboxView(event: catalogLibrary.selectedEvent)
                } label: {
                    LucideLabel("Toolbox", icon: "square.grid.2x2")
                }
                .accessibilityIdentifier("profile-toolbox")

                NavigationLink {
                    ImageCacheManagementScreen()
                } label: {
                    Label {
                        Text("Image cache", tableName: "ImageCache")
                    } icon: {
                        LucideIcon("images")
                    }
                }
                .accessibilityIdentifier("profile-image-cache")
            }

            Section {
                // Every row in this list has a leading icon, so the text
                // column starts at one x position.
                Toggle(isOn: $automaticallyReadsSharedLocations) {
                    Label {
                        Text("Detect locations from clipboard")
                    } icon: {
                        LucideIcon("doc.on.doc")
                    }
                }
                .accessibilityIdentifier("profile-auto-read-shared-location")

                LabeledContent {
                    PasteButton(payloadType: String.self) { values in
                        guard let value = values.first else { return }
                        sharedLocationInbox.receiveClipboardText(value)
                    }
                    .buttonBorderShape(.roundedRectangle(radius: Radius.control))
                    // PasteButton draws white text. Dark olive keeps it legible
                    // in light and dark mode; lime behind white text does not.
                    .tint(Color.accentColor)
                    // The large size gives the button a 44 pt hit height.
                    .controlSize(.large)
                    .accessibilityIdentifier("profile-paste-shared-location")
                } label: {
                    Label {
                        Text("Open a copied link")
                    } icon: {
                        LucideIcon("mappin.and.ellipse")
                    }
                }
            } header: {
                Text("Settings")
            } footer: {
                Text(
                    "Friends can send you a ComiNavi location link. When this setting is on, ComiNavi checks the clipboard for a new link each time you return to the app. To open a link that you copied, tap Paste."
                )
            }

            Section("Support") {
                Button {
                    presentedSheet = .issueReport
                } label: {
                    // Same icon family, size, and colors as the navigation rows:
                    // an accent glyph next to a primary title.
                    Label {
                        Text("Report an issue")
                            .foregroundStyle(.primary)
                    } icon: {
                        LucideIcon("exclamationmark.circle")
                    }
                }
                .accessibilityIdentifier("profile-report-issue")
            }

            if isLoggedIn {
                Section("Account") {
                    Button(role: .destructive) {
                        isShowingLogoutConfirmation = true
                    } label: {
                        LucideLabel("Sign Out", icon: "person.crop.circle.badge.minus")
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
        }
        .readableFormWidth()
        .navigationTitle("Profile")
        .readableColumnTitleDisplayMode()
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .profileEditor:
                NavigationStack {
                    ProfileEditorScreen(profileStore: profileStore)
                }
            case .issueReport:
                IssueReportScreen()
            case .signIn:
                NavigationStack {
                    SignInView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { presentedSheet = nil }
                                    .accessibilityIdentifier("profile-cancel-sign-in")
                            }
                        }
                }
            }
        }
        .onChange(of: verifiedProfileID) { _, newValue in
            guard newValue != nil, case .signIn? = presentedSheet else { return }
            finishSignIn()
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
            favoriteSyncState = .idle
            await loadFavoriteRecoveries()
        }
        .confirmationDialog(
            "Sign out of ComiNavi?",
            isPresented: $isShowingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                signOut()
            }
            .accessibilityIdentifier("profile-confirm-log-out")

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this account's Shared Plans, unsent changes, and downloaded catalogs from this device.")
        }
        .confirmationDialog(
            "Discard the unsent profile change?",
            isPresented: $isShowingPendingMutationDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Change", role: .destructive) {
                do {
                    try profileStore.discardPendingMutation()
                    profileIssue = nil
                } catch {
                    profileIssue = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You cannot restore an unsent change.")
        }
        .confirmationDialog(
            "Discard this favorite change?",
            isPresented: Binding(
                get: { favoriteRecoveryPendingDiscard != nil },
                set: { if !$0 { favoriteRecoveryPendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Change", role: .destructive) {
                discardFavoriteRecovery()
            }
            Button("Cancel", role: .cancel) {
                favoriteRecoveryPendingDiscard = nil
            }
        } message: {
            Text("You cannot restore a change that you did not export.")
        }
    }

    /// Everything that acts on the person's favorites sits in one place, so
    /// the printable map, color labels, and X import are easy to find.
    private func favoritesSection(_ dataSource: CirclemsDataSource) -> some View {
        Section {
            NavigationLink {
                FavoriteMapPDFScreen(
                    dataSource: dataSource,
                    colorLabelStore: favoriteColorLabelStore
                )
            } label: {
                LucideLabel("Printable favorite map", icon: "map")
            }
            .accessibilityIdentifier("profile-favorite-map")

            NavigationLink {
                FavoriteColorLabelsScreen(store: favoriteColorLabelStore)
            } label: {
                LucideLabel("Color labels", icon: "tag")
            }
            .accessibilityIdentifier("profile-favorite-color-labels")

            NavigationLink {
                FollowingImportView(
                    dataSource: dataSource,
                    isSignedIn: isLoggedIn,
                    onSignIn: presentSignIn
                )
            } label: {
                LucideLabel("Import from X", icon: "users")
            }
            .accessibilityIdentifier("profile-following-import")

            if hasLinkedCirclemsIdentity {
                circlemsFavoriteSyncRows(dataSource)
            }
        } header: {
            Text("Your favorites")
        }
    }

    @ViewBuilder
    private func circlemsFavoriteSyncRows(_ dataSource: CirclemsDataSource) -> some View {
        Button {
            syncFavoritesToCirclems(dataSource)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("Sync favorites to Circle.ms")
                        .foregroundStyle(.primary)
                    Text(
                        "Adds or updates your ComiNavi favorites in Circle.ms. Existing Circle.ms memos and unrelated favorites are kept."
                    )
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                }
            } icon: {
                if favoriteSyncState == .syncing {
                    ProgressView()
                } else {
                    LucideIcon("arrow.triangle.2.circlepath")
                }
            }
        }
        .disabled(
            favoriteSyncState == .syncing
                || !profileStore.isIdentityVerified
        )
        .accessibilityIdentifier("profile-sync-circlems-favorites")

        switch favoriteSyncState {
        case .idle, .syncing:
            EmptyView()
        case .succeeded:
            Label {
                Text("ComiNavi favorites were synced to Circle.ms.")
                    .wrapsFully()
            } icon: {
                LucideIcon("checkmark.circle.fill", size: IconSize.caption)
            }
            .font(.meta)
            .foregroundStyle(.green)
            .accessibilityIdentifier("profile-sync-circlems-favorites-success")
        case .failed(let message):
            Text(message)
                .font(.meta)
                .foregroundStyle(.red)
                .wrapsFully()
                .accessibilityIdentifier("profile-sync-circlems-favorites-error")
        }
    }

    /// A person who never signed in (the demo catalog and App Review path)
    /// sees one value sentence and one Sign In action instead of an empty
    /// account header.
    @ViewBuilder
    private var accountHeaderSection: some View {
        Section {
            if isLoggedIn {
                signedInHeader
            } else {
                signedOutHeader
            }
        }
    }

    /// One avatar size for both account headers, so signing in does not
    /// move the text column.
    private static let headerAvatarSize: CGFloat = 56

    /// Avatar beside the text, or above it at accessibility sizes so the
    /// text keeps the full card width.
    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.medium))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.iconToText))
    }

    private var signedInHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            headerLayout {
                AuthenticatedProfileAvatar(
                    url: profileStore.profile?.avatarURL,
                    size: Self.headerAvatarSize,
                    revision: profileStore.profile?.revision
                )
                .accessibilityIdentifier("profile-avatar")

                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("ComiNavi account")
                        .font(.meta)
                        .foregroundStyle(.secondary)

                    Text(
                        profileStore.profile?.displayName
                            ?? userState.user?.nickname
                            ?? String(localized: "Signed in")
                    )
                    .font(.sectionTitle)
                    .wrapsFully()

                    if let profile = profileStore.profile,
                       let identity = profile.identities.first(where: {
                           $0.provider == "circlems"
                       })
                    {
                        Label {
                            // The email comes from data: one line, and the
                            // middle gives way so both ends stay readable.
                            Text("Circle.ms · \(identity.profileDisplayDetail)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            LucideIcon("checkmark.circle.fill", size: IconSize.caption)
                                .foregroundStyle(.green)
                        }
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.xSmall)
                        .accessibilityIdentifier("profile-circlems-status")
                    }
                }
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let profile = profileStore.profile {
                // Chips keep one line and a 44 pt hit area; the row wraps to
                // a column only when the titles do not fit side by side.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.small) {
                        accountChips(profile)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        accountChips(profile)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.small)
    }

    @ViewBuilder
    private func accountChips(_ profile: CominaviUserProfile) -> some View {
        Button {
            presentedSheet = .profileEditor(userID: profile.id)
        } label: {
            Text("Edit")
        }
        .buttonStyle(.chip)
        .disabled(!profileStore.isIdentityVerified)
        .accessibilityIdentifier("profile-edit")

        if !profile.identities.contains(where: { $0.provider == "circlems" }) {
            Button {
                linkCirclemsIdentity(profile.id)
            } label: {
                if circlemsLinkViewModel.state == .authenticating {
                    HStack(spacing: Spacing.xSmall) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Linking Circle.ms…")
                    }
                } else {
                    Text("Link Circle.ms")
                }
            }
            .buttonStyle(.chip)
            .disabled(
                !profileStore.isIdentityVerified
                    || circlemsLinkViewModel.state == .authenticating
            )
            .accessibilityIdentifier("profile-link-circlems")
        }
    }

    private var signedOutHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            headerLayout {
                AuthenticatedProfileAvatar(url: nil, size: Self.headerAvatarSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("Not signed in")
                        .font(.rowTitle)
                    Text("Sign in to sync plans and favorites")
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            // The card's one primary action: a flat lime fill with dark text,
            // the same in light and dark mode.
            Button(action: presentSignIn) {
                Text("Sign in")
            }
            .buttonStyle(.primaryAction)
            .accessibilityIdentifier("profile-sign-in")
        }
        .padding(.vertical, Spacing.small)
    }

    private var isLoggedIn: Bool {
        profileStore.profile != nil || userState.user != nil
    }

    private var nonCirclemsIdentities: [CominaviProfileIdentity] {
        profileStore.profile?.identities.filter { $0.provider != "circlems" } ?? []
    }

    private var hasLinkedCirclemsIdentity: Bool {
        profileStore.profile?.identities.contains { $0.provider == "circlems" } == true
    }

    private var verifiedProfileID: String? {
        guard profileStore.isIdentityVerified else { return nil }
        return profileStore.profile?.id
    }

    private func presentSignIn() {
        presentedSheet = .signIn
    }

    /// Sign-in from Profile keeps the current catalog open until the account
    /// is verified. Cancelling the sheet therefore leaves the demo catalog and
    /// the person's place in it untouched.
    private func finishSignIn() {
        presentedSheet = nil
        if catalogLibrary.mode == .demo {
            // A signed-in account reads the ComiNavi catalog, not the bundled
            // demo data. The app shell loads the new catalog once it is idle.
            withAnimation {
                catalogLibrary.selectMode(.cominavi)
            }
        }
        Task { await profileStore.load() }
    }

    private func signOut() {
        let dataSource = AppData.circlems
        guard isLoggedIn, !isLoggingOut else { return }
        AppTrack.userIntent(.signOutStarted)
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
        AppTrack.userIntent(.accountDeletionRequested)
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

    private func syncFavoritesToCirclems(_ dataSource: CirclemsDataSource) {
        guard favoriteSyncState != .syncing else { return }
        favoriteSyncState = .syncing
        Task {
            do {
                // Flush the durable local outbox first so the server mirrors the
                // canonical revision that includes this device's latest edits.
                try await dataSource.bookmarkSyncCoordinator?.sync()
                let result = try await CominaviServiceClient.shared
                    .syncCirclemsFavorites(eventNumber: dataSource.comiket.number)
                guard result.eventNumber == dataSource.comiket.number else {
                    throw CominaviServiceError.invalidResponse
                }
                favoriteSyncState = .succeeded
            } catch {
                favoriteSyncState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func discardFavoriteRecovery() {
        guard let recovery = favoriteRecoveryPendingDiscard,
              let dataSource = catalogLibrary.dataSource
        else { return }
        AppTrack.userIntent(
            .favoriteRecoveryDiscarded,
            data: ["event_number": recovery.mutation.eventNumber]
        )
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
            return email ?? String(localized: "Linked")
        }
        return email ?? environment ?? String(localized: "Linked")
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
                    .accessibilityLabel("Profile picture")
            } else {
                Self.placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: loadID) {
            image = nil
            guard let url else { return }
            let cacheKey = RemoteImagePipeline.authenticatedCacheKey(
                for: url,
                revision: revision
            )
            let data: Data
            if let cached = await RemoteImagePipeline.cachedImageData(
                forKey: cacheKey,
                category: .profileImages
            ) {
                data = cached
            } else if let downloaded = try? await CominaviServiceClient.shared.loadAvatarData(
                from: url
            ) {
                data = downloaded
                await RemoteImagePipeline.storeImageData(
                    downloaded,
                    forKey: cacheKey,
                    category: .profileImages
                )
            } else {
                return
            }
            guard !Task.isCancelled else { return }
            image = AvatarImageProcessor.circularImage(
                from: data,
                pointSize: size,
                displayScale: displayScale
            )
        }
    }

    /// The empty avatar. It fills the fixed frame exactly instead of
    /// scaling with Dynamic Type like `LucideIcon`, which would grow the
    /// glyph past the circular clip at large text sizes. It is decorative:
    /// the header text next to it already says that no picture is set.
    static var placeholder: some View {
        Image(decorative: LucideIcon.assetName(for: "circle-user"))
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.secondary)
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

struct AccountDeletionConfirmationFlow: Equatable {
    static let countdownDuration = 10

    private(set) var step = AccountDeletionConfirmationStep.accountSeparation
    private(set) var secondsRemaining = Self.countdownDuration

    var canContinue: Bool {
        step == .accountSeparation && secondsRemaining == 0
    }

    var canDelete: Bool {
        step == .consequences && secondsRemaining == 0
    }

    mutating func tick() {
        guard secondsRemaining > 0 else { return }
        secondsRemaining -= 1
    }

    @discardableResult
    mutating func continueToConsequences() -> Bool {
        guard canContinue else { return false }
        step = .consequences
        secondsRemaining = Self.countdownDuration
        return true
    }

    mutating func returnToAccountSeparation() {
        step = .accountSeparation
        secondsRemaining = Self.countdownDuration
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
            Button("Yes, Delete", role: .destructive) {
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
                .font(.rowTitle)
                .foregroundStyle(.orange)

            Text("ComiNavi and Circle.ms are separate accounts")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .wrapsFully()
                .padding(.top, Spacing.small)

            Text("Deleting your ComiNavi account will not delete your Circle.ms account. If you connected Circle.ms, you can continue using that account directly on Circle.ms.")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

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
            .padding(.horizontal, Spacing.cardPadding)
            .surface(.card, padding: 0)
            .padding(.top, Spacing.xxLarge)

            countdownStatus(
                title: flow.canContinue
                    ? "Ready to continue"
                    : "Read this before continuing",
                countdown: "Next available in \(flow.secondsRemaining) seconds"
            )
            .padding(.top, Spacing.xxLarge)

            VStack(spacing: Spacing.medium) {
                FocusedActionButton(
                    action: continueToConsequences
                ) {
                    Label("Next", systemImage: "arrow.right")
                }
                .disabled(!flow.canContinue)
                .accessibilityIdentifier("profile-account-deletion-next")

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
            .padding(.top, Spacing.xxLarge)
        }
        .accessibilityIdentifier("profile-account-deletion-separation")
    }

    private var consequencesPage: some View {
        FocusedActionSurface(
            symbolName: "person.crop.circle.badge.xmark",
            tint: .red
        ) {
            Text("Step 2 of 2")
                .font(.rowTitle)
                .foregroundStyle(.red)

            Text("Deleting your ComiNavi account cannot be undone")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .wrapsFully()
                .padding(.top, Spacing.small)

            Text("Owned Shared Plans will be deleted, and you will leave joined plans. Your profile, favorites, notifications, and pending changes will also be deleted. This cannot be undone.")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            Label {
                Text("Your Circle.ms account will not be deleted.")
                    .font(.rowTitle)
                    .wrapsFully()
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
            .padding(.top, Spacing.xxLarge)

            countdownStatus(
                title: flow.canDelete
                    ? "Ready to delete"
                    : "Review the consequences",
                countdown: "Delete available in \(flow.secondsRemaining) seconds"
            )
            .padding(.top, Spacing.xxLarge)

            VStack(spacing: Spacing.medium) {
                FocusedActionButton(
                    role: .destructive,
                    tint: .red,
                    action: {
                        guard flow.canDelete else { return }
                        isShowingFinalConfirmation = true
                    }
                ) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!flow.canDelete)
                .accessibilityIdentifier("profile-delete-account")

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
            .padding(.top, Spacing.xxLarge)
        }
        .accessibilityIdentifier("profile-account-deletion-consequences")
    }

    private func countdownStatus(
        title: LocalizedStringKey,
        countdown: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title)
                .font(.rowTitle)

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
            guard flow.step == expectedStep else { return }
            flow.tick()
        }
    }

    private func continueToConsequences() {
        guard flow.canContinue else { return }
        withAnimation(.snappy) {
            _ = flow.continueToConsequences()
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
        HStack(alignment: .center, spacing: Spacing.iconToText) {
            // SF Symbols: the Lucide set in the app has no trash or shield
            // glyph. A fixed-width column keeps both titles on one x position.
            Image(systemName: systemImage)
                .font(.rowTitle)
                .imageScale(.large)
                .foregroundStyle(tint)
                // 28 pt: the width of a large rowTitle symbol, so both
                // titles start at one x position.
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(title)
                    .font(.rowTitle)
                Text(status)
                    .font(.rowSubtitle)
                    .foregroundStyle(tint)
            }
            .wrapsFully()

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.cardPadding)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ProfileScreen()
}
