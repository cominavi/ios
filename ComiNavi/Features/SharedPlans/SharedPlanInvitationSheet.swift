import SwiftUI

struct SharedPlanInvitationSheet: View {
    let pending: SharedPlanInvitationInbox.Pending
    let profileStore: CominaviProfileStore
    let invitationInbox: SharedPlanInvitationInbox
    let onDismiss: () -> Void

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
            .navigationTitle("共有プランへの招待")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        cancelInvitation()
                    }
                    .disabled(isAccepting)
                }
            }
        }
        // The only dismiss paths are explicit: Cancel deletes the route
        // capability, while “Log in and continue” intentionally retains it.
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
                Text("招待を確認しています…")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("共有プランの名前と参加先アカウントを安全に確認しています。")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                CatalogActivityIndicator(accessibilityLabel: "招待を確認しています…")
                    .padding(.top, 30)
            }
        } else if let preview {
            FocusedActionSurface(symbolName: "person.crop.circle.badge.plus") {
                Text("C\(preview.comiketNo) · 共有プラン")
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
                            Text("このアカウントで参加します")
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
                            LucideLabel("このプランに参加", icon: "person.crop.circle.badge.plus")
                        }
                    }
                    .disabled(isAccepting)
                    .padding(.top, 28)
                } else {
                    Text("参加する本人の名前とプロフィール画像を確認してから追加します。ログインして続けてください。")
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)

                    FocusedActionButton(action: onDismiss) {
                        LucideLabel("ログインして続ける", icon: "person.crop.circle.badge.plus")
                    }
                    .padding(.top, 28)
                }

                Text("参加後はメンバー全員がプランを編集できます。招待リンクは信頼できる相手だけに共有してください。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)
            }
        } else {
            FocusedActionSurface(
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange
            ) {
                Text("招待を確認できません")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(issue ?? "この招待リンクは利用できません。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("shared-plan-invitation-error")

                if canRetryPreview {
                    FocusedActionButton(action: {
                        Task { await loadPreview() }
                    }) {
                        LucideLabel("もう一度確認", icon: "arrow.clockwise")
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
