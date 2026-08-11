import SwiftUI

enum SharedPlanEditorAccessibilityID {
    static let openEditor = "shared-plan-open-editor"
    static let screen = "shared-plan-editor"
    static let syncStatus = "shared-plan-editor-sync-status"
    static let readOnly = "shared-plan-editor-read-only"
    static let addCircle = "shared-plan-editor-add-circle"
    static let recovery = "shared-plan-editor-recovery"
    static let recoveryRebase = "shared-plan-editor-recovery-rebase"
    static let recoveryDiscard = "shared-plan-editor-recovery-discard"
    static let recoveryDiscardConfirmation =
        "shared-plan-editor-recovery-discard-confirmation"
    static let conflictList = "shared-plan-editor-conflicts"

    static func circle(_ key: SharedPlanCircleKey) -> String {
        "shared-plan-editor-circle-\(key.id)"
    }

    static func memo(_ key: SharedPlanCircleKey) -> String {
        "shared-plan-editor-memo-\(key.id)"
    }

    static func addNeed(_ key: SharedPlanCircleKey) -> String {
        "shared-plan-editor-add-need-\(key.id)"
    }

    static func need(_ needID: UUID) -> String {
        "shared-plan-editor-need-\(needID.uuidString.lowercased())"
    }

    static func conflict(_ conflictID: String) -> String {
        "shared-plan-editor-conflict-\(conflictID)"
    }
}

struct SharedPlanEditorStatusPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case progress
        case success
        case warning
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone

    init(status: SharedPlanSyncConnectionStatus, pendingOperationCount: Int) {
        switch status {
        case .idle:
            title = String(localized: "Sync is stopped")
            detail = String(localized: "Open this screen while online to check for plan updates.")
            systemImage = "icloud.slash"
            tone = .neutral
        case .connecting:
            title = String(localized: "Connecting to Shared Plan")
            detail = Self.pendingDetail(pendingOperationCount)
            systemImage = "arrow.triangle.2.circlepath.icloud"
            tone = .progress
        case .connected(let mutationsEnabled, let pending):
            title = mutationsEnabled
                ? String(localized: "Shared Plan is connected")
                : String(localized: "Connected in read-only mode")
            detail = Self.pendingDetail(pending)
            systemImage = "icloud"
            tone = mutationsEnabled ? .progress : .neutral
        case .synchronized(let mutationsEnabled, let pending):
            title = mutationsEnabled
                ? String(localized: "Shared Plan is up to date")
                : String(localized: "Shared Plan is up to date and read-only")
            detail = Self.pendingDetail(pending)
            systemImage = pending == 0 ? "checkmark.icloud" : "icloud.and.arrow.up"
            tone = pending == 0 ? .success : .progress
        case .reconnecting:
            title = String(localized: "Reconnecting to Shared Plan")
            detail = Self.pendingDetail(pendingOperationCount)
            systemImage = "arrow.clockwise.icloud"
            tone = .warning
        case .quarantined:
            title = String(localized: "Sync is paused for review")
            detail = String(localized: "Saved content remains on this device until you choose a recovery action.")
            systemImage = "exclamationmark.icloud"
            tone = .warning
        }
    }

    private static func pendingDetail(_ count: Int) -> String {
        count == 0
            ? String(localized: "No changes are waiting to sync.")
            : String(localized: "\(count) changes are waiting to sync.")
    }
}

struct SharedPlanEditorReadOnlyPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let systemImage: String

    init(reason: SharedPlanEditorReadOnlyReason) {
        switch reason {
        case .featureDisabled:
            title = String(localized: "Shared Plan editing is not available yet")
            detail = String(localized: "You can review collaborative content and recovery data. Editing will appear after interoperable sync is enabled.")
            systemImage = "lock.fill"
        case .archived:
            title = String(localized: "This plan is archived")
            detail = String(localized: "Reopen the plan before changing circles or purchases.")
            systemImage = "archivebox.fill"
        case .insufficientRole:
            title = String(localized: "You have view-only access")
            detail = String(localized: "An owner or editor can change this plan.")
            systemImage = "eye.fill"
        case .waitingForWritableSync:
            title = String(localized: "Waiting for writable sync")
            detail = String(localized: "Keep this screen open while ComiNavi reconnects. No local edit will be accepted until authority is confirmed.")
            systemImage = "clock.arrow.circlepath"
        case .localLimit(let limit):
            switch limit {
            case .syncBacklog(let maximum, let pending):
                title = String(localized: "Sync before editing again")
                detail = String(localized: "\(pending) of \(maximum) unsynced changes are retained. The existing changes can continue syncing, but the next edit is blocked.")
                systemImage = "icloud.and.arrow.up.fill"
            case .compactionRequired:
                title = String(localized: "This plan needs compact recovery")
                detail = String(localized: "Retained operation data reached the 512 KiB safety limit. Export it, then rebase or discard the local branch.")
                systemImage = "externaldrive.badge.exclamationmark"
            }
        case .quarantine(let issue):
            title = Self.quarantineTitle(issue)
            detail = Self.quarantineDetail(issue)
            systemImage = "lock.trianglebadge.exclamationmark.fill"
        }
    }

    private static func quarantineTitle(_ issue: SharedPlanSyncIssue) -> String {
        switch issue {
        case .membershipRevoked:
            String(localized: "Plan access was removed")
        case .roleChanged:
            String(localized: "Your plan role changed")
        case .conflict:
            String(localized: "Sync authority needs review")
        case .unavailable:
            String(localized: "Saved plan data cannot be opened")
        case .compactionRequired, .serverCompactionRequired:
            String(localized: "The server requires plan recovery")
        case .backlogLimit:
            String(localized: "The server rejected an oversized sync backlog")
        }
    }

    private static func quarantineDetail(_ issue: SharedPlanSyncIssue) -> String {
        switch issue {
        case .membershipRevoked:
            String(localized: "Unsynced content is retained for export. Reinstatement starts a fresh editing generation.")
        case .roleChanged:
            String(localized: "Reload the plan to confirm the current role before editing again.")
        case .conflict:
            String(localized: "The local branch is preserved and will not retry automatically.")
        case .unavailable:
            String(localized: "Malformed saved data is never interpreted. It can only be exported or discarded.")
        case .compactionRequired, .serverCompactionRequired:
            String(localized: "Export the retained branch, then choose an available recovery action.")
        case .backlogLimit(let maximum, let received):
            String(localized: "The branch contains \(received) pending operations; the server limit is \(maximum). It will not retry as one unsplittable frame.")
        }
    }
}

