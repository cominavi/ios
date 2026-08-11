import SwiftUI
import UIKit

private enum SharedPlanManagementSheet: Identifiable {
    case createInvitation
    case createdInvitation(SharedPlanCreatedInvitation)

    var id: String {
        switch self {
        case .createInvitation: "create-invitation"
        case .createdInvitation(let invitation):
            "created-invitation:\(invitation.requestID.uuidString.lowercased())"
        }
    }
}

struct SharedPlanManagementScreen: View {
    private enum Confirmation: Identifiable {
        case administrative(SharedPlanAdministrativeAction)
        case discardProtectedInvitation(UUID)
        case discardQuarantinedWrite(UUID)

        var id: String {
            switch self {
            case .administrative(let action): action.id
            case .discardProtectedInvitation(let id): "discard-protected:\(id)"
            case .discardQuarantinedWrite(let id): "discard-quarantine:\(id)"
            }
        }
    }

    let store: SharedPlanStore
    @State private var model: SharedPlanManagementModel
    @State private var presentedSheet: SharedPlanManagementSheet?
    @State private var confirmation: Confirmation?

    init(
        store: SharedPlanStore,
        planID: String,
        features: SharedPlanPresentationFeatures = .production
    ) {
        self.store = store
        _model = State(initialValue: SharedPlanManagementModel(
            planID: planID,
            features: features
        ))
    }

