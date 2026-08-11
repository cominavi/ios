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

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("招待を確認しています…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if let preview {
                    Section("共有プラン") {
                        LabeledContent("プラン名") {
                            Text(preview.planName)
                                .accessibilityIdentifier("shared-plan-invitation-plan-name")
                        }
                        LabeledContent("コミケ") {
                            Text("C\(preview.comiketNo)")
                                .accessibilityIdentifier("shared-plan-invitation-comiket")
                        }
                    }

                    if profileStore.isIdentityVerified, let profile = profileStore.profile {
                        Section("このアカウントで参加") {
                            HStack(spacing: 12) {
                                AuthenticatedProfileAvatar(url: profile.avatarURL, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                        .font(.headline)
                                    Text("参加後はメンバー全員がプランを編集できます。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Button {
                                accept()
                            } label: {
                                if isAccepting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("このプランに参加")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isAccepting)
                        }
                    } else {
                        Section("ログインが必要です") {
                            Text("参加する本人の名前とプロフィール画像を確認してから追加します。ログインして続けてください。")
                            Button("ログインして続ける") {
                                onDismiss()
                            }
                        }
                    }

                    Section {
                        Text("招待リンクを知っている人は、期限内であればこのプランに参加できます。リンクは信頼できる相手だけに共有してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let issue {
                    Section {
                        Text(issue)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("shared-plan-invitation-error")
                    }
                }
            }
            .navigationTitle("共有プランへの招待")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        invitationInbox.clear()
                        onDismiss()
                    }
                }
            }
        }
        // The only dismiss paths are explicit: Cancel deletes the route
        // capability, while “Log in and continue” intentionally retains it.
        .interactiveDismissDisabled()
        .task(id: pending.token) { await loadPreview() }
    }

    private func loadPreview() async {
        isLoading = true
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
        } catch {
            if SharedPlanInvitationFailurePolicy.consumesRouteCapability(after: error) {
                invitationInbox.removePersistedCapability(token: pending.token)
            }
            preview = nil
            issue = error.localizedDescription
        }
    }

    private func accept() {
        guard profileStore.isIdentityVerified,
              let profile = profileStore.profile,
              !isAccepting
        else { return }
        isAccepting = true
        Task {
            do {
                let store = AppData.sharedPlanStore(for: profile.id)
                _ = try await store.acceptInvitation(token: pending.token)
                // The durable acceptance outbox now owns a protected Keychain
                // copy, so the route capability can be deleted immediately.
                invitationInbox.consume(token: pending.token)
                onDismiss()
            } catch {
                issue = error.localizedDescription
            }
            isAccepting = false
        }
    }
}