struct SharedPlanConflictPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let path: String

    init(conflict: SharedPlanDocumentConflict) {
        path = Self.pathLabel(conflict.path)
        switch conflict.kind {
        case .parent:
            title = String(localized: "Choose the original item")
            detail = String(localized: "Select one creation as the parent, then make an explicit choice for every overlapping field.")
        case .scalar:
            title = String(localized: "Choose one value")
            detail = String(localized: "Concurrent edits produced more than one value. No value is selected silently.")
        case .removalVersusEdit:
            title = String(localized: "Choose removal or the later edit")
            detail = String(localized: "One person removed this item while another changed retained content. Descendant data stays available until you decide.")
        }
    }

    static func pathLabel(_ path: [String]) -> String {
        guard !path.isEmpty else { return String(localized: "Plan content") }
        if let last = path.last {
            switch last {
            case "presence": return String(localized: "Presence")
            case "memo": return String(localized: "Memo")
            case "wantedQuantity": return String(localized: "Wanted quantity")
            case "buyerAllocations": return String(localized: "Buyer allocation")
            case "fulfilledQuantity": return String(localized: "Fulfilled quantity")
            case "communicationState": return String(localized: "Communication")
            default: break
            }
        }
        if path.count == 2, path.first == "circles" {
            return String(localized: "Circle WCID \(path[1])")
        }
        if path.count >= 4, path[2] == "needs" {
            return String(localized: "Purchase need")
        }
        if path.contains("communicationState"), let field = path.last {
            return String(localized: "Communication: \(field)")
        }
        return path.joined(separator: " › ")
    }
}

extension SharedPlanJSONValue {
    var sharedPlanDisplayText: String {
        sharedPlanDisplayText(members: [:], currentUserID: nil)
    }

    func sharedPlanDisplayText(
        members: [String: SharedPlanMember],
        currentUserID: String?,
        depth: Int = 0
    ) -> String {
        guard depth < 4 else { return String(localized: "Additional structured details") }
        return switch self {
        case .null: String(localized: "Not set")
        case .boolean(true): String(localized: "Yes")
        case .boolean(false): String(localized: "No")
        case .integer(let value): value.formatted()
        case .string(let value):
            value.isEmpty
                ? String(localized: "Empty text")
                : String(value.prefix(120))
        case .array(let values):
            Self.boundedSummary(
                values.enumerated().map { index, value in
                    "\(index + 1). \(value.sharedPlanDisplayText(members: members, currentUserID: currentUserID, depth: depth + 1))"
                }
            )
        case .object(let values):
            if let state = values["state"]?.stringValue {
                state == SharedPlanPresenceState.active.rawValue
                    ? String(localized: "Active")
                    : String(localized: "Removed")
            } else {
                Self.boundedSummary(values.keys.sorted().map { key in
                    let label = members[key].map {
                        SharedPlanMemberPresentation.label(
                            $0,
                            currentUserID: currentUserID,
                            includesRole: false
                        )
                    } ?? key
                    let value = values[key]?.sharedPlanDisplayText(
                        members: members,
                        currentUserID: currentUserID,
                        depth: depth + 1
                    ) ?? String(localized: "Not set")
                    return "\(label): \(value)"
                })
            }
        }
    }

    private static func boundedSummary(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return String(localized: "Empty collection") }
        let visible = parts.prefix(6).joined(separator: " · ")
        let remaining = parts.count - min(parts.count, 6)
        return remaining == 0
            ? visible
            : String(localized: "\(visible) · \(remaining) more")
    }
}

private enum SharedPlanMemberPresentation {
    static func label(
        _ member: SharedPlanMember,
        currentUserID: String?,
        includesRole: Bool = true
    ) -> String {
        var pieces = [member.displayName]
        if member.userID == currentUserID { pieces.append(String(localized: "You")) }
        if includesRole { pieces.append(role(member.role)) }
        return pieces.joined(separator: " · ")
    }

    static func role(_ role: SharedPlanRole) -> String {
        switch role {
        case .owner: String(localized: "Owner")
        case .editor: String(localized: "Editor")
        case .viewer: String(localized: "Viewer")
        }
    }
}

private enum SharedPlanEditorSheet: Identifiable {
    case addCircle
    case resolveParent(conflictID: String, parentID: UUID)

    var id: String {
        switch self {
        case .addCircle: "add-circle"
        case .resolveParent(let conflictID, let parentID):
            "resolve-parent:\(conflictID):\(parentID.uuidString.lowercased())"
        }
    }
}

private enum SharedPlanEditorConfirmation: Identifiable {
    case discardRecovery

    var id: String { "discard-recovery" }
}