    var body: some View {
        List {
            if !model.features.writesEnabled {
                SharedPlanReadOnlyNotice()
            }

            pendingAndRecoverySections
            protectedInvitationsSection
            membersSection
            invitationsSection
        }
        .navigationTitle("Members and invitations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.permitsInvitationCreation {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentedSheet = .createInvitation
                    } label: {
                        Label("Create invitation", systemImage: "person.badge.plus")
                    }
                    .disabled(model.isPerformingAction)
                    .accessibilityIdentifier("shared-plan-create-invitation")
                }
            }
        }
        .refreshable { await model.refresh(using: store) }
        .task(id: model.planID) { await model.load(using: store) }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .createInvitation:
                SharedPlanCreateInvitationSheet(
                    model: model,
                    store: store,
                    presentedSheet: $presentedSheet
                )
            case .createdInvitation(let invitation):
                SharedPlanCreatedInvitationSheet(
                    invitation: invitation,
                    model: model,
                    store: store
                )
            }
        }
        .confirmationDialog(
            "Confirm Shared Plan change",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation
        ) { item in
            confirmationActions(item)
        } message: { item in
            Text(confirmationMessage(item))
        }
        .alert(
            "Shared Plan could not be updated",
            isPresented: Binding(
                get: { model.actionIssue != nil },
                set: { if !$0 { model.dismissActionIssue() } }
            )
        ) {
            Button("OK") { model.dismissActionIssue() }
        } message: {
            Text(model.actionIssue ?? String(localized: "Please try again."))
        }
    }

    @ViewBuilder
    private var pendingAndRecoverySections: some View {
        if !model.pendingWrites.isEmpty {
            Section("Pending changes") {
                ForEach(model.pendingWrites) { write in
                    SharedPlanAdministrativeWriteRow(
                        write: write,
                        issue: model.writeIssues[write.id],
                        isQuarantined: false
                    )
                }
            }
        }

        if !model.quarantinedWrites.isEmpty {
            Section {
                ForEach(model.quarantinedWrites) { write in
                    VStack(alignment: .leading, spacing: 8) {
                        SharedPlanAdministrativeWriteRow(
                            write: write,
                            issue: model.writeIssues[write.id],
                            isQuarantined: true
                        )
                        Button("Discard this saved change", role: .destructive) {
                            confirmation = .discardQuarantinedWrite(write.id)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isPerformingAction)
                    }
                }

                if model.hasRevisionConflictRecovery,
                   model.permitsQuarantineRetry
                {
                    Button("Retry against the latest plan") {
                        Task { await model.retryQuarantinedWrites(using: store) }
                    }
                    .disabled(model.isPerformingAction)
                }
            } header: {
                Text("Changes needing review")
            } footer: {
                Text("These changes are not retried automatically. Review them before retrying or discarding them.")
            }
        }
    }

    @ViewBuilder
    private var protectedInvitationsSection: some View {
        if !model.protectedInvitations.isEmpty {
            Section {
                ForEach(model.protectedInvitations) { invitation in
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        SharedPlanProtectedInvitationRow(
                            invitation: invitation,
                            availability: model.protectedInvitationAvailability(
                                for: invitation,
                                now: context.date
                            ),
                            onOpen: { presentedSheet = .createdInvitation(invitation) },
                            onDiscard: {
                                confirmation = .discardProtectedInvitation(
                                    invitation.requestID
                                )
                            }
                        )
                    }
                }
            } header: {
                Text("One-time invitation links")
            } footer: {
                Text("Invitation tokens are protected on this device. Discard each one after sharing it.")
            }
        }
    }

    private var membersSection: some View {
        Section {
            if model.members.isEmpty, model.memberIssue == nil, model.isRefreshing {
                SharedPlanLoadingRow(label: "Loading members")
            } else if model.members.isEmpty {
                ContentUnavailableView(
                    "No members available",
                    systemImage: "person.2.slash",
                    description: Text(model.memberIssue ?? String(localized: "Pull to refresh and try again."))
                )
            } else {
                ForEach(model.members) { member in
                    SharedPlanMemberRow(
                        member: member,
                        canManage: model.permitsMembershipAdministration
                    ) { action in
                        confirmation = .administrative(action)
                    }
                }
                if model.canLoadMoreMembers {
                    SharedPlanLoadMoreRow(
                        label: "Load more members",
                        isLoading: model.isLoadingMoreMembers
                    ) {
                        Task { await model.loadMoreMembers(using: store) }
                    }
                }
            }

            if let issue = model.memberIssue, !model.members.isEmpty {
                SharedPlanInlineIssue(message: issue) {
                    Task { await model.refresh(using: store) }
                }
            }
        } header: {
            Text("Members")
        } footer: {
            if model.isOwner {
                Text("Removed members remain listed so the owner can explicitly reinstate them.")
            }
        }
    }

    private var invitationsSection: some View {
        Section {
            if model.invitations.isEmpty, model.invitationIssue == nil, model.isRefreshing {
                SharedPlanLoadingRow(label: "Loading invitations")
            } else if model.invitations.isEmpty {
                ContentUnavailableView(
                    "No invitations",
                    systemImage: "link",
                    description: Text(model.invitationIssue ?? String(localized: "No invitations have been created for this plan."))
                )
            } else {
                ForEach(model.invitations) { invitation in
                    SharedPlanInvitationRow(
                        invitation: invitation,
                        canManage: model.permitsInvitationRevocation(
                            invitationID: invitation.invitationID
                        )
                    ) {
                        confirmation = .administrative(.revokeInvitation(
                            invitationID: invitation.invitationID
                        ))
                    }
                }
                if model.canLoadMoreInvitations {
                    SharedPlanLoadMoreRow(
                        label: "Load more invitations",
                        isLoading: model.isLoadingMoreInvitations
                    ) {
                        Task { await model.loadMoreInvitations(using: store) }
                    }
                }
            }

            if let issue = model.invitationIssue, !model.invitations.isEmpty {
                SharedPlanInlineIssue(message: issue) {
                    Task { await model.refresh(using: store) }
                }
            }
        } header: {
            Text("Invitations")
        } footer: {
            Text("Invite links stop working when they expire, are revoked, or the plan is archived.")
        }
    }

    @ViewBuilder
    private func confirmationActions(_ item: Confirmation) -> some View {
        switch item {
        case .administrative(let action):
            Button(role: action.isDestructive ? .destructive : nil) {
                confirmation = nil
                Task { await model.perform(action, using: store) }
            } label: {
                Text(action.confirmationButtonTitle)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .discardProtectedInvitation(let requestID):
            Button("Discard invitation token", role: .destructive) {
                confirmation = nil
                Task {
                    _ = await model.discardProtectedInvitation(
                        requestID: requestID,
                        using: store
                    )
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .discardQuarantinedWrite(let id):
            Button("Discard saved change", role: .destructive) {
                confirmation = nil
                Task { await model.discardQuarantinedWrite(id: id, using: store) }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        }
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .administrative(let action): action.confirmationMessage
        case .discardProtectedInvitation:
            String(localized: "The invitation token cannot be displayed again after it is discarded.")
        case .discardQuarantinedWrite:
            String(localized: "The saved intent will be removed from this device and cannot be recovered.")
        }
    }
}

struct SharedPlanNotificationInboxScreen: View {
    let store: SharedPlanStore
    let features: SharedPlanPresentationFeatures
    let currentUserID: String?
    let catalogDataSource: CirclemsDataSource?
    @State private var model = SharedPlanNotificationInboxModel()

    init(
        store: SharedPlanStore,
        currentUserID: String? = nil,
        catalogDataSource: CirclemsDataSource? = nil,
        features: SharedPlanPresentationFeatures = .production
    ) {
        self.store = store
        self.currentUserID = currentUserID
        self.catalogDataSource = catalogDataSource
        self.features = features
    }

    var body: some View {
        @Bindable var model = model
        List {
            if let issue = model.issueMessage, !model.notifications.isEmpty {
                SharedPlanInlineIssue(message: issue) {
                    Task { await model.refresh(using: store) }
                }
            }

            ForEach(model.notifications) { notification in
                SharedPlanNotificationRow(
                    notification: notification,
                    planName: model.planNames[notification.planID],
                    planComiketNumber: model.planComiketNumbers[notification.planID],
                    isPendingRead: model.pendingReadIDs.contains(notification.id),
                    readIssue: model.readIssues[notification.id],
                    catalogDataSource: catalogDataSource
                ) {
                    Task { await model.open(notification, using: store) }
                } onRetryRead: {
                    Task { await model.retryRead(notification, using: store) }
                }
            }

            if model.canLoadMore {
                SharedPlanLoadMoreRow(
                    label: "Load more notifications",
                    isLoading: model.isLoadingMore
                ) {
                    Task { await model.loadMore(using: store) }
                }
            }
        }
        .overlay {
            if model.notifications.isEmpty, !model.isRefreshing {
                FocusedActionSurface(
                    symbolName: model.issueMessage == nil
                        ? "antenna.radiowaves.left.and.right"
                        : "exclamationmark.triangle.fill",
                    tint: model.issueMessage == nil ? .accentColor : .orange
                ) {
                    Text(model.issueMessage == nil ? "No notifications" : "Notifications unavailable")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(model.issueMessage ?? String(localized: "Shared Plan updates and conflicts will appear here."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                    if model.issueMessage != nil {
                        FocusedActionButton {
                            Task { await model.refresh(using: store) }
                        } label: {
                            LucideLabel("Try Again", icon: "arrow.clockwise")
                        }
                        .padding(.top, 28)
                    }
                }
                .allowsHitTesting(model.issueMessage != nil)
            }
        }
        .navigationTitle("Notifications")
        .refreshable { await model.refresh(using: store) }
        .task { await model.load(using: store) }
        .navigationDestination(item: $model.selectedPlanID) { planID in
            SharedPlanDetailScreen(
                store: store,
                planID: planID,
                currentUserID: currentUserID,
                features: features,
                catalogDataSource: catalogDataSource
            )
        }
    }
}

struct SharedPlanReadOnlyNotice: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared Plans are read-only")
                        .font(.headline)
                    Text("You can view plans, members, invitations, notifications, and saved recovery copies. Editing will be available in a later update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SharedPlanMemberRow: View {
    let member: SharedPlanMember
    let canManage: Bool
    let onAction: (SharedPlanAdministrativeAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedProfileAvatar(url: member.avatarURL, size: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(member.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(member.role.localizedTitle)
                    if member.membershipStatus == .removed {
                        Text("Removed")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if canManage, let actions = availableActions, !actions.isEmpty {
                Menu {
                    ForEach(actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            onAction(action)
                        } label: {
                            Label(action.menuTitle, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Label("Member actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(Text("Actions for \(member.displayName)"))
            }
        }
        .padding(.vertical, 2)
    }

    private var availableActions: [SharedPlanAdministrativeAction]? {
        guard member.role != .owner else { return nil }
        switch member.membershipStatus {
        case .active:
            return [
                .transferOwnership(userID: member.userID, displayName: member.displayName),
                .revokeMember(userID: member.userID, displayName: member.displayName),
            ]
        case .removed:
            return [.reinstateMember(userID: member.userID, displayName: member.displayName)]
        }
    }
}

private struct SharedPlanInvitationRow: View {
    let invitation: SharedPlanInvitation
    let canManage: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.body.weight(.medium))
                Text(invitation.expiresAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if canManage, invitation.currentUserCanRevoke, status == .active {
                Button(role: .destructive, action: onRevoke) {
                    Label("Revoke invitation", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Revoke invitation")
            }
        }
        .padding(.vertical, 2)
    }

    private var status: Status {
        if invitation.revokedAt != nil { return .revoked }
        if invitation.expiresAt <= Date() { return .expired }
        return .active
    }

    private enum Status: Equatable {
        case active
        case expired
        case revoked

        var title: LocalizedStringResource {
            switch self {
            case .active: "Active invitation"
            case .expired: "Expired invitation"
            case .revoked: "Revoked invitation"
            }
        }

        var systemImage: String {
            switch self {
            case .active: "link"
            case .expired: "clock.badge.xmark"
            case .revoked: "xmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .active: .accentColor
            case .expired, .revoked: .secondary
            }
        }
    }
}

private struct SharedPlanProtectedInvitationRow: View {
    let invitation: SharedPlanCreatedInvitation
    let availability: SharedPlanProtectedInvitationAvailability
    let onOpen: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Protected invitation link")
                            .font(.body.weight(.medium))
                        Label(availability.title, systemImage: availability.systemImage)
                            .font(.caption)
                            .foregroundStyle(availability.color)
                        Text(invitation.expiresAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            Button("Discard token", role: .destructive, action: onDiscard)
                .buttonStyle(.borderless)
        }
    }
}

private struct SharedPlanAdministrativeWriteRow: View {
    let write: SharedPlanRESTWrite
    let issue: String?
    let isQuarantined: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isQuarantined ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(isQuarantined ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(write.kind.localizedAdministrativeTitle)
                    .font(.body.weight(.medium))
                Text(issue ?? (isQuarantined
                    ? String(localized: "Automatic retry is paused until you review this change.")
                    : String(localized: "Saved on this device and waiting to send.")))
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SharedPlanInlineIssue: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            Button("Try Again", action: retry)
                .buttonStyle(.borderless)
        }
    }
}

private struct SharedPlanLoadingRow: View {
    let label: LocalizedStringResource

    var body: some View {
        HStack {
            ProgressView()
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SharedPlanLoadMoreRow: View {
    let label: LocalizedStringResource
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if isLoading { ProgressView() }
            }
        }
        .disabled(isLoading)
    }
}

private struct SharedPlanCreateInvitationSheet: View {
    let model: SharedPlanManagementModel
    let store: SharedPlanStore
    @Binding var presentedSheet: SharedPlanManagementSheet?
    @State private var expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Expiration") {
                    DatePicker(
                        "Invitation expires",
                        selection: $expiresAt,
                        in: minimumExpiration ... maximumExpiration,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section {
                    Text("The invite link is reusable until it expires, is revoked, or the plan is archived.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Create invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        Task {
                            let outcome = await model.createInvitation(
                                expiresAt: expiresAt,
                                using: store
                            )
                            isSubmitting = false
                            switch outcome {
                            case .created(let invitation):
                                presentedSheet = .createdInvitation(invitation)
                            case .queued:
                                presentedSheet = nil
                            case nil:
                                break
                            }
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
        .presentationDetents([.medium])
    }

    private var minimumExpiration: Date {
        Date().addingTimeInterval(60)
    }

    private var maximumExpiration: Date {
        Date().addingTimeInterval(90 * 24 * 60 * 60)
    }
}

private struct SharedPlanCreatedInvitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invitation: SharedPlanCreatedInvitation
    let model: SharedPlanManagementModel
    let store: SharedPlanStore
    @State private var copied = false
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(availability: model.protectedInvitationAvailability(
                    for: invitation,
                    now: context.date
                ))
            }
        }
    }

    private func content(
        availability: SharedPlanProtectedInvitationAvailability
    ) -> some View {
            Form {
                Section {
                    LabeledContent("Invitation code") {
                        Text(invitation.token)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    LabeledContent("Expires") {
                        Text(invitation.expiresAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    LabeledContent("Invitation status") {
                        Label(availability.title, systemImage: availability.systemImage)
                            .foregroundStyle(availability.color)
                    }
                } header: {
                    Text("Save this invitation now")
                } footer: {
                    Text(availability.canShare
                        ? String(localized: "For security, the server returns this token only once. ComiNavi keeps it protected on this device until you discard it.")
                        : String(localized: "This protected token is retained only for review or discard and can no longer be shared."))
                }

                Section {
                    ShareLink(item: invitation.canonicalURL) {
                        Label("Share invitation link", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!availability.canShare)
                    Button {
                        UIPasteboard.general.url = invitation.canonicalURL
                        copied = true
                    } label: {
                        Label(
                            copied ? "Invitation link copied" : "Copy invitation link",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(!availability.canShare)
                }

                Section {
                    Button("Discard invitation token", role: .destructive) {
                        confirmsDiscard = true
                    }
                }
            }
            .navigationTitle("Invitation link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Discard this invitation token?",
                isPresented: $confirmsDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard token", role: .destructive) {
                    Task {
                        if await model.discardProtectedInvitation(
                            requestID: invitation.requestID,
                            using: store
                        ) {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The invitation itself remains listed, but this device can never display its token again.")
            }
    }
}

private extension SharedPlanProtectedInvitationAvailability {
    var title: LocalizedStringResource {
        switch self {
        case .active: "Active invitation"
        case .expired: "Expired invitation"
        case .revoked: "Revoked invitation"
        case .unavailable: "Invitation status unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "link"
        case .expired: "clock.badge.xmark"
        case .revoked: "xmark.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .active: .accentColor
        case .expired, .revoked, .unavailable: .secondary
        }
    }
}

private struct SharedPlanNotificationRow: View {
    let notification: SharedPlanNotificationItem
    let planName: String?
    let planComiketNumber: Int?
    let isPendingRead: Bool
    let readIssue: String?
    let catalogDataSource: CirclemsDataSource?
    let onOpen: () -> Void
    let onRetryRead: () -> Void
    @State private var circleSummary: CatalogNotificationCircle?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    if let presentation {
                        Image(systemName: presentation.systemImage)
                            .foregroundStyle(presentation.isConflict ? .orange : .accent)
                            .font(.caption)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.title)
                                .font(.caption.weight(notification.readAt == nil ? .semibold : .regular))
                            circleSummaryLine
                            Text(presentation.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            notificationTimestamp
                        }
                        .multilineTextAlignment(.leading)
                    } else {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shared Plan update")
                                .font(.caption.weight(.medium))
                            Text("Open the plan to review this update.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            notificationTimestamp
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 10) {
                        unreadIndicator
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)

            if isPendingRead {
                Label("Read status waiting to send", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let readIssue {
                HStack {
                    Text(readIssue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry read status", action: onRetryRead)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 3)
        .task(id: circleSummaryTaskID) {
            circleSummary = nil
            guard let publicCircleID = presentation?.publicCircleID,
                  let catalogDataSource,
                  catalogDataSource.readiness == .ready,
                  let catalogComiket = catalogDataSource.comiket,
                  planComiketNumber == catalogComiket.number
            else { return }
            circleSummary = await catalogDataSource.notificationCircle(
                publicCircleID: publicCircleID
            )
        }
    }

    private var presentation: SharedPlanNotificationPresentation? {
        SharedPlanNotificationPresentation.make(
            notification: notification,
            planName: planName
        )
    }

    private var circleSummaryTaskID: String {
        let isReady = catalogDataSource?.readiness == .ready
        return "\(catalogDataSource?.eventID ?? 0):\(presentation?.publicCircleID ?? 0):\(isReady)"
    }

    @ViewBuilder
    private var circleSummaryLine: some View {
        if let circleSummary {
            HStack(spacing: 6) {
                if let imageData = circleSummary.coverImageData,
                   let image = UIImage(data: imageData)
                {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipped()
                        .clipShape(.rect(cornerRadius: 4))
                        .accessibilityHidden(true)
                }
                Text(circleSummary.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var notificationTimestamp: some View {
        HStack(spacing: 4) {
            Text(notification.createdAt, format: .relative(presentation: .named))
            Text("•")
                .accessibilityHidden(true)
            Text(
                notification.createdAt,
                format: .dateTime.year().month(.abbreviated).day().hour().minute()
            )
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var unreadIndicator: some View {
        if notification.readAt == nil, !isPendingRead {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
        } else {
            Color.clear
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }
}

private extension SharedPlanAdministrativeAction {
    var menuTitle: LocalizedStringResource {
        switch self {
        case .revokeMember: "Remove member"
        case .reinstateMember: "Reinstate member"
        case .transferOwnership: "Transfer ownership"
        case .revokeInvitation: "Revoke invitation"
        }
    }

    var confirmationButtonTitle: LocalizedStringResource { menuTitle }

    var confirmationMessage: String {
        switch self {
        case .revokeMember(_, let name):
            String.localizedStringWithFormat(
                String(localized: "%@ will immediately lose access. Unsynced work remains only on their device."),
                name
            )
        case .reinstateMember(_, let name):
            String.localizedStringWithFormat(
                String(localized: "%@ will regain access with a new synchronization identity."),
                name
            )
        case .transferOwnership(_, let name):
            String.localizedStringWithFormat(
                String(localized: "%@ will become the owner. You will become an editor."),
                name
            )
        case .revokeInvitation:
            String(localized: "Anyone using this invitation link will no longer be able to join.")
        }
    }

    var systemImage: String {
        switch self {
        case .revokeMember: "person.badge.minus"
        case .reinstateMember: "person.badge.plus"
        case .transferOwnership: "person.crop.circle.badge.checkmark"
        case .revokeInvitation: "xmark.circle"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .revokeMember, .transferOwnership, .revokeInvitation: true
        case .reinstateMember: false
        }
    }
}

private extension SharedPlanRole {
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .owner: "Owner"
        case .editor: "Editor"
        case .viewer: "Viewer"
        }
    }
}

private extension SharedPlanRESTWriteKind {
    var localizedAdministrativeTitle: LocalizedStringResource {
        switch self {
        case .revokeMember: "Remove member"
        case .reinstateMember: "Reinstate member"
        case .transferOwnership: "Transfer ownership"
        case .createInvitation: "Create invitation"
        case .revokeInvitation: "Revoke invitation"
        case .create: "Create plan"
        case .rename: "Rename plan"
        case .archive: "Archive plan"
        case .reopen: "Reopen plan"
        case .acceptInvitation: "Join invitation"
        }
    }
}
