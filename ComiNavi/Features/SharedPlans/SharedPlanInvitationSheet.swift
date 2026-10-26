import SwiftUI

struct SharedPlanInvitationSheet: View {
    let pending: SharedPlanInvitationInbox.Pending
    let profileStore: CominaviProfileStore
    let invitationInbox: SharedPlanInvitationInbox
    let onDismiss: () -> Void
    /// Opens ComiNavi sign-in. The caller must keep `invitationInbox.pending`
    /// so the invitation opens again after sign-in completes. Without it, the
    /// sheet only closes and the invitation waits for a later sign-in.
    var onSignIn: (() -> Void)?

    @State private var preview: SharedPlanInvitationPreview?
    @State private var isLoading = true
    @State private var isAccepting = false
    @State private var issue: String?
    @State private var canRetryPreview = false
    @State private var acceptanceTask: Task<Void, Never>?
    @Environment(\.appHapticFeedback) private var hapticFeedback

    var body: some View {
        NavigationStack {
            invitationContent
            .navigationTitle("Shared Plan Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelInvitation()
                    }
                    .disabled(isAccepting)
                }
            }
        }
        // The only dismiss paths are explicit: Cancel deletes the route
        // capability, while “Sign in to continue” intentionally retains it.
        .interactiveDismissDisabled()
        .task(id: pending.token) { await loadPreview() }
    }

    @ViewBuilder
    private var invitationContent: some View {
        if isLoading {
            FocusedActionSurface(
                symbolName: "person.crop.circle.badge.plus",
                animatesBackdrop: true
            ) {
                Text("Checking invitation…")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("ComiNavi is securely checking the plan name and the account that will join.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                CatalogActivityIndicator(accessibilityLabel: "Checking invitation…")
                    .padding(.top, 30)
            }
        } else if let preview {
            FocusedActionSurface(symbolName: "person.crop.circle.badge.plus") {
                Text("C\(preview.comiketNo) · Shared Plan")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("shared-plan-invitation-comiket")

                Text(preview.planName)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityIdentifier("shared-plan-invitation-plan-name")

                if profileStore.isIdentityVerified, let profile = profileStore.profile {
                    HStack(spacing: 12) {
                        AuthenticatedProfileAvatar(url: profile.avatarURL, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.headline)
                            Text("You will join with this account")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 24)

                    if let issue {
                        invitationIssue(issue)
                    }

                    FocusedActionButton(action: accept) {
                        if isAccepting {
                            ProgressView()
                        } else {
                            LucideLabel("Join this plan", icon: "person.crop.circle.badge.plus")
                        }
                    }
                    .disabled(isAccepting)
                    .padding(.top, 28)
                } else {
                    Text("The plan shows your name and profile picture to its members. Sign in to continue.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)

                    FocusedActionButton(action: onSignIn ?? onDismiss) {
                        LucideLabel("Sign in to continue", icon: "circle-user")
                    }
                    .padding(.top, 28)
                    .accessibilityIdentifier("shared-plan-invitation-sign-in")

                    Text("Your invitation opens again after you sign in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                }

                Text("All members can edit the plan after they join. Share invitation links only with people you trust.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)
            }
        } else {
            FocusedActionSurface(
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange
            ) {
                Text("Cannot open invitation")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(issue ?? String(localized: "This invitation link cannot be used."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("shared-plan-invitation-error")

                if canRetryPreview {
                    FocusedActionButton(action: {
                        Task { await loadPreview() }
                    }) {
                        LucideLabel("Check again", icon: "arrow.clockwise")
                    }
                    .padding(.top, 28)
                }
            }
        }
    }

    private func invitationIssue(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LucideIcon("exclamationmark.circle", size: 20)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shared-plan-invitation-error")
    }

    private func loadPreview() async {
        isLoading = true
        canRetryPreview = false
        defer { isLoading = false }
        do {
            let loaded = try await CominaviServiceClient.shared.previewInvitation(
                token: pending.token
            )
            guard loaded.expiresAt > Date() else {
                invitationInbox.consume(token: pending.token)
                throw SharedPlanError.invalidInvite
            }
            preview = loaded
            issue = nil
            canRetryPreview = false
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            let consumesCapability = SharedPlanInvitationFailurePolicy
                .consumesRouteCapability(after: error)
            if consumesCapability {
                invitationInbox.removePersistedCapability(token: pending.token)
            }
            preview = nil
            issue = error.localizedDescription
            canRetryPreview = !consumesCapability
        }
    }

    private func accept() {
        guard profileStore.isIdentityVerified,
              let profile = profileStore.profile,
              !isAccepting,
              acceptanceTask == nil
        else { return }
        isAccepting = true
        acceptanceTask = Task {
            defer {
                isAccepting = false
                acceptanceTask = nil
            }
            do {
                let store = AppData.sharedPlanStore(for: profile.id)
                _ = try await store.acceptInvitation(token: pending.token)
                // The durable acceptance outbox now owns a protected Keychain
                // copy, so the route capability can be deleted immediately.
                invitationInbox.consume(token: pending.token)
                hapticFeedback?.play(.completion)
                onDismiss()
            } catch {
                guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                    return
                }
                issue = error.localizedDescription
                hapticFeedback?.play(.error)
            }
        }
    }

    private func cancelInvitation() {
        guard !isAccepting, acceptanceTask == nil else { return }
        invitationInbox.clear()
        onDismiss()
    }
}
