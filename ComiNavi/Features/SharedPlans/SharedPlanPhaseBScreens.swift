import SwiftUI

enum SharedPlanEditorAccessibilityID {
    static let screen = "shared-plan-editor"
    static let syncStatus = "shared-plan-editor-sync-status"
    static let readOnly = "shared-plan-editor-read-only"
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

    static func needProgress(_ needID: UUID) -> String {
        "shared-plan-editor-need-progress-\(needID.uuidString.lowercased())"
    }

    static func needProgressPreview(_ needID: UUID) -> String {
        "shared-plan-editor-need-progress-preview-\(needID.uuidString.lowercased())"
    }

    static func conflict(_ conflictID: String) -> String {
        "shared-plan-editor-conflict-\(conflictID)"
    }
}

struct SharedPlanPurchaseProgressPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case requested
        case partiallyAssigned
        case assigned
        case partiallyBought
        case bought
        case needsReview
    }

    let requested: Int
    let assigned: Int
    let bought: Int
    let state: State

    init(need: SharedPlanPurchaseNeed, hasConflict: Bool) {
        self.init(
            requested: need.wantedQuantity,
            assigned: need.buyerAllocations.values.reduce(0, +),
            bought: need.fulfilledQuantity,
            hasConflict: hasConflict
        )
    }

    init(requested: Int, assigned: Int, bought: Int, hasConflict: Bool) {
        self.requested = max(requested, 1)
        self.assigned = assigned
        self.bought = bought

        if hasConflict
            || assigned > self.requested
            || bought > self.requested
            || bought > assigned
        {
            state = .needsReview
        } else if bought >= requested {
            state = .bought
        } else if bought > 0 {
            state = .partiallyBought
        } else if assigned >= requested {
            state = .assigned
        } else if assigned > 0 {
            state = .partiallyAssigned
        } else {
            state = .requested
        }
    }

    var assignedFraction: Double {
        min(Double(assigned) / Double(requested), 1)
    }

    var boughtFraction: Double {
        min(Double(bought) / Double(requested), 1)
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
            systemImage = "circle"
            tone = .neutral
        case .connecting:
            title = String(localized: "Connecting to Shared Plan")
            detail = Self.pendingDetail(pendingOperationCount)
            systemImage = "refresh-cw"
            tone = .progress
        case .connected(let mutationsEnabled, let pending):
            title = mutationsEnabled
                ? String(localized: "Shared Plan is connected")
                : String(localized: "Connected in read-only mode")
            detail = Self.pendingDetail(pending)
            systemImage = "circle"
            tone = mutationsEnabled ? .progress : .neutral
        case .synchronized(let mutationsEnabled, let pending):
            title = mutationsEnabled
                ? String(localized: "Shared Plan is up to date")
                : String(localized: "Shared Plan is up to date and read-only")
            detail = Self.pendingDetail(pending)
            systemImage = pending == 0 ? "circle-check-big" : "refresh-cw"
            tone = pending == 0 ? .success : .progress
        case .reconnecting:
            title = String(localized: "Reconnecting to Shared Plan")
            detail = Self.pendingDetail(pendingOperationCount)
            systemImage = "refresh-cw"
            tone = .warning
        case .quarantined:
            title = String(localized: "Sync is paused for review")
            detail = String(localized: "Saved content remains on this device until you choose a recovery action.")
            systemImage = "triangle-alert"
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
            detail = String(localized: "You can view this plan now. Editing will be available in a later update.")
            systemImage = "circle"
        case .archived:
            title = String(localized: "This plan is archived")
            detail = String(localized: "Reopen the plan before changing circles or purchases.")
            systemImage = "database"
        case .insufficientRole:
            title = String(localized: "You have view-only access")
            detail = String(localized: "An owner or editor can change this plan.")
            systemImage = "eye"
        case .waitingForWritableSync:
            title = String(localized: "Waiting for writable sync")
            detail = String(localized: "Keep this screen open while ComiNavi reconnects. No local edit will be accepted until authority is confirmed.")
            systemImage = "calendar-clock"
        case .localLimit(let limit):
            switch limit {
            case .syncBacklog(let maximum, let pending):
                title = String(localized: "Sync before editing again")
                detail = String(localized: "\(pending) changes are waiting to upload. Let them finish before editing again. The limit is \(maximum).")
                systemImage = "refresh-cw"
            case .compactionRequired:
                title = String(localized: "This plan needs compact recovery")
                detail = String(localized: "This plan has too many saved changes. Download a copy, then repair or reset the plan.")
                systemImage = "triangle-alert"
            }
        case .quarantine(let issue):
            title = Self.quarantineTitle(issue)
            detail = Self.quarantineDetail(issue)
            systemImage = "triangle-alert"
        }
    }

    private static func quarantineTitle(_ issue: SharedPlanSyncIssue) -> String {
        switch issue {
        case .membershipRevoked:
            String(localized: "Plan access was removed")
        case .roleChanged:
            String(localized: "Your plan role changed")
        case .conflict:
            String(localized: "This plan needs review")
        case .unavailable:
            String(localized: "Saved plan data cannot be opened")
        case .rejectedLocalChanges:
            String(localized: "Some saved changes need recovery")
        case .compactionRequired, .serverCompactionRequired:
            String(localized: "The server requires plan recovery")
        case .backlogLimit:
            String(localized: "The server rejected an oversized sync backlog")
        }
    }

    private static func quarantineDetail(_ issue: SharedPlanSyncIssue) -> String {
        switch issue {
        case .membershipRevoked:
            String(localized: "Your unsent changes are saved so you can download a copy.")
        case .roleChanged:
            String(localized: "Reload the plan to confirm the current role before editing again.")
        case .conflict:
            String(localized: "Your changes are saved. Review the choices before continuing.")
        case .unavailable:
            String(localized: "This saved plan cannot be opened. Download a copy or reset it.")
        case .rejectedLocalChanges(let supportCode):
            if let supportCode {
                String(localized: "Some changes could not be saved online. Download a copy, then reset from the latest plan. Support code: \(supportCode)")
            } else {
                String(localized: "Some changes could not be saved online. Download a copy, then reset from the latest plan.")
            }
        case .compactionRequired, .serverCompactionRequired:
            String(localized: "Download a copy, then choose how to repair or reset this plan.")
        case .backlogLimit(let maximum, let received):
            String(localized: "There are \(received) unsent changes, above the \(maximum)-change upload limit. Download a copy, then repair or reset the plan.")
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
            detail = String(localized: "Choose which version to keep, then review each highlighted detail.")
        case .scalar:
            title = String(localized: "Choose one value")
            detail = String(localized: "Two people changed this at the same time. Choose the value the plan should keep.")
        case .removalVersusEdit:
            title = String(localized: "Choose removal or the later edit")
            detail = String(localized: "One person removed this item while another changed it. Choose what the plan should keep.")
        }
    }

    static func pathLabel(_ path: [String]) -> String {
        guard !path.isEmpty else { return String(localized: "Plan content") }
        if let last = path.last {
            switch last {
            case "presence": return String(localized: "Presence")
            case "memo": return String(localized: "Memo")
            case "itemName": return String(localized: "Item name")
            case "unitPrice": return String(localized: "Price")
            case "wantedQuantity": return String(localized: "Requested")
            case "buyerAllocations": return String(localized: "Assigned")
            case "fulfilledQuantity": return String(localized: "Bought")
            case "communicationState": return String(localized: "Plan detail")
            default: break
            }
        }
        if path.count == 2, path.first == "circles" {
            return String(localized: "Circle")
        }
        if path.count >= 4, path[2] == "needs" {
            return String(localized: "Purchase need")
        }
        return String(localized: "Plan detail")
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
            Self.objectSummary(
                values,
                members: members,
                currentUserID: currentUserID,
                depth: depth
            )
        }
    }

    private static func objectSummary(
        _ values: [String: SharedPlanJSONValue],
        members: [String: SharedPlanMember],
        currentUserID: String?,
        depth: Int
    ) -> String {
        if let state = values["state"]?.stringValue {
            return state == SharedPlanPresenceState.active.rawValue
                ? String(localized: "Active")
                : String(localized: "Removed")
        }
        if let itemName = values["itemName"]?.stringValue {
            let wanted = values["wantedQuantity"]?.integerValue.map {
                String(localized: "Quantity \($0)")
            }
            let price = values["unitPrice"]?.integerValue.map {
                Int($0).formatted(.currency(code: "JPY").precision(.fractionLength(0)))
            }
            return ([itemName] + [wanted, price].compactMap { $0 }).joined(separator: " · ")
        }
        let participantValues = values.compactMap { key, value -> String? in
            guard let member = members[key] else { return nil }
            let label = SharedPlanMemberPresentation.label(
                member,
                currentUserID: currentUserID,
                includesRole: false
            )
            let displayValue = value.sharedPlanDisplayText(
                members: members,
                currentUserID: currentUserID,
                depth: depth + 1
            )
            return "\(label): \(displayValue)"
        }
        let detailValues = values.compactMap { key, value -> String? in
            guard members[key] == nil else { return nil }
            let label: String = switch key {
            case "status", "state": String(localized: "Status")
            case "wantedQuantity": String(localized: "Quantity")
            case "fulfilledQuantity": String(localized: "Purchased")
            case "unitPrice": String(localized: "Price")
            default: String(localized: "Details")
            }
            let displayValue = value.sharedPlanDisplayText(
                members: members,
                currentUserID: currentUserID,
                depth: depth + 1
            )
            return "\(label): \(displayValue)"
        }
        let summaryValues = participantValues + detailValues
        return summaryValues.isEmpty
            ? String(localized: "Structured plan details")
            : Self.boundedSummary(summaryValues)
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
    case resolveParent(conflictID: String, parentID: UUID)

    var id: String {
        switch self {
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
    let catalogDataSource: CirclemsDataSource?
    @State private var model: SharedPlanEditorModel
    @State private var presentedSheet: SharedPlanEditorSheet?
    @State private var confirmation: SharedPlanEditorConfirmation?
    @State private var catalogCircles: [SharedPlanCircleKey: CirclemsDataSchema.ComiketCircleWC] = [:]
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: SharedPlanStore,
        planID: String,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        catalogDataSource: CirclemsDataSource? = nil
    ) {
        self.store = store
        self.currentUserID = currentUserID
        self.catalogDataSource = catalogDataSource
        _model = State(initialValue: SharedPlanEditorModel(
            planID: planID,
            features: features
        ))
    }

    var body: some View {
        @Bindable var model = model
        List {
            progressSection
            circleSections
            conflictSection
            readOnlySection
            recoverySection
            memoRecoverySection
            statusSection
        }
        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.screen)
        .navigationTitle(model.plan?.name ?? String(localized: "Plan content"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload(using: store) }
        .task(id: model.planID) {
            await model.run(using: store)
        }
        .task(id: catalogCircleTaskID) {
            await loadCatalogCircles()
        }
        .task(id: scenePhase) {
            guard scenePhase != .active else { return }
            await model.flushAllMemos(using: store)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
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
            "Reset this saved plan?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation
        ) { _ in
            Button("Reset to the latest plan", role: .destructive) {
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
                LucideIcon(presentation.systemImage)
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
                    LucideIcon(presentation.systemImage)
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
                    LucideLabel("Saved recovery copy", icon: "database")
                        .font(.headline)
                    Text("\(recovery.pendingOperationCount) item changes and \(recovery.metadataIntentCount) plan updates are saved on this device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                ShareLink(item: recovery.exportText) {
                    LucideLabel("Download recovery copy", icon: "share")
                }

                if model.features.writesEnabled, model.recoveryRebaseAvailable {
                    Button {
                        Task { await model.rebaseUnsyncedContent(using: store) }
                    } label: {
                        LucideLabel("Repair from latest plan", icon: "git-branch")
                    }
                    .disabled(model.isPerformingMutation)
                    .accessibilityIdentifier(SharedPlanEditorAccessibilityID.recoveryRebase)
                }

                Button("Reset saved plan", role: .destructive) {
                    confirmation = .discardRecovery
                }
                .disabled(model.isPerformingMutation)
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.recoveryDiscard)
            } header: {
                Text("Recovery")
            } footer: {
                if case .some(.unavailable) = model.syncIssue {
                    Text("This saved plan cannot be opened. Download a copy before resetting it.")
                } else if model.recoveryRebaseAvailable {
                    Text("Repair keeps the changes that can be recovered and starts from the latest shared plan.")
                } else {
                    Text("This plan cannot be repaired automatically. Download a copy before resetting it.")
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
                        Text("Circle memo")
                            .font(.headline)
                        Text(recovery.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ShareLink(item: recovery.exportText) {
                            LucideLabel("Download memo", icon: "share")
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
                LucideLabel("Choices that need your attention", icon: "triangle-alert")
            } footer: {
                Text("Choose the version the plan should keep.")
            }
            .accessibilityIdentifier(SharedPlanEditorAccessibilityID.conflictList)
        }
    }

    @ViewBuilder
    private var circleSections: some View {
        if model.circles.isEmpty {
            Section("Circles and purchases") {
                SharedPlanEmptyCirclesView(canEdit: model.canEdit)
            }
        } else {
            ForEach(model.circles) { circle in
                let identity = circleIdentity(for: circle.key)
                Section {
                    if circle.needs.isEmpty {
                        NavigationLink {
                            SharedPlanCircleEditorScreen(
                                model: model,
                                store: store,
                                circle: circle.key,
                                currentUserID: currentUserID,
                                identity: identity
                            )
                        } label: {
                            SharedPlanEmptyPurchaseSummaryRow(identity: identity)
                        }
                        .accessibilityIdentifier(
                            SharedPlanEditorAccessibilityID.circle(circle.key)
                        )
                    } else {
                        ForEach(circle.needs) { need in
                            NavigationLink {
                                SharedPlanCircleEditorScreen(
                                    model: model,
                                    store: store,
                                    circle: circle.key,
                                    currentUserID: currentUserID,
                                    identity: identity
                                )
                            } label: {
                                SharedPlanPurchaseSummaryRow(
                                    need: need,
                                    circleDisplayName: identity.displayName,
                                    hasConflict: model.conflicts.contains { conflict in
                                        conflict.path.contains(need.id.uuidString.lowercased())
                                    }
                                )
                            }
                            .accessibilityIdentifier(
                                need.id == circle.needs.first?.id
                                    ? SharedPlanEditorAccessibilityID.circle(circle.key)
                                    : SharedPlanEditorAccessibilityID.need(need.id)
                            )
                        }
                    }
                } header: {
                    SharedPlanCircleGroupHeader(
                        identity: identity,
                        conflictCount: conflictCount(for: circle.key)
                    )
                }
            }
        }
    }

    private var catalogCircleTaskID: String {
        let circleIDs = model.circles.map(\.key.id).joined(separator: ",")
        let isReady = catalogDataSource?.readiness == .ready
        return "\(catalogDataSource?.eventID ?? 0):\(isReady):\(circleIDs)"
    }

    private func loadCatalogCircles() async {
        guard let catalogDataSource,
              catalogDataSource.readiness == .ready,
              let catalog = catalogDataSource.comiket,
              model.plan?.comiketNo == catalog.number
        else {
            catalogCircles = [:]
            return
        }

        var loaded: [SharedPlanCircleKey: CirclemsDataSchema.ComiketCircleWC] = [:]
        for content in model.circles {
            guard !Task.isCancelled else { return }
            if let circle = await catalogDataSource.getCircle(publicCircleID: content.key.wcID) {
                loaded[content.key] = circle
            }
        }
        catalogCircles = loaded
    }

    private func circleIdentity(
        for key: SharedPlanCircleKey
    ) -> SharedPlanCircleIdentityPresentation {
        let catalogCircle = catalogCircles[key]
        let blockName = catalogCircle?.blockId.flatMap { blockID in
            catalogDataSource?.comiket.blocks.first(where: {
                $0.externalBlockId == blockID
            })?.name
        }
        return SharedPlanCircleIdentityPresentation(
            circleName: catalogCircle?.circleName,
            penName: catalogCircle?.penName,
            day: catalogCircle?.day,
            blockName: blockName,
            spaceNumber: catalogCircle?.spaceNo,
            spaceNumberSub: catalogCircle?.spaceNoSub
        )
    }

    private var progressSection: some View {
        let progress = model.progress
        return Section("Plan progress") {
            SharedPlanProgressOverview(progress: progress)

            if progress.overAssigned > 0 {
                LucideLabel(
                    verbatim: String(localized: "Over-assigned by \(progress.overAssigned)"),
                    icon: "triangle-alert"
                )
                .foregroundStyle(.orange)
            }
            if progress.conflicted > 0 {
                LucideLabel(
                    verbatim: String(localized: "\(progress.conflicted) choices need attention"),
                    icon: "triangle-alert"
                )
                .foregroundStyle(.orange)
            }
            if progress.terminalOutcomeCircles > 0 {
                Text("\(progress.terminalOutcomeCircles) circles have a recorded result")
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

struct SharedPlanEmptyCirclesView: View {
    let canEdit: Bool

    @ScaledMetric(relativeTo: .title3) private var iconContainerSize = 72.0
    @ScaledMetric(relativeTo: .title3) private var iconSize = 30.0

    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: iconContainerSize, height: iconContainerSize)
                .overlay {
                    LucideIcon("building-2", size: iconSize)
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text("No circles in this plan")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if canEdit {
                    Text("Open a circle from the catalog to add a purchase request to this plan.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Circles and purchase requests will appear here.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 30)
        .background(.background, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shared-plan-empty-circles")
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct SharedPlanProgressOverview: View {
    let progress: SharedPlanProgressSummary

    @ScaledMetric(relativeTo: .body) private var barHeight = 12.0

    var body: some View {
        if progress.wanted == 0 {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No purchase requests yet")
                        .font(.headline)
                    Text("Add a purchase request to start tracking this plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                LucideIcon("shopping-cart")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "\(progress.fulfilledPercentage)%")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("bought")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(progress.outstanding) remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.18))
                        Capsule()
                            .fill(.orange)
                            .frame(width: width * progress.assignedFraction)
                        Capsule()
                            .fill(.green)
                            .frame(width: width * progress.fulfilledFraction)
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .frame(height: barHeight)
                .accessibilityHidden(true)

                HStack(spacing: 8) {
                    SharedPlanProgressMetric(
                        title: String(localized: "Requested"),
                        value: progress.wanted,
                        color: .secondary
                    )
                    SharedPlanProgressMetric(
                        title: String(localized: "Assigned"),
                        value: progress.assigned,
                        color: .orange
                    )
                    SharedPlanProgressMetric(
                        title: String(localized: "Bought"),
                        value: progress.fulfilled,
                        color: .green
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan progress")
            .accessibilityValue(
                "Requested \(progress.wanted), assigned \(progress.assigned), bought \(progress.fulfilled), \(progress.outstanding) remaining"
            )
        }
    }
}

private struct SharedPlanProgressMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value, format: .number)
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SharedPlanCircleGroupHeader: View {
    let identity: SharedPlanCircleIdentityPresentation
    let conflictCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.circleName)
                    .font(.subheadline.weight(.semibold))
                if let penName = identity.penName {
                    Text(penName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if conflictCount > 0 {
                LucideLabel(
                    verbatim: String(localized: "\(conflictCount) choices"),
                    icon: "triangle-alert"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

private struct SharedPlanPurchaseSummaryRow: View {
    let need: SharedPlanPurchaseNeed
    let circleDisplayName: String
    let hasConflict: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayItemName)
                    .font(.headline)
                Spacer(minLength: 8)
                if let unitPrice = need.unitPrice {
                    Text(
                        unitPrice,
                        format: .currency(code: "JPY").precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Text(circleDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SharedPlanPurchaseStageBar(
                progress: SharedPlanPurchaseProgressPresentation(
                    need: need,
                    hasConflict: hasConflict
                ),
                accessibilityIdentifier: SharedPlanEditorAccessibilityID.needProgress(need.id)
            )
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var displayItemName: String {
        let value = need.itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? String(localized: "Purchase item") : value
    }
}

private struct SharedPlanEmptyPurchaseSummaryRow: View {
    let identity: SharedPlanCircleIdentityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No purchase requests yet")
                .font(.headline)
            Text(identity.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
            LucideIcon("circle")
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
            LucideIcon("chevron-right", size: 14)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private var actorLabel: String {
        guard let candidate else { return String(localized: "Saved version") }
        if candidate.actorUserID == currentUserID {
            return String(localized: "Your change")
        }
        if let member = members[candidate.actorUserID] {
            return String(localized: "Change by \(SharedPlanMemberPresentation.label(member, currentUserID: currentUserID))")
        }
        return String(localized: "Change by member")
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
                        Text("Review every highlighted detail before saving this version.")
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
                                            LucideIcon("circle-check-big")
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
                            Text("Choose one version for this detail.")
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
            ?? String(localized: "Saved version")
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
    case editProgress(SharedPlanPurchaseProgressEdit)
    case editAllocation(SharedPlanBuyerAllocationEdit)

    var id: String {
        switch self {
        case .createNeed: "create-need"
        case .editProgress(let edit): "progress:\(edit.id)"
        case .editAllocation(let edit): "allocation:\(edit.id)"
        }
    }
}

private struct SharedPlanCircleEditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let currentUserID: String?
    let identity: SharedPlanCircleIdentityPresentation
    @State private var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var confirmsCircleRemoval = false
    @State private var purchaseNeedPendingRemoval: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let content {
                    needsSection(content)
                    memoSection
                    presenceSection(content)
                } else {
                    LucideContentUnavailableView(
                        "Circle content is unavailable",
                        icon: "building-2",
                        description: Text("This circle may have been removed. Any saved memo can still be downloaded from plan recovery.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .modifier(SharedPlanCirclePurchasesNavigationTitle(identity: identity))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.circleContent(for: circle)?.presence) { _, presence in
            guard presence == .removed else { return }
            dismiss()
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .createNeed:
                SharedPlanCreateNeedSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    currentUserID: currentUserID,
                    identity: identity,
                    presentedSheet: $presentedSheet
                )
            case .editProgress(let edit):
                SharedPlanPurchaseProgressSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    edit: edit,
                    presentedSheet: $presentedSheet
                )
            case .editAllocation(let edit):
                SharedPlanBuyerAllocationSheet(
                    model: model,
                    store: store,
                    circle: circle,
                    edit: edit,
                    currentUserID: currentUserID,
                    presentedSheet: $presentedSheet
                )
            }
        }
        .confirmationDialog(
            "Remove this purchase need?",
            isPresented: Binding(
                get: { purchaseNeedPendingRemoval != nil },
                set: { if !$0 { purchaseNeedPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: purchaseNeedPendingRemoval
        ) { needID in
            Button("Remove purchase need", role: .destructive) {
                purchaseNeedPendingRemoval = nil
                Task { await model.deleteNeed(needID, circle: circle, using: store) }
            }
            Button("Cancel", role: .cancel) { purchaseNeedPendingRemoval = nil }
        } message: { _ in
            Text("This purchase request will be removed. If someone changed it at the same time, you can choose which version to keep.")
        }
        .task(id: circle.id) {
            do {
                try await Task.sleep(for: .seconds(31_536_000))
            } catch {
                // Navigation cancellation is the structured flush signal.
            }
            await model.flushMemo(circle: circle, using: store)
        }
    }

    private var content: SharedPlanCircleContent? {
        model.circleContent(for: circle)
    }

    @ViewBuilder
    private func presenceSection(_ content: SharedPlanCircleContent) -> some View {
        if model.canEdit || content.presence != .present {
            SharedPlanCirclePanel(title: String(localized: "Plan")) {
                switch content.presence {
                case .present:
                    if model.canEdit {
                        Button(role: .destructive) {
                            confirmsCircleRemoval = true
                        } label: {
                            Text("Remove circle from plan")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .disabled(model.isPerformingMutation)
                        .confirmationDialog(
                            "Remove this circle from the plan?",
                            isPresented: $confirmsCircleRemoval,
                            titleVisibility: .visible
                        ) {
                            Button("Remove circle", role: .destructive) {
                                confirmsCircleRemoval = false
                                Task {
                                    await model.setCirclePresence(
                                        .removed,
                                        circle: circle,
                                        using: store
                                    )
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This circle will be removed from the plan. Its notes and purchases remain available if another recent change restores it.")
                        }
                    }
                case .removed:
                    LucideLabel("Removed", icon: "minus")
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await model.setCirclePresence(.active, circle: circle, using: store)
                        }
                    } label: {
                        LucideLabel("Reactivate circle", icon: "rotate-cw")
                    }
                    .disabled(model.isPerformingMutation)
                case .conflicted:
                    LucideLabel("Needs review", icon: "triangle-alert")
                        .foregroundStyle(.orange)
                    if model.canEdit {
                        Text("Choose whether this circle should stay in the plan.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var memoSection: some View {
        SharedPlanCirclePanel(title: String(localized: "Memo")) {
            TextEditor(text: memoBinding)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .background(.background, in: .rect(cornerRadius: 12))
                .disabled(!model.canEdit)
                .accessibilityLabel("Memo")
                .accessibilityHint("Saved after a short pause and when you leave.")
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.memo(circle))

            if model.hasMemoDraft(for: circle) {
                LucideLabel(
                    verbatim: model.isMemoDraftDurablyRetained(for: circle)
                        ? String(localized: "Saved on this device")
                        : String(localized: "Saving…"),
                    icon: model.isMemoDraftDurablyRetained(for: circle)
                        ? "circle-check-big"
                        : "calendar-clock"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func needsSection(_ content: SharedPlanCircleContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Purchases")
                    .font(.title3.weight(.bold))
                Spacer()
                SharedPlanPurchaseStageLegend()
            }

            if content.needs.isEmpty {
                Text("No purchase requests yet")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.background, in: .rect(cornerRadius: 16))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.needs) { need in
                    SharedPlanNeedEditorRow(
                        need: need,
                        circleDisplayName: identity.displayName,
                        currentUserID: currentUserID,
                        members: model.members,
                        hasConflict: model.conflicts.contains { conflict in
                            conflict.path.contains(need.id.uuidString.lowercased())
                        },
                        canEdit: model.canEdit && !model.isPerformingMutation,
                        onEditProgress: {
                            presentedSheet = .editProgress(.init(
                                need: need,
                                hasConflict: model.conflicts.contains { conflict in
                                    conflict.path.contains(need.id.uuidString.lowercased())
                                }
                            ))
                        },
                        onEditAllocation: { buyerUserID in
                            presentedSheet = .editAllocation(.init(
                                need,
                                buyerUserID: buyerUserID
                            ))
                        },
                        onAddAllocation: {
                            guard let buyer = model.activeMembers.first(where: {
                                $0.userID == currentUserID
                            }) ?? model.activeMembers.first else { return }
                            presentedSheet = .editAllocation(.init(
                                need,
                                buyerUserID: buyer.userID
                            ))
                        },
                        onDelete: { purchaseNeedPendingRemoval = need.id }
                    )
                }
            }

            if model.canEdit {
                Button {
                    presentedSheet = .createNeed
                } label: {
                    HStack(spacing: 8) {
                        LucideIcon("plus")
                        Text("Add purchase request")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(currentUserID == nil || model.isPerformingMutation)
                .accessibilityIdentifier(SharedPlanEditorAccessibilityID.addNeed(circle))
            }

            if model.canEdit, currentUserID == nil {
                Text("Reload your verified profile before creating or assigning a purchase need.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { model.memoText(for: circle) },
            set: { value in model.stageMemo(value, circle: circle, using: store) }
        )
    }

}

private struct SharedPlanCircleIdentityText: View {
    let identity: SharedPlanCircleIdentityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(identity.circleName)
                .font(.headline)
            if let penName = identity.penName {
                Text(penName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LucideLabel(verbatim: identity.dayAndLocation, icon: "map-pin")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SharedPlanCirclePurchasesNavigationTitle: ViewModifier {
    let identity: SharedPlanCircleIdentityPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationTitle("Circle purchases")
                .navigationSubtitle(identity.navigationSubtitle)
        } else {
            content
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text("Circle purchases")
                                .font(.headline)
                            Text(identity.navigationSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
    }
}

private struct SharedPlanCirclePanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
            content
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct SharedPlanPurchaseStageLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            stage("Requested", color: .secondary)
            stage("Assigned", color: .orange)
            stage("Bought", color: .green)
        }
        .font(.caption2.weight(.semibold))
        .accessibilityElement(children: .combine)
    }

    private func stage(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .foregroundStyle(color)
    }
}

private struct SharedPlanPurchaseStageBar: View {
    let progress: SharedPlanPurchaseProgressPresentation
    let accessibilityIdentifier: String

    @ScaledMetric(relativeTo: .caption) private var barHeight = 10.5

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.22))
                    Capsule()
                        .fill(.orange)
                        .frame(width: geometry.size.width * progress.assignedFraction)
                    Capsule()
                        .fill(.green)
                        .frame(width: geometry.size.width * progress.boughtFraction)
                }
                .overlay {
                    Capsule()
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .frame(height: barHeight)

            HStack(spacing: 0) {
                quantityLabel(progress.requested, color: .secondary)
                quantityLabel(progress.assigned, color: .orange)
                quantityLabel(progress.bought, color: .green)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Purchase progress")
        .accessibilityValue(
            "Requested \(progress.requested), assigned \(progress.assigned), bought \(progress.bought)"
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func quantityLabel(_ quantity: Int, color: Color) -> some View {
        Text(quantity.formatted())
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
    }
}

private struct SharedPlanNeedEditorRow: View {
    let need: SharedPlanPurchaseNeed
    let circleDisplayName: String
    let currentUserID: String?
    let members: [SharedPlanMember]
    let hasConflict: Bool
    let canEdit: Bool
    let onEditProgress: () -> Void
    let onEditAllocation: (String) -> Void
    let onAddAllocation: () -> Void
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSize = 60.0

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Text(verbatim: " \n ")
                        .font(.headline)
                        .hidden()
                        .accessibilityHidden(true)

                    Text(displayItemName)
                        .font(.headline)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(circleDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let unitPrice = need.unitPrice {
                    Text(
                        unitPrice,
                        format: .currency(code: "JPY").precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "0")
                        .font(.caption)
                        .hidden()
                        .accessibilityHidden(true)
                }
                if canEdit {
                    Button(action: onEditProgress) {
                        progressBar
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Purchase progress")
                    .accessibilityValue(
                        "Requested \(progress.requested), assigned \(progress.assigned), bought \(progress.bought)"
                    )
                    .accessibilityIdentifier(
                        SharedPlanEditorAccessibilityID.needProgress(need.id)
                    )
                } else {
                    progressBar
                }
            }
            .frame(width: 102, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(participants) { participant in
                        participantAvatar(participant)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, minHeight: avatarSize + 4, alignment: .leading)

            if canEdit {
                Menu {
                    Button("Purchase progress", action: onEditProgress)
                    Button("Assign a buyer", action: onAddAllocation)
                        .disabled(activeMembers.isEmpty)
                    Button("Remove request", role: .destructive, action: onDelete)
                } label: {
                    LucideIcon("ellipsis", size: 22)
                        .frame(width: 28, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More actions for \(displayItemName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(rowBackground, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(statusColor.opacity(0.32), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.need(need.id))
    }

    @ViewBuilder
    private func participantAvatar(_ participant: Participant) -> some View {
        let avatar = AuthenticatedProfileAvatar(
            url: participant.member?.avatarURL,
            size: avatarSize
        )
            .overlay { Circle().strokeBorder(.background, lineWidth: 3) }
            .overlay(alignment: .bottom) {
                HStack(spacing: 3) {
                    if let requestedQuantity = participant.requestedQuantity {
                        quantityBadge(requestedQuantity, color: .secondary)
                    }
                    if participant.assignedQuantity > 0 {
                        quantityBadge(participant.assignedQuantity, color: .orange)
                    }
                }
                .offset(y: 3)
                .zIndex(1)
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(participant.accessibilityLabel)

        if canEdit, participant.member?.membershipStatus == .active {
            Menu {
                if participant.isRequester {
                    Button("Purchase progress", action: onEditProgress)
                }
                Button("Change assigned quantity") {
                    onEditAllocation(participant.userID)
                }
            } label: {
                avatar
            }
            .buttonStyle(.plain)
        } else {
            avatar
        }
    }

    private func quantityBadge(_ quantity: Int, color: Color) -> some View {
        Text("×\(quantity)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color, in: .capsule)
    }

    private var membersByUserID: [String: SharedPlanMember] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.userID, $0) })
    }

    private var activeMembers: [SharedPlanMember] {
        members.filter { $0.membershipStatus == .active }
    }

    private var displayItemName: String {
        let value = need.itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? String(localized: "Purchase item") : value
    }

    private var participants: [Participant] {
        let ids = Set(need.buyerAllocations.compactMap { entry in
            entry.value > 0 ? entry.key : nil
        }).union([need.requesterUserID])
        return ids.map { userID in
            Participant(
                userID: userID,
                member: membersByUserID[userID],
                isRequester: userID == need.requesterUserID,
                requestedQuantity: userID == need.requesterUserID
                    ? need.wantedQuantity
                    : nil,
                assignedQuantity: need.buyerAllocations[userID] ?? 0,
                isCurrentUser: userID == currentUserID
            )
        }.sorted {
            if $0.isRequester != $1.isRequester { return $0.isRequester }
            return $0.userID < $1.userID
        }
    }

    private var progress: SharedPlanPurchaseProgressPresentation {
        SharedPlanPurchaseProgressPresentation(need: need, hasConflict: hasConflict)
    }

    private var progressBar: some View {
        SharedPlanPurchaseStageBar(
            progress: progress,
            accessibilityIdentifier: SharedPlanEditorAccessibilityID.needProgress(need.id)
        )
    }

    private var statusColor: Color {
        switch progress.state {
        case .requested: .secondary
        case .partiallyAssigned, .assigned: .orange
        case .partiallyBought, .bought: .green
        case .needsReview: .red
        }
    }

    private var rowBackground: Color {
        switch progress.state {
        case .requested: Color(uiColor: .secondarySystemGroupedBackground)
        case .partiallyAssigned, .assigned: .orange.opacity(0.08)
        case .partiallyBought, .bought: .green.opacity(0.08)
        case .needsReview: .red.opacity(0.08)
        }
    }

    private var accessibilitySummary: String {
        let participantSummary = participants.map(\.accessibilityLabel).formatted()
        return String(localized: "\(displayItemName). Requested \(progress.requested), assigned \(progress.assigned), bought \(progress.bought). \(participantSummary)")
    }

    private struct Participant: Identifiable {
        let userID: String
        let member: SharedPlanMember?
        let isRequester: Bool
        let requestedQuantity: Int?
        let assignedQuantity: Int
        let isCurrentUser: Bool

        var id: String { userID }

        var accessibilityLabel: String {
            let name = isCurrentUser
                ? String(localized: "You")
                : member?.displayName ?? String(localized: "Former member")
            switch (requestedQuantity, assignedQuantity) {
            case let (.some(requested), assigned) where assigned > 0:
                return String(localized: "\(name), requested \(requested), assigned \(assigned)")
            case let (.some(requested), _):
                return String(localized: "\(name), requested \(requested)")
            case let (_, assigned):
                return String(localized: "\(name), assigned \(assigned)")
            }
        }
    }
}

private struct SharedPlanQuantityControl: View {
    let title: String
    @Binding var quantity: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $quantity, in: range) {
            Text(title)
                .font(.body.weight(.medium))
        }
    }
}

private struct SharedPlanCreateNeedSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let currentUserID: String?
    let identity: SharedPlanCircleIdentityPresentation
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var itemName = ""
    @State private var rawUnitPrice = ""
    @State private var wantedQuantity = 1
    @FocusState private var focusedField: Field?

    private enum Field { case itemName, price }

    var body: some View {
        NavigationStack {
            Form {
                Section("Circle") {
                    SharedPlanCircleIdentityText(identity: identity)
                }
                Section("Purchase need") {
                    TextField(
                        "What should be purchased?",
                        text: $itemName,
                        prompt: Text("For example: new-release set, new release only, or acrylic keychain")
                    )
                    .focused($focusedField, equals: .itemName)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("shared-plan-need-item-name")

                    SharedPlanPurchaseItemPresetRow { selectedItemName in
                        itemName = selectedItemName
                        focusedField = .itemName
                    }

                    SharedPlanQuantityControl(
                        title: String(localized: "Requested"),
                        quantity: $wantedQuantity,
                        range: 1...SharedPlanAutomergeDocument.maximumQuantity
                    )
                    LabeledContent(
                        "Requester",
                        value: currentUserID == nil
                            ? String(localized: "Verified profile required")
                            : String(localized: "You")
                    )

                    TextField(
                        "Price per item (optional)",
                        text: $rawUnitPrice,
                        prompt: Text("Yen")
                    )
                    .focused($focusedField, equals: .price)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("shared-plan-need-unit-price")
                }
            }
            .navigationTitle("Add purchase request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }
                        .disabled(!canCreate)
                }
            }
        }
        .presentationDetents([.medium])
        .task { focusedField = .itemName }
    }

    private var normalizedItemName: String {
        itemName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var unitPrice: Int? {
        guard !rawUnitPrice.isEmpty else { return nil }
        return Int(rawUnitPrice)
    }

    private var canCreate: Bool {
        currentUserID != nil
            && !model.isPerformingMutation
            && !normalizedItemName.isEmpty
            && normalizedItemName.count <= 80
            && (rawUnitPrice.isEmpty || unitPrice.map({ (0...9_999_999).contains($0) }) == true)
    }

    private func create() {
        guard let currentUserID else { return }
        Task {
            await model.createNeed(
                requesterUserID: currentUserID,
                itemName: normalizedItemName,
                unitPrice: unitPrice,
                wantedQuantity: wantedQuantity,
                circle: circle,
                using: store
            )
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }
}

private struct SharedPlanPurchaseProgressEdit: Identifiable {
    let needID: UUID
    let itemName: String
    let requestedQuantity: Int
    let assignedQuantity: Int
    let boughtQuantity: Int
    let hasConflict: Bool

    init(need: SharedPlanPurchaseNeed, hasConflict: Bool) {
        needID = need.id
        let normalizedName = need.itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        itemName = normalizedName.isEmpty ? String(localized: "Purchase item") : normalizedName
        requestedQuantity = need.wantedQuantity
        assignedQuantity = need.buyerAllocations.values.reduce(0, +)
        boughtQuantity = need.fulfilledQuantity
        self.hasConflict = hasConflict
    }

    var id: UUID { needID }
}

private struct SharedPlanPurchaseProgressForm: View {
    let edit: SharedPlanPurchaseProgressEdit
    @Binding var requestedQuantity: Int
    @Binding var boughtQuantity: Int

    var body: some View {
        Form {
            Section {
                SharedPlanPurchaseStageBar(
                    progress: previewProgress,
                    accessibilityIdentifier: SharedPlanEditorAccessibilityID.needProgressPreview(
                        edit.needID
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Text(verbatim: edit.itemName)
            }

            Section {
                SharedPlanQuantityControl(
                    title: String(localized: "Requested"),
                    quantity: $requestedQuantity,
                    range: 1...SharedPlanAutomergeDocument.maximumQuantity
                )
                LabeledContent("Assigned", value: edit.assignedQuantity.formatted())
                SharedPlanQuantityControl(
                    title: String(localized: "Bought"),
                    quantity: $boughtQuantity,
                    range: 0...SharedPlanAutomergeDocument.maximumQuantity
                )
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How many items are needed in total.")
                    Text("How many items were actually bought.")
                }
            }
        }
    }

    private var previewProgress: SharedPlanPurchaseProgressPresentation {
        SharedPlanPurchaseProgressPresentation(
            requested: requestedQuantity,
            assigned: edit.assignedQuantity,
            bought: boughtQuantity,
            hasConflict: edit.hasConflict
        )
    }
}

private struct SharedPlanPurchaseProgressSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let edit: SharedPlanPurchaseProgressEdit
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var requestedQuantity: Int
    @State private var boughtQuantity: Int

    init(
        model: SharedPlanEditorModel,
        store: SharedPlanStore,
        circle: SharedPlanCircleKey,
        edit: SharedPlanPurchaseProgressEdit,
        presentedSheet: Binding<SharedPlanCircleEditorSheet?>
    ) {
        self.model = model
        self.store = store
        self.circle = circle
        self.edit = edit
        _presentedSheet = presentedSheet
        _requestedQuantity = State(initialValue: edit.requestedQuantity)
        _boughtQuantity = State(initialValue: edit.boughtQuantity)
    }

    var body: some View {
        NavigationStack {
            SharedPlanPurchaseProgressForm(
                edit: edit,
                requestedQuantity: $requestedQuantity,
                boughtQuantity: $boughtQuantity
            )
            .navigationTitle("Purchase progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.fraction(0.62)])
    }

    private var canSave: Bool {
        !model.isPerformingMutation
            && (1...SharedPlanAutomergeDocument.maximumQuantity).contains(requestedQuantity)
            && (0...SharedPlanAutomergeDocument.maximumQuantity).contains(boughtQuantity)
            && (requestedQuantity != edit.requestedQuantity
                || boughtQuantity != edit.boughtQuantity)
    }

    private func save() {
        Task {
            await model.setPurchaseProgress(
                requestedQuantity: requestedQuantity,
                boughtQuantity: boughtQuantity,
                needID: edit.needID,
                circle: circle,
                using: store
            )
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }
}

private struct SharedPlanBuyerAllocationEdit: Identifiable {
    let needID: UUID
    let initialValue: Int
    let buyerUserID: String?

    var id: String {
        "\(needID.uuidString.lowercased()):\(buyerUserID ?? "-")"
    }

    init(
        _ need: SharedPlanPurchaseNeed,
        buyerUserID: String
    ) {
        needID = need.id
        initialValue = need.buyerAllocations[buyerUserID] ?? 0
        self.buyerUserID = buyerUserID
    }
}

private struct SharedPlanBuyerAllocationSheet: View {
    @Bindable var model: SharedPlanEditorModel
    let store: SharedPlanStore
    let circle: SharedPlanCircleKey
    let edit: SharedPlanBuyerAllocationEdit
    let currentUserID: String?
    @Binding var presentedSheet: SharedPlanCircleEditorSheet?
    @State private var quantity: Int
    @State private var selectedBuyerUserID: String?
    @ScaledMetric(relativeTo: .body) private var buyerAvatarSize = 32.0

    init(
        model: SharedPlanEditorModel,
        store: SharedPlanStore,
        circle: SharedPlanCircleKey,
        edit: SharedPlanBuyerAllocationEdit,
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
                Section("Assigned") {
                    Picker("Buyer", selection: $selectedBuyerUserID) {
                        ForEach(model.members) { member in
                            buyerLabel(for: member)
                            .tag(String?.some(member.userID))
                            .disabled(member.membershipStatus != .active)
                        }
                    }
                    .onChange(of: selectedBuyerUserID) { _, buyerUserID in
                        guard let buyerUserID else { return }
                        quantity = currentNeed?.buyerAllocations[buyerUserID] ?? 0
                    }
                    SharedPlanQuantityControl(
                        title: String(localized: "Assigned"),
                        quantity: $quantity,
                        range: 0...SharedPlanAutomergeDocument.maximumQuantity
                    )
                }
                Section {
                    Text("Choose who will try to buy these items and how many.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Assigned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentedSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            !(0...SharedPlanAutomergeDocument.maximumQuantity).contains(quantity)
                                || model.isPerformingMutation
                                || !selectedBuyerIsActive
                        )
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func buyerLabel(for member: SharedPlanMember) -> some View {
        HStack(spacing: 10) {
            AuthenticatedProfileAvatar(
                url: member.avatarURL,
                size: buyerAvatarSize
            )
            .accessibilityHidden(true)

            Text(SharedPlanMemberPresentation.label(
                member,
                currentUserID: currentUserID
            ))
        }
    }

    private func save() {
        Task {
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
            if model.issueMessage == nil { presentedSheet = nil }
        }
    }

    private var currentNeed: SharedPlanPurchaseNeed? {
        model.circleContent(for: circle)?.needs.first { $0.id == edit.needID }
    }

    private var selectedBuyerIsActive: Bool {
        guard let selectedBuyerUserID else { return false }
        return model.member(userID: selectedBuyerUserID)?.membershipStatus == .active
    }
}

#if DEBUG
struct SharedPlanPurchaseUITestSurface: View {
    private static let requesterID = "11111111-1111-4111-8111-111111111111"
    private static let buyerID = "22222222-2222-4222-8222-222222222222"

    @State private var presentedProgress: SharedPlanPurchaseProgressEdit?

    private let identity = SharedPlanCircleIdentityPresentation(
        circleName: "うどん道場",
        penName: "青井",
        day: 1,
        blockName: "東A",
        spaceNumber: 12,
        spaceNumberSub: 0
    )

    private let members = [
        SharedPlanMember(
            userID: Self.requesterID,
            displayName: "Aoi",
            avatarURL: nil,
            role: .owner,
            membershipStatus: .active,
            joinedAt: .distantPast,
            removedAt: nil
        ),
        SharedPlanMember(
            userID: Self.buyerID,
            displayName: "Ren",
            avatarURL: nil,
            role: .editor,
            membershipStatus: .active,
            joinedAt: .distantPast,
            removedAt: nil
        ),
    ]

    private let needs = [
        SharedPlanPurchaseNeed(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            requesterUserID: Self.requesterID,
            itemName: "新刊セット",
            unitPrice: 2_000,
            wantedQuantity: 2
        ),
        SharedPlanPurchaseNeed(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
            requesterUserID: Self.requesterID,
            itemName: "新刊のみ",
            unitPrice: 1_000,
            wantedQuantity: 2,
            buyerAllocations: [Self.buyerID: 1]
        ),
        SharedPlanPurchaseNeed(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
            requesterUserID: Self.requesterID,
            itemName: "アクキー",
            wantedQuantity: 1,
            buyerAllocations: [Self.buyerID: 1]
        ),
        SharedPlanPurchaseNeed(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
            requesterUserID: Self.requesterID,
            itemName: "アクリルスタンド",
            unitPrice: 1_500,
            wantedQuantity: 2,
            buyerAllocations: [Self.requesterID: 2],
            fulfilledQuantity: 1
        ),
        SharedPlanPurchaseNeed(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
            requesterUserID: Self.requesterID,
            itemName: "会場限定本",
            unitPrice: 1_000,
            wantedQuantity: 1,
            buyerAllocations: [Self.buyerID: 1],
            fulfilledQuantity: 1
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Purchases")
                            .font(.title3.weight(.bold))
                        Spacer()
                        SharedPlanPurchaseStageLegend()
                    }
                    ForEach(needs) { need in
                        SharedPlanNeedEditorRow(
                            need: need,
                            circleDisplayName: identity.displayName,
                            currentUserID: Self.requesterID,
                            members: members,
                            hasConflict: false,
                            canEdit: true,
                            onEditProgress: {
                                presentedProgress = SharedPlanPurchaseProgressEdit(
                                    need: need,
                                    hasConflict: false
                                )
                            },
                            onEditAllocation: { _ in },
                            onAddAllocation: {},
                            onDelete: {}
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .modifier(SharedPlanCirclePurchasesNavigationTitle(identity: identity))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("shared-plan-purchase-test-surface")
        }
        .sheet(item: $presentedProgress) { edit in
            SharedPlanPurchaseProgressPreviewSheet(edit: edit)
        }
    }
}

private struct SharedPlanPurchaseProgressPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let edit: SharedPlanPurchaseProgressEdit
    @State private var requestedQuantity: Int
    @State private var boughtQuantity: Int

    init(edit: SharedPlanPurchaseProgressEdit) {
        self.edit = edit
        _requestedQuantity = State(initialValue: edit.requestedQuantity)
        _boughtQuantity = State(initialValue: edit.boughtQuantity)
    }

    var body: some View {
        NavigationStack {
            SharedPlanPurchaseProgressForm(
                edit: edit,
                requestedQuantity: $requestedQuantity,
                boughtQuantity: $boughtQuantity
            )
            .navigationTitle("Purchase progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.62)])
    }
}
#endif
