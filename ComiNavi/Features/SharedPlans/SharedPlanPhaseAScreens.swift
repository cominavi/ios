import SwiftUI
import UIKit

enum SharedPlanManagementSheet: Identifiable {
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
        case discardQuarantinedWrite(UUID)

        var id: String {
            switch self {
            case .administrative(let action): action.id
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
                    model: model
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
            if model.visibleInvitations.isEmpty, model.invitationIssue == nil, model.isRefreshing {
                SharedPlanLoadingRow(label: "Loading invitations")
            } else if model.visibleInvitations.isEmpty {
                ContentUnavailableView(
                    "No active invitation links",
                    systemImage: "link",
                    description: Text(model.invitationIssue ?? String(localized: "Create a link to add someone to this plan."))
                )
            } else {
                ForEach(model.visibleInvitations) { invitation in
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

            if let issue = model.invitationIssue, !model.visibleInvitations.isEmpty {
                SharedPlanInlineIssue(message: issue) {
                    Task { await model.refresh(using: store) }
                }
            }
        } header: {
            Text("Invitations")
        } footer: {
            Text("Invite links stop working when they expire or the plan is archived.")
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
        case .discardQuarantinedWrite:
            String(localized: "This saved change will be removed and cannot be recovered.")
        }
    }
}

struct SharedPlanNotificationInboxScreen: View {
    let store: SharedPlanStore
    let features: SharedPlanPresentationFeatures
    let currentUserID: String?
    let catalogDataSource: CirclemsDataSource?
    let onOpenCirclePlan: (String, Int?) -> Void
    @State private var model = SharedPlanNotificationInboxModel()

    init(
        store: SharedPlanStore,
        currentUserID: String? = nil,
        catalogDataSource: CirclemsDataSource? = nil,
        features: SharedPlanPresentationFeatures = .production,
        onOpenCirclePlan: @escaping (String, Int?) -> Void
    ) {
        self.store = store
        self.currentUserID = currentUserID
        self.catalogDataSource = catalogDataSource
        self.features = features
        self.onOpenCirclePlan = onOpenCirclePlan
    }

    var body: some View {
        List {
            if let issue = model.issueMessage, !model.notifications.isEmpty {
                SharedPlanInlineIssue(message: issue) {
                    Task { await model.refresh(using: store) }
                }
            }

            ForEach(model.displayItems) { displayItem in
                SharedPlanNotificationRow(
                    displayItem: displayItem,
                    planName: model.planNames[displayItem.primary.planID],
                    planComiketNumber: model.planComiketNumbers[displayItem.primary.planID],
                    isPendingRead: displayItem.notifications.contains {
                        model.pendingReadIDs.contains($0.id)
                    },
                    readIssue: displayItem.notifications.compactMap {
                        model.readIssues[$0.id]
                    }.first,
                    catalogDataSource: catalogDataSource
                ) {
                    onOpenCirclePlan(
                        displayItem.primary.planID,
                        displayItem.presentation(planName: model.planNames[displayItem.primary.planID])?
                            .publicCircleID
                    )
                } onSeen: {
                    Task { await model.markSeen(displayItem, using: store) }
                } onRetryRead: {
                    Task { await model.retryRead(displayItem, using: store) }
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
                    Text(model.issueMessage ?? String(localized: "Circle, purchase, and conflict updates will appear here."))
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

struct SharedPlanMemberRow: View {
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

struct SharedPlanInvitationRow: View {
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
                .accessibilityLabel("Revoke invitation...")
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
                    ? String(localized: "This change needs your review before it can be sent.")
                    : String(localized: "Waiting to send.")))
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct SharedPlanInlineIssue: View {
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

struct SharedPlanLoadingRow: View {
    let label: LocalizedStringResource

    var body: some View {
        HStack {
            ProgressView()
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SharedPlanLoadMoreRow: View {
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

struct SharedPlanCreateInvitationSheet: View {
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

struct SharedPlanCreatedInvitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invitation: SharedPlanCreatedInvitation
    let model: SharedPlanManagementModel
    @State private var copied = false
    @Environment(\.appHapticFeedback) private var hapticFeedback

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Share this link")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    VStack(spacing: 0) {
                        LabeledContent("Expires") {
                            Text(invitation.expiresAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)

                        Divider()
                            .padding(.leading, 16)

                        LabeledContent("Invitation status") {
                            Label(availability.title, systemImage: availability.systemImage)
                                .foregroundStyle(availability.color)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: 24)
                    )

                    Text(availability.canShare
                        ? String(localized: "Share this link with the person you want to add.")
                        : String(localized: "This invitation link is no longer available."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                VStack(spacing: 0) {
                    ShareLink(item: invitation.canonicalURL) {
                        Label("Share invitation link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!availability.canShare)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                    Divider()
                        .padding(.leading, 16)

                    Button {
                        UIPasteboard.general.url = invitation.canonicalURL
                        copied = true
                        hapticFeedback?.play(.copyConfirmation)
                    } label: {
                        Label(
                            copied ? "Invitation link copied" : "Copy invitation link",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!availability.canShare)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 24)
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Invitation link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
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
    let displayItem: SharedPlanNotificationDisplayItem
    let planName: String?
    let planComiketNumber: Int?
    let isPendingRead: Bool
    let readIssue: String?
    let catalogDataSource: CirclemsDataSource?
    let onOpen: () -> Void
    let onSeen: () -> Void
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
                                .font(.caption.weight(displayItem.isUnread ? .semibold : .regular))
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
                            Text("Plan activity")
                                .font(.caption.weight(.medium))
                            Text("Open the plan to see what changed.")
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
                Label("Marking as read", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let readIssue {
                HStack {
                    Text(readIssue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry", action: onRetryRead)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 3)
        .onAppear(perform: onSeen)
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
            displayItem: displayItem,
            planName: planName
        )
    }

    private var notification: SharedPlanNotificationItem { displayItem.primary }

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
        if displayItem.isUnread, !isPendingRead {
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

private extension SharedPlanNotificationDisplayItem {
    func presentation(planName: String?) -> SharedPlanNotificationPresentation? {
        SharedPlanNotificationPresentation.make(displayItem: self, planName: planName)
    }
}

extension SharedPlanAdministrativeAction {
    var menuTitle: LocalizedStringResource {
        switch self {
        case .revokeMember: "Remove member..."
        case .reinstateMember: "Reinstate member..."
        case .transferOwnership: "Transfer ownership..."
        case .revokeInvitation: "Revoke invitation..."
        }
    }

    var confirmationButtonTitle: LocalizedStringResource {
        switch self {
        case .revokeMember: "Remove member"
        case .reinstateMember: "Reinstate member"
        case .transferOwnership: "Transfer ownership"
        case .revokeInvitation: "Revoke invitation"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .revokeMember(_, let name):
            String.localizedStringWithFormat(
                String(localized: "%@ will immediately lose access. Changes they have not sent will not be shared."),
                name
            )
        case .reinstateMember(_, let name):
            String.localizedStringWithFormat(
                String(localized: "%@ will regain access."),
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