struct SharedPlanEditorScreen: View {
    let store: SharedPlanStore
    let currentUserID: String?
    @State private var model: SharedPlanEditorModel
    @State private var presentedSheet: SharedPlanEditorSheet?
    @State private var confirmation: SharedPlanEditorConfirmation?
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: SharedPlanStore,
        planID: String,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production
    ) {
        self.store = store
        self.currentUserID = currentUserID
        _model = State(initialValue: SharedPlanEditorModel(
            planID: planID,
            features: features
        ))
    }

    var body: some View {
        @Bindable var model = model
        List {
            statusSection
            readOnlySection
            recoverySection
            memoRecoverySection
            conflictSection
            progressSection
            circleSection
        }
        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.screen)
        .navigationTitle(model.plan?.name ?? String(localized: "Plan content"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentedSheet = .addCircle
                    } label: {
                        Label("Add circle", systemImage: "plus")
                    }
                    .disabled(model.isPerformingMutation)
                    .accessibilityIdentifier(SharedPlanEditorAccessibilityID.addCircle)
                }
            }
        }
        .refreshable { await model.reload(using: store) }
        .task(id: model.planID) {
            await model.run(using: store)
        }
        .task(id: scenePhase) {
            guard scenePhase != .active else { return }
            await model.flushAllMemos(using: store)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .addCircle:
                SharedPlanAddCircleSheet(
                    model: model,
                    store: store,
                    comiketNo: model.plan?.comiketNo,
                    presentedSheet: $presentedSheet
                )
            case .resolveParent(let conflictID, let parentID):
                SharedPlanParentResolutionSheet(
                    model: model,
                    store: store,
                    conflictID: conflictID,
                    parentID: parentID,
                    currentUserID: currentUserID,
                    presentedSheet: $presentedSheet
                )
            }
        }
        .confirmationDialog(
            "Discard the saved local branch?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation
        ) { _ in
            Button("Discard and load the server copy", role: .destructive) {
                confirmation = nil
                Task { await model.discardAndRebootstrap(using: store) }
            }
            .accessibilityIdentifier(
                SharedPlanEditorAccessibilityID.recoveryDiscardConfirmation
            )
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { _ in
            Text("Export the recovery data first if you may need it. Discarding cannot be undone.")
        }
        .alert(
            "Shared Plan could not be updated",
            isPresented: Binding(
                get: { model.issueMessage != nil },
                set: { if !$0 { model.dismissIssue() } }
            )
        ) {
            Button("OK") { model.dismissIssue() }
        } message: {
            Text(model.issueMessage ?? String(localized: "Please try again."))
        }
    }

    private var statusSection: some View {
        let presentation = SharedPlanEditorStatusPresentation(
            status: model.syncStatus,
            pendingOperationCount: model.pendingOperationCount
        )
        return Section("Sync") {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(statusColor(presentation.tone))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(SharedPlanEditorAccessibilityID.syncStatus)

            if case .reconnecting = model.syncStatus {
                Button("Retry sync") {
                    Task { await model.retrySync(using: store) }
                }
                .disabled(model.isStartingSync)
            }
        }
    }

    @ViewBuilder
    private var readOnlySection: some View {
        if let reason = model.readOnlyReason {
            let presentation = SharedPlanEditorReadOnlyPresentation(reason: reason)
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(presentation.title)
                            .font(.headline)
                        Text(presentation.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.readOnly)
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if let recovery = model.recoveryDocument {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Saved local recovery branch", systemImage: "externaldrive.badge.timemachine")
                        .font(.headline)
                    Text("\(recovery.pendingOperationCount) content changes and \(recovery.metadataIntentCount) plan changes are retained on this device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                ShareLink(item: recovery.exportText) {
                    Label("Export recovery data", systemImage: "square.and.arrow.up")
                }

                if model.features.writesEnabled, model.recoveryRebaseAvailable {
                    Button {
                        Task { await model.rebaseUnsyncedContent(using: store) }
                    } label: {
                        Label("Rebase onto the server copy", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(model.isPerformingMutation)
                    .accessibilityIdentifier(SharedPlanEditorAccessibilityID.recoveryRebase)
                }

                Button("Discard local branch", role: .destructive) {
                    confirmation = .discardRecovery
                }
                .disabled(model.isPerformingMutation)
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.recoveryDiscard)
            } header: {
                Text("Recovery")
            } footer: {
                if case .some(.unavailable) = model.syncIssue {
                    Text("This saved document is malformed and is never interpreted. Export or discard are the only safe actions.")
                } else if model.recoveryRebaseAvailable {
                    Text("Rebase replays valid unsynced operations onto a fresh server document. The original remains protected unless the replacement is saved atomically.")
                } else {
                    Text("Rebase is unavailable for this branch. Export it before discarding if you may need the content.")
                }
            }
            .accessibilityIdentifier(SharedPlanEditorAccessibilityID.recovery)
        }
    }

    @ViewBuilder
    private var memoRecoverySection: some View {
        if !model.memoDraftRecoveries.isEmpty {
            Section {
                ForEach(model.memoDraftRecoveries) { recovery in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WCID \(recovery.circle.wcID)")
                            .font(.headline)
                        Text(recovery.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ShareLink(item: recovery.exportText) {
                            Label("Export memo draft", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } header: {
                Text("Unsaved memo drafts")
            } footer: {
                Text("A memo draft is never presented as saved when editing authority was lost.")
            }
        }
    }

    @ViewBuilder
    private var conflictSection: some View {
        if !model.conflicts.isEmpty {
            Section {
                ForEach(model.conflicts) { conflict in
                    SharedPlanConflictRow(
                        conflict: conflict,
                        currentUserID: currentUserID,
                        members: model.activeMembersByUserID,
                        canResolve: model.canEdit && !model.isPerformingMutation,
                        onSelectCandidate: { candidate in
                            Task {
                                await model.resolveConflict(
                                    conflictID: conflict.id,
                                    selectedChangeHash: candidate.changeHash,
                                    using: store
                                )
                            }
                        },
                        onSelectParent: { parentID in
                            presentedSheet = .resolveParent(
                                conflictID: conflict.id,
                                parentID: parentID
                            )
                        }
                    )
                }
            } header: {
                Label("Conflicts requiring a choice", systemImage: "exclamationmark.bubble")
            } footer: {
                Text("ComiNavi keeps every meaningful concurrent value until a person makes an explicit choice.")
            }
            .accessibilityIdentifier(SharedPlanEditorAccessibilityID.conflictList)
        }
    }

    private var circleSection: some View {
        Section {
            if model.circles.isEmpty {
                ContentUnavailableView(
                    "No circles in this plan",
                    systemImage: "building.2",
                    description: Text(model.canEdit
                        ? String(localized: "Add a circle by its WCID to begin planning.")
                        : String(localized: "Collaborative circle content will appear here."))
                )
            } else {
                ForEach(model.circles) { circle in
                    NavigationLink {
                        SharedPlanCircleEditorScreen(
                            model: model,
                            store: store,
                            circle: circle.key,
                            currentUserID: currentUserID
                        )
                    } label: {
                        SharedPlanCircleSummaryRow(
                            circle: circle,
                            conflictCount: conflictCount(for: circle.key)
                        )
                    }
                    .accessibilityIdentifier(
                        SharedPlanEditorAccessibilityID.circle(circle.key)
                    )
                }
            }
        } header: {
            Text("Circles and purchases")
        }
    }

    private var progressSection: some View {
        let progress = model.progress
        return Section("Plan progress") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("Wanted")
                    Text(progress.wanted, format: .number)
                    Text("Assigned")
                    Text(progress.assigned, format: .number)
                }
                GridRow {
                    Text("Covered")
                    Text(progress.covered, format: .number)
                    Text("Fulfilled")
                    Text(progress.fulfilled, format: .number)
                }
                GridRow {
                    Text("Outstanding")
                    Text(progress.outstanding, format: .number)
                    Text("Conflicts")
                    Text(progress.conflicted, format: .number)
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)

            if progress.overAssigned > 0 {
                Label(
                    "Over-assigned by \(progress.overAssigned)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            if progress.terminalOutcomeCircles > 0 {
                Label(
                    "\(progress.terminalOutcomeCircles) circles have a member-entered outcome",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func conflictCount(for key: SharedPlanCircleKey) -> Int {
        model.conflicts.filter {
            $0.path.count >= 2
                && $0.path[0] == "circles"
                && $0.path[1] == String(key.wcID)
        }.count
    }

    private func statusColor(_ tone: SharedPlanEditorStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .progress: .accentColor
        case .success: .green
        case .warning: .orange
        }
    }
}

private struct SharedPlanCircleSummaryRow: View {
    let circle: SharedPlanCircleContent
    let conflictCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("WCID \(circle.key.wcID)")
                    .font(.headline)
                Spacer(minLength: 8)
                presenceLabel
            }
            HStack(spacing: 12) {
                Label("\(circle.needs.count) needs", systemImage: "bag")
                if conflictCount > 0 {
                    Label("\(conflictCount) conflicts", systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !circle.memo.isEmpty {
                Text(circle.memo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var presenceLabel: some View {
        switch circle.presence {
        case .present:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .removed:
            Label("Removed", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .conflicted:
            Label("Conflicted", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct SharedPlanConflictRow: View {
    let conflict: SharedPlanDocumentConflict
    let currentUserID: String?
    let members: [String: SharedPlanMember]
    let canResolve: Bool
    let onSelectCandidate: (SharedPlanConflictCandidate) -> Void
    let onSelectParent: (UUID) -> Void

    var body: some View {
        let presentation = SharedPlanConflictPresentation(conflict: conflict)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.path)
                    .font(.subheadline.weight(.medium))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if conflict.kind == .parent {
                ForEach(conflict.parentRootOperationIDs, id: \.self) { parentID in
                    Button {
                        onSelectParent(parentID)
                    } label: {
                        SharedPlanConflictChoiceLabel(
                            candidate: parentCandidate(parentID),
                            fallbackTitle: String(localized: "Creation choice"),
                            currentUserID: currentUserID,
                            members: members
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canResolve)
                }
            } else {
                ForEach(conflict.candidates) { candidate in
                    Button {
                        onSelectCandidate(candidate)
                    } label: {
                        SharedPlanConflictChoiceLabel(
                            candidate: candidate,
                            fallbackTitle: String(localized: "Value choice"),
                            currentUserID: currentUserID,
                            members: members
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canResolve)
                }
            }

            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Path", value: conflict.path.joined(separator: " › "))
                    ForEach(conflict.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.value.sharedPlanDisplayText(
                                members: members,
                                currentUserID: currentUserID
                            ))
                                .font(.caption.weight(.semibold))
                            Text("Operation \(candidate.operationID.uuidString.lowercased())")
                            Text("Change \(candidate.changeHash)")
                            Text("Actor \(candidate.actorUserID)")
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(.vertical, 5)
        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.conflict(conflict.id))
    }

    private func parentCandidate(_ parentID: UUID) -> SharedPlanConflictCandidate? {
        conflict.candidates.first {
            $0.rootOperationID == parentID || $0.operationID == parentID
        }
    }
}

private struct SharedPlanConflictChoiceLabel: View {
    let candidate: SharedPlanConflictCandidate?
    let fallbackTitle: String
    let currentUserID: String?
    let members: [String: SharedPlanMember]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate?.value.sharedPlanDisplayText(
                    members: members,
                    currentUserID: currentUserID
                ) ?? fallbackTitle)
                    .font(.body.weight(.medium))
                Text(actorLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private var actorLabel: String {
        guard let candidate else { return String(localized: "Creation retained in plan history") }
        if candidate.actorUserID == currentUserID {
            return String(localized: "Your change")
        }
        if let member = members[candidate.actorUserID] {
            return String(localized: "Change by \(SharedPlanMemberPresentation.label(member, currentUserID: currentUserID))")
        }
        return String(localized: "Change by member")
    }
}

private struct SharedPlanAddCircleSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let comiketNo: Int?
    @Binding var presentedSheet: SharedPlanEditorSheet?
    @State private var rawWCID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Circle") {
                    LabeledContent("Comiket", value: comiketNo.map { "C\($0)" } ?? "—")
                    TextField("WCID", text: $rawWCID)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                }
                Section {
                    Text("WCID is the stable circle identifier for this Comiket. Existing retained content is restored when a removed circle is reactivated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addCircle() }
                        .disabled(circle == nil || model.isPerformingMutation)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var circle: SharedPlanCircleKey? {
        guard let comiketNo, let wcID = Int(rawWCID) else { return nil }
        return SharedPlanCircleKey(comiketNo: comiketNo, wcID: wcID)
    }

    private func addCircle() {
        guard let circle else { return }
        Task {
            await model.setCirclePresence(.active, circle: circle, using: store)
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }
}

private struct SharedPlanParentResolutionSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let conflictID: String
    let parentID: UUID
    let currentUserID: String?
    @Binding var presentedSheet: SharedPlanEditorSheet?

    var body: some View {
        NavigationStack {
            Form {
                if let draft = matchingDraft {
                    Section {
                        LabeledContent("Selected original item") {
                            Text(parentLabel(draft))
                                .multilineTextAlignment(.trailing)
                        }
                    } footer: {
                        Text("The selected parent takes precedence. Every overlapping descendant below still requires an explicit value.")
                    }

                    Section("Keep this item") {
                        Picker(
                            "Presence after resolution",
                            selection: Binding(
                                get: { draft.state },
                                set: { value in
                                    if let value { model.selectParentPresence(value) }
                                }
                            )
                        ) {
                            Text("Active").tag(SharedPlanPresenceState?.some(.active))
                            Text("Removed").tag(SharedPlanPresenceState?.some(.removed))
                        }
                        .pickerStyle(.segmented)
                    }

                    ForEach(draft.inventory.requiredNestedConflicts) { conflict in
                        Section {
                            ForEach(conflict.candidates) { candidate in
                                Button {
                                    model.selectNestedCandidate(
                                        conflictID: conflict.id,
                                        changeHash: candidate.changeHash
                                    )
                                } label: {
                                    HStack {
                                        SharedPlanConflictChoiceLabel(
                                            candidate: candidate,
                                            fallbackTitle: String(localized: "Value choice"),
                                            currentUserID: currentUserID,
                                            members: model.activeMembersByUserID
                                        )
                                        if draft.selectedChangeHashes[conflict.id]
                                            == candidate.changeHash
                                        {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.accent)
                                                .accessibilityLabel("Selected")
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        } header: {
                            Text(SharedPlanConflictPresentation.pathLabel(conflict.path))
                        } footer: {
                            Text("Choose exactly one retained candidate for this field.")
                        }
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading every required conflict…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Resolve original item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelParentResolution()
                        presentedSheet = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resolve") { resolve() }
                        .disabled(matchingDraft?.isComplete != true || model.isPerformingMutation)
                }
            }
            .interactiveDismissDisabled(model.isPerformingMutation)
        }
        .task(id: parentID) {
            await model.prepareParentResolution(
                conflictID: conflictID,
                selectedParentOperationID: parentID,
                using: store
            )
        }
        .onDisappear {
            model.cancelParentResolutionRequest(
                conflictID: conflictID,
                parentID: parentID
            )
        }
    }

    private var matchingDraft: SharedPlanParentResolutionDraft? {
        guard let draft = model.parentResolutionDraft,
              draft.conflictID == conflictID,
              draft.inventory.selectedParentOperationID == parentID
        else { return nil }
        return draft
    }

    private func parentLabel(_ draft: SharedPlanParentResolutionDraft) -> String {
        let candidate = draft.inventory.parentConflict.candidates.first {
            $0.rootOperationID == parentID || $0.operationID == parentID
        }
        return candidate?.value.sharedPlanDisplayText(
            members: model.activeMembersByUserID,
            currentUserID: currentUserID
        )
            ?? String(localized: "Creation retained in plan history")
    }

    private func resolve() {
        Task {
            await model.submitParentResolution(using: store)
            if model.parentResolutionDraft == nil { presentedSheet = nil }
        }
    }
}

private enum SharedPlanCircleEditorSheet: Identifiable {
    case createNeed
    case editQuantity(SharedPlanQuantityEdit)
    case editCommunication(field: String?, value: SharedPlanJSONValue?)

    var id: String {
        switch self {
        case .createNeed: "create-need"
        case .editQuantity(let edit): "quantity:\(edit.id)"
        case .editCommunication(let field, _): "communication:\(field ?? "new")"
        }
    }
}

private enum SharedPlanCircleEditorConfirmation: Identifiable {
    case removeCircle
    case deleteNeed(UUID)

    var id: String {
        switch self {
        case .removeCircle: "remove-circle"
        case .deleteNeed(let id): "delete-need:\(id.uuidString.lowercased())"
        }
    }
}

private struct SharedPlanCircleEditorScreen: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let currentUserID: String?
    @State private var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var confirmation: SharedPlanCircleEditorConfirmation?
    @State private var externalStates: [SharedPlanExternalCircleState] = []
    @State private var externalStateIssue: String?

    var body: some View {
        List {
            if let content {
                presenceSection(content)
                memoSection
                needsSection(content)
                memberOutcomeSection(content)
                externalAvailabilitySection
                communicationSection(content)
            } else {
                ContentUnavailableView(
                    "Circle content is unavailable",
                    systemImage: "building.2.crop.circle",
                    description: Text("The circle may have been removed remotely. Any unsaved memo draft remains available from the plan recovery screen.")
                )
            }
        }
        .navigationTitle("WCID \(circle.wcID)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .createNeed:
                SharedPlanCreateNeedSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    currentUserID: currentUserID,
                    presentedSheet: $presentedSheet
                )
            case .editQuantity(let edit):
                SharedPlanQuantityEditorSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    edit: edit,
                    currentUserID: currentUserID,
                    presentedSheet: $presentedSheet
                )
            case .editCommunication(let field, let value):
                SharedPlanCommunicationEditorSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    existingField: field,
                    existingValue: value,
                    presentedSheet: $presentedSheet
                )
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation
        ) { item in
            switch item {
            case .removeCircle:
                Button("Remove circle", role: .destructive) {
                    confirmation = nil
                    Task {
                        await model.setCirclePresence(.removed, circle: circle, using: store)
                    }
                }
            case .deleteNeed(let needID):
                Button("Remove purchase need", role: .destructive) {
                    confirmation = nil
                    Task { await model.deleteNeed(needID, circle: circle, using: store) }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            switch item {
            case .removeCircle:
                Text("The circle is hidden by a collaborative tombstone. Its memo and purchase history remain available for conflict resolution and later reactivation.")
            case .deleteNeed:
                Text("The purchase need is hidden, but retained quantities and allocations remain available if a concurrent edit requires resolution.")
            }
        }
        .task(id: circle.id) {
            do {
                try await Task.sleep(for: .seconds(31_536_000))
            } catch {
                // Navigation cancellation is the structured flush signal.
            }
            await model.flushMemo(circle: circle, using: store)
        }
        .task(id: "external:\(circle.id)") {
            await loadExternalStates()
        }
    }

    private var content: SharedPlanCircleContent? {
        model.circleContent(for: circle)
    }

    private func presenceSection(_ content: SharedPlanCircleContent) -> some View {
        Section {
            LabeledContent("Status") {
                switch content.presence {
                case .present:
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .removed:
                    Label("Removed", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                case .conflicted:
                    Label("Needs conflict resolution", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if model.canEdit {
                switch content.presence {
                case .present:
                    Button("Remove circle from plan", role: .destructive) {
                        confirmation = .removeCircle
                    }
                    .disabled(model.isPerformingMutation)
                case .removed:
                    Button {
                        Task {
                            await model.setCirclePresence(.active, circle: circle, using: store)
                        }
                    } label: {
                        Label("Reactivate circle", systemImage: "arrow.uturn.forward.circle")
                    }
                    .disabled(model.isPerformingMutation)
                case .conflicted:
                    Text("Use the plan conflict section to choose active or removed explicitly.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Circle")
        }
    }

    private var memoSection: some View {
        Section {
            TextEditor(text: memoBinding)
                .frame(minHeight: 120)
                .disabled(!model.canEdit)
                .accessibilityLabel("Collaborative memo")
                .accessibilityHint("Changes are combined into one saved edit after a short pause.")
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.memo(circle))

            if model.hasMemoDraft(for: circle) {
                Label(
                    model.isMemoDraftDurablyRetained(for: circle)
                        ? String(localized: "Memo edit retained on this device")
                        : String(localized: "Saving memo edit on this device…"),
                    systemImage: model.isMemoDraftDurablyRetained(for: circle)
                        ? "checkmark.circle"
                        : "clock"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Memo")
        } footer: {
            Text("Plain text only. Unicode characters are edited by scalar position and saved after a short idle pause or when you leave this screen.")
        }
    }

    private func needsSection(_ content: SharedPlanCircleContent) -> some View {
        Section {
            if content.needs.isEmpty {
                Text("No purchase needs")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.needs) { need in
                    SharedPlanNeedEditorRow(
                        need: need,
                        currentUserID: currentUserID,
                        members: model.members,
                        canEdit: model.canEdit && !model.isPerformingMutation,
                        onEditWanted: {
                            presentedSheet = .editQuantity(.wanted(need))
                        },
                        onEditAllocation: { buyerUserID in
                            presentedSheet = .editQuantity(.allocation(
                                need,
                                buyerUserID: buyerUserID
                            ))
                        },
                        onAddAllocation: {
                            guard let buyer = model.activeMembers.first(where: {
                                $0.userID == currentUserID
                            }) ?? model.activeMembers.first else { return }
                            presentedSheet = .editQuantity(.allocation(
                                need,
                                buyerUserID: buyer.userID
                            ))
                        },
                        onEditFulfilled: {
                            presentedSheet = .editQuantity(.fulfilled(need))
                        },
                        onDelete: { confirmation = .deleteNeed(need.id) }
                    )
                }
            }

            if model.canEdit {
                Button {
                    presentedSheet = .createNeed
                } label: {
                    Label("Add purchase need", systemImage: "plus")
                }
                .disabled(currentUserID == nil || model.isPerformingMutation)
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.addNeed(circle))
            }
        } header: {
            Text("Purchases")
        } footer: {
            if model.canEdit, currentUserID == nil {
                Text("Reload your verified profile before creating or assigning a purchase need.")
            } else {
                Text("Wanted, assigned, and fulfilled quantities are saved as separate collaborative edits.")
            }
        }
    }

    private func communicationSection(_ content: SharedPlanCircleContent) -> some View {
        Section {
            let editableFields = content.communicationState.keys.filter {
                $0 != SharedPlanMemberOutcome.communicationField
            }.sorted()
            if editableFields.isEmpty {
                Text("No communication fields")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(editableFields, id: \.self) { field in
                    Button {
                        presentedSheet = .editCommunication(
                            field: field,
                            value: content.communicationState[field]
                        )
                    } label: {
                        LabeledContent(field) {
                            Text(content.communicationState[field]?.sharedPlanDisplayText ?? "—")
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .disabled(!model.canEdit || model.isPerformingMutation)
                }
            }

            if model.canEdit {
                Button {
                    presentedSheet = .editCommunication(field: nil, value: nil)
                } label: {
                    Label("Add communication field", systemImage: "plus")
                }
                .disabled(model.isPerformingMutation)
            }
        } header: {
            Text("Communication")
        } footer: {
            Text("Use short typed fields such as status, meeting place, or whether contact is complete.")
        }
    }

    private func memberOutcomeSection(_ content: SharedPlanCircleContent) -> some View {
        Section {
            LabeledContent("Member-entered outcome") {
                Text(SharedPlanMemberOutcome.value(in: content)?.title ?? String(localized: "Not set"))
            }
            if model.canEdit {
                Menu("Record outcome") {
                    ForEach(SharedPlanMemberOutcome.allCases) { outcome in
                        Button(outcome.title) {
                            Task {
                                await model.setMemberOutcome(
                                    outcome,
                                    circle: circle,
                                    using: store
                                )
                            }
                        }
                    }
                    if SharedPlanMemberOutcome.value(in: content) != nil {
                        Button("Clear outcome", role: .destructive) {
                            Task {
                                await model.setMemberOutcome(
                                    nil,
                                    circle: circle,
                                    using: store
                                )
                            }
                        }
                    }
                }
                .disabled(model.isPerformingMutation)
            }
        } header: {
            Text("Plan outcome")
        } footer: {
            Text("This is a member-entered plan decision. Live external reports below remain separate and never change it automatically.")
        }
    }

    @ViewBuilder
    private var externalAvailabilitySection: some View {
        Section {
            if externalStates.isEmpty {
                Text(externalStateIssue ?? String(localized: "No live external report"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(externalStates) { state in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(state.title, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                        HStack(spacing: 5) {
                            Text("Reported by \(state.sourceName)")
                            Text("·")
                            Text(state.occurredAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let sourceURL = state.sourceURL {
                            Link("View source", destination: sourceURL)
                                .font(.caption)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Live external reports")
        } footer: {
            Text("External availability is source-attributed information, not a Shared Plan outcome.")
        }
    }

    private func loadExternalStates() async {
        do {
            externalStates = try await CominaviRealtimeStore.shared.sharedPlanExternalStates(
                eventNumber: circle.comiketNo,
                publicCircleID: circle.wcID
            )
            externalStateIssue = nil
        } catch {
            externalStateIssue = String(localized: "Live external reports are temporarily unavailable.")
        }
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { model.memoText(for: circle) },
            set: { value in model.stageMemo(value, circle: circle, using: store) }
        )
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .removeCircle: String(localized: "Remove this circle from the plan?")
        case .deleteNeed: String(localized: "Remove this purchase need?")
        case nil: String(localized: "Confirm change")
        }
    }
}

private struct SharedPlanNeedEditorRow: View {
    let need: SharedPlanPurchaseNeed
    let currentUserID: String?
    let members: [SharedPlanMember]
    let canEdit: Bool
    let onEditWanted: () -> Void
    let onEditAllocation: (String) -> Void
    let onAddAllocation: () -> Void
    let onEditFulfilled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(requesterLabel)
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(need.fulfilledQuantity)/\(need.wantedQuantity) fulfilled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Wanted")
                    Text(need.wantedQuantity, format: .number)
                }
                GridRow {
                    Text("Fulfilled")
                    Text(need.fulfilledQuantity, format: .number)
                }
                GridRow {
                    Text("Assigned")
                    Text(totalAssigned, format: .number)
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Buyer allocations")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(allocationRows, id: \.userID) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                            if row.member == nil || row.member?.membershipStatus == .removed {
                                Text("No longer an active member")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(row.quantity, format: .number)
                            .monospacedDigit()
                        if canEdit, row.member?.membershipStatus == .active {
                            Button("Edit") { onEditAllocation(row.userID) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.callout)
                }
                allocationBalance
            }

            if canEdit {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        quantityButtons
                    }
                    VStack(alignment: .leading) {
                        quantityButtons
                    }
                }
                Button("Remove need", role: .destructive, action: onDelete)
                    .font(.callout)
            }
        }
        .padding(.vertical, 5)
        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.need(need.id))
    }

    @ViewBuilder
    private var quantityButtons: some View {
        Button("Wanted", action: onEditWanted)
            .buttonStyle(.bordered)
        Button("Assign buyer", action: onAddAllocation)
            .buttonStyle(.bordered)
            .disabled(activeMembers.isEmpty)
        Button("Fulfilled", action: onEditFulfilled)
            .buttonStyle(.bordered)
    }

    private var requesterLabel: String {
        if let member = membersByUserID[need.requesterUserID] {
            return need.requesterUserID == currentUserID
                ? String(localized: "Your request")
                : String(localized: "Request by \(member.displayName)")
        }
        return String(localized: "Request by former member")
    }

    private var membersByUserID: [String: SharedPlanMember] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.userID, $0) })
    }

    private var activeMembers: [SharedPlanMember] {
        members.filter { $0.membershipStatus == .active }
    }

    private var totalAssigned: Int {
        need.buyerAllocations.values.reduce(0, +)
    }

    @ViewBuilder
    private var allocationBalance: some View {
        let remaining = need.wantedQuantity - totalAssigned
        if remaining >= 0 {
            Label("\(remaining) still unassigned", systemImage: "person.badge.clock")
                .foregroundStyle(remaining == 0 ? Color.green : Color.secondary)
        } else {
            Label("Over-assigned by \(-remaining)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fontWeight(.semibold)
        }
    }

    private var allocationRows: [AllocationRow] {
        let active = activeMembers.map { member in
            AllocationRow(
                userID: member.userID,
                label: SharedPlanMemberPresentation.label(
                    member,
                    currentUserID: currentUserID
                ),
                quantity: need.buyerAllocations[member.userID] ?? 0,
                member: member
            )
        }
        let activeIDs = Set(active.map(\.userID))
        let retained = need.buyerAllocations
            .filter { !activeIDs.contains($0.key) && $0.value != 0 }
            .map { userID, quantity in
                let member = membersByUserID[userID]
                return AllocationRow(
                    userID: userID,
                    label: member?.displayName ?? String(localized: "Former member"),
                    quantity: quantity,
                    member: member
                )
            }
        return (active + retained).sorted {
            if $0.member?.membershipStatus != $1.member?.membershipStatus {
                return $0.member?.membershipStatus == .active
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private struct AllocationRow {
        let userID: String
        let label: String
        let quantity: Int
        let member: SharedPlanMember?
    }
}

private struct SharedPlanCreateNeedSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let currentUserID: String?
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var wantedQuantity = 1

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase need") {
                    Stepper(
                        "Wanted quantity: \(wantedQuantity)",
                        value: $wantedQuantity,
                        in: 1...SharedPlanAutomergeDocument.maximumQuantity
                    )
                    LabeledContent(
                        "Requester",
                        value: currentUserID == nil
                            ? String(localized: "Verified profile required")
                            : String(localized: "You")
                    )
                }
                Section {
                    Text("Buyer allocations and fulfillment start at zero. Add them as separate edits after creating the need.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add purchase need")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }
                        .disabled(currentUserID == nil || model.isPerformingMutation)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard let currentUserID else { return }
        Task {
            await model.createNeed(
                requesterUserID: currentUserID,
                wantedQuantity: wantedQuantity,
                circle: circle,
                using: store
            )
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }
}

private struct SharedPlanQuantityEdit: Identifiable {
    enum Field: String {
        case wanted
        case allocation
        case fulfilled
    }

    let field: Field
    let needID: UUID
    let initialValue: Int
    let buyerUserID: String?

    var id: String {
        "\(needID.uuidString.lowercased()):\(field.rawValue):\(buyerUserID ?? "-")"
    }

    static func wanted(_ need: SharedPlanPurchaseNeed) -> SharedPlanQuantityEdit {
        SharedPlanQuantityEdit(
            field: .wanted,
            needID: need.id,
            initialValue: need.wantedQuantity,
            buyerUserID: nil
        )
    }

    static func allocation(
        _ need: SharedPlanPurchaseNeed,
        buyerUserID: String
    ) -> SharedPlanQuantityEdit {
        SharedPlanQuantityEdit(
            field: .allocation,
            needID: need.id,
            initialValue: need.buyerAllocations[buyerUserID] ?? 0,
            buyerUserID: buyerUserID
        )
    }

    static func fulfilled(_ need: SharedPlanPurchaseNeed) -> SharedPlanQuantityEdit {
        SharedPlanQuantityEdit(
            field: .fulfilled,
            needID: need.id,
            initialValue: need.fulfilledQuantity,
            buyerUserID: nil
        )
    }
}

private struct SharedPlanQuantityEditorSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let edit: SharedPlanQuantityEdit
    let currentUserID: String?
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var quantity: Int
    @State private var selectedBuyerUserID: String?

    init(
        model: SharedPlanEditorModel,
        store: SharedPlanStore,
        circle: SharedPlanCircleKey,
        edit: SharedPlanQuantityEdit,
        currentUserID: String?,
        presentedSheet: Binding<SharedPlanCircleEditorSheet?>
    ) {
        self.model = model
        self.store = store
        self.circle = circle
        self.edit = edit
        self.currentUserID = currentUserID
        _presentedSheet = presentedSheet
        _quantity = State(initialValue: edit.initialValue)
        _selectedBuyerUserID = State(initialValue: edit.buyerUserID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    if edit.field == .allocation {
                        Picker("Buyer", selection: $selectedBuyerUserID) {
                            ForEach(model.members) { member in
                                Text(SharedPlanMemberPresentation.label(
                                    member,
                                    currentUserID: currentUserID
                                ))
                                .tag(String?.some(member.userID))
                                .disabled(member.membershipStatus != .active)
                            }
                        }
                        .onChange(of: selectedBuyerUserID) { _, buyerUserID in
                            guard let buyerUserID else { return }
                            quantity = currentNeed?.buyerAllocations[buyerUserID] ?? 0
                        }
                    }
                    Stepper(
                        "Quantity: \(quantity)",
                        value: $quantity,
                        in: range
                    )
                    TextField("Quantity", value: $quantity, format: .number)
                        .keyboardType(.numberPad)
                }
                Section {
                    Text(helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            !range.contains(quantity)
                                || model.isPerformingMutation
                                || (edit.field == .allocation && !selectedBuyerIsActive)
                        )
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var range: ClosedRange<Int> {
        switch edit.field {
        case .wanted: 1...SharedPlanAutomergeDocument.maximumQuantity
        case .allocation, .fulfilled: 0...SharedPlanAutomergeDocument.maximumQuantity
        }
    }

    private var title: String {
        switch edit.field {
        case .wanted: String(localized: "Wanted quantity")
        case .allocation: String(localized: "Buyer allocation")
        case .fulfilled: String(localized: "Fulfilled quantity")
        }
    }

    private var helpText: String {
        switch edit.field {
        case .wanted:
            String(localized: "How many items the requester wants in total.")
        case .allocation:
            String(localized: "Assign part of this request to any active plan member. Other allocations remain unchanged.")
        case .fulfilled:
            String(localized: "How many items have actually been purchased or otherwise fulfilled.")
        }
    }

    private func save() {
        Task {
            switch edit.field {
            case .wanted:
                await model.setWantedQuantity(
                    quantity,
                    needID: edit.needID,
                    circle: circle,
                    using: store
                )
            case .allocation:
                guard let buyerUserID = selectedBuyerUserID,
                      model.member(userID: buyerUserID)?.membershipStatus == .active
                else {
                    model.reportStaleAllocationMember()
                    return
                }
                await model.setBuyerAllocation(
                    quantity,
                    buyerUserID: buyerUserID,
                    needID: edit.needID,
                    circle: circle,
                    using: store
                )
            case .fulfilled:
                await model.setFulfilledQuantity(
                    quantity,
                    needID: edit.needID,
                    circle: circle,
                    using: store
                )
            }
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }

    private var currentNeed: SharedPlanPurchaseNeed? {
        model.circleContent(for: circle)?.needs.first { $0.id == edit.needID }
    }

    private var selectedBuyerIsActive: Bool {
        guard edit.field == .allocation else { return true }
        guard let selectedBuyerUserID else { return false }
        return model.member(userID: selectedBuyerUserID)?.membershipStatus == .active
    }
}

private enum SharedPlanCommunicationValueKind: String, CaseIterable, Identifiable {
    case text
    case number
    case flag
    case clear

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .flag: "Yes or no"
        case .clear: "Not set"
        }
    }
}

private struct SharedPlanCommunicationEditorSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let existingField: String?
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var field: String
    @State private var kind: SharedPlanCommunicationValueKind
    @State private var textValue: String
    @State private var integerValue: Int
    @State private var booleanValue: Bool

    init(
        model: SharedPlanEditorModel,
        store: SharedPlanStore,
        circle: SharedPlanCircleKey,
        existingField: String?,
        existingValue: SharedPlanJSONValue?,
        presentedSheet: Binding<SharedPlanCircleEditorSheet?>
    ) {
        self.model = model
        self.store = store
        self.circle = circle
        self.existingField = existingField
        _presentedSheet = presentedSheet
        _field = State(initialValue: existingField ?? "status")
        switch existingValue {
        case .string(let value):
            _kind = State(initialValue: .text)
            _textValue = State(initialValue: value)
            _integerValue = State(initialValue: 0)
            _booleanValue = State(initialValue: false)
        case .integer(let value):
            _kind = State(initialValue: .number)
            _textValue = State(initialValue: "")
            _integerValue = State(initialValue: Int(clamping: value))
            _booleanValue = State(initialValue: false)
        case .boolean(let value):
            _kind = State(initialValue: .flag)
            _textValue = State(initialValue: "")
            _integerValue = State(initialValue: 0)
            _booleanValue = State(initialValue: value)
        case .null:
            _kind = State(initialValue: .clear)
            _textValue = State(initialValue: "")
            _integerValue = State(initialValue: 0)
            _booleanValue = State(initialValue: false)
        case .array, .object:
            _kind = State(initialValue: .text)
            _textValue = State(initialValue: "")
            _integerValue = State(initialValue: 0)
            _booleanValue = State(initialValue: false)
        case nil:
            _kind = State(initialValue: .text)
            _textValue = State(initialValue: "")
            _integerValue = State(initialValue: 0)
            _booleanValue = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Field") {
                    TextField("Field name", text: $field)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(existingField != nil)
                    if !fieldIsValid {
                        Text("Use 1–64 characters, beginning with a lowercase letter. Letters, numbers, underscore, period, and hyphen are allowed.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Value") {
                    Picker("Value type", selection: $kind) {
                        ForEach(SharedPlanCommunicationValueKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    switch kind {
                    case .text:
                        TextField("Value", text: $textValue, axis: .vertical)
                            .lineLimit(1...4)
                    case .number:
                        TextField("Value", value: $integerValue, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                    case .flag:
                        Toggle("Yes", isOn: $booleanValue)
                    case .clear:
                        Text("The field remains in collaborative history but has no current value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existingField == nil
                ? String(localized: "Add communication field")
                : String(localized: "Edit communication field"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || model.isPerformingMutation)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var fieldIsValid: Bool {
        let scalars = Array(field.unicodeScalars)
        guard (1...64).contains(scalars.count),
              let first = scalars.first,
              (97...122).contains(first.value)
        else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            let value = scalar.value
            return (97...122).contains(value)
                || (65...90).contains(value)
                || (48...57).contains(value)
                || value == 95 || value == 46 || value == 45
        }
    }

    private var canSave: Bool {
        guard fieldIsValid else { return false }
        if kind == .text { return textValue.utf8.count <= 4_096 }
        return true
    }

    private var value: SharedPlanJSONValue {
        switch kind {
        case .text: .string(textValue)
        case .number: .integer(Int64(integerValue))
        case .flag: .boolean(booleanValue)
        case .clear: .null
        }
    }

    private func save() {
        guard canSave else { return }
        Task {
            await model.setCommunication(
                value,
                field: field,
                circle: circle,
                using: store
            )
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }
}
