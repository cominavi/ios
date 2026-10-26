import SwiftUI

private enum SharedPlansRoute: Hashable {
    case plan(String)
    case circlePlan(planID: String, publicCircleID: Int)
}

private enum SharedPlansSheet: Identifiable {
    case create(comiketNo: Int)
    case notifications
    case allPlans
    case join

    var id: String {
        switch self {
        case .create(let comiketNo): "create-\(comiketNo)"
        case .notifications: "notifications"
        case .allPlans: "all-plans"
        case .join: "join"
        }
    }
}

struct SharedPlansScreen: View {
    let store: SharedPlanStore
    @State private var navigationPath: [SharedPlansRoute] = []
    @State private var presentedSheet: SharedPlansSheet?
    @State private var queuedSheet: SharedPlansSheet?
    @State private var queuedRoute: SharedPlansRoute?
    @State private var primaryPlanID: String?
    @State private var hasLoadedPrimaryPreference = false
    @State private var presentsInvitationAfterDismissal = false
    @State private var requestsSignInAfterDismissal = false
    let comiketNo: Int?
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing
    let catalogDataSource: CirclemsDataSource?
    let invitationInbox: SharedPlanInvitationInbox
    /// Opens ComiNavi sign-in. The shell supplies it. Without it, signed-out
    /// surfaces tell the person to sign in from the Profile tab.
    let onRequestSignIn: (() -> Void)?
    private let primaryPlanPreference: SharedPlanPrimaryPlanPreference

    init(
        store: SharedPlanStore,
        comiketNo: Int?,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared,
        catalogDataSource: CirclemsDataSource? = AppData.catalogLibrary.dataSource,
        invitationInbox: SharedPlanInvitationInbox = AppData.sharedPlanInvitationInbox,
        primaryPlanDefaults: UserDefaults = .standard,
        onRequestSignIn: (() -> Void)? = nil
    ) {
        self.store = store
        self.comiketNo = comiketNo
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
        self.invitationInbox = invitationInbox
        self.onRequestSignIn = onRequestSignIn
        primaryPlanPreference = SharedPlanPrimaryPlanPreference(defaults: primaryPlanDefaults)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            primaryPlanHome
                .navigationDestination(for: SharedPlansRoute.self) { route in
                    switch route {
                    case let .plan(planID):
                        SharedPlanDetailScreen(
                            store: store,
                            planID: planID,
                            currentUserID: currentUserID,
                            features: features,
                            favoriteImportService: favoriteImportService,
                            catalogDataSource: catalogDataSource
                        )
                    case let .circlePlan(planID, publicCircleID):
                        SharedPlanDetailScreen(
                            store: store,
                            planID: planID,
                            currentUserID: currentUserID,
                            features: features,
                            favoriteImportService: favoriteImportService,
                            catalogDataSource: catalogDataSource,
                            initialPublicCircleID: publicCircleID
                        )
                    }
                }
        }
        .sheet(item: $presentedSheet, onDismiss: completeQueuedSheetTransition) { sheet in
            switch sheet {
            case .create(let comiketNo):
                SharedPlanCreateSheet(
                    store: store,
                    comiketNo: comiketNo,
                    onCreated: selectPrimaryPlan,
                    onSignIn: onRequestSignIn.map { _ in requestSignInAfterDismissal }
                )
            case .notifications:
                SharedPlanNotificationInboxSheet(
                    store: store,
                    currentUserID: currentUserID,
                    features: features,
                    catalogDataSource: catalogDataSource,
                    onOpenCirclePlan: queueOpeningCirclePlan
                )
            case .allPlans:
                SharedPlanSwitcherSheet(
                    activePlans: activePlans,
                    archivedPlans: archivedPlans,
                    recoveryDocuments: store.recoveryDocuments,
                    visiblePlanIDs: Set(store.plans.map(\.id)),
                    primaryPlanID: primaryPlanID,
                    pendingPlanIDs: pendingPlanIDs,
                    canCreate: canCreatePlan,
                    comiketNo: comiketNo,
                    onSelectPrimary: selectPrimaryPlan,
                    onOpenArchived: queueOpeningPlan,
                    onCreate: { queueSheet(.create(comiketNo: $0)) },
                    onJoin: { queueSheet(.join) }
                )
            case .join:
                SharedPlanJoinSheet(onSubmitLink: receiveInvitationLink)
            }
        }
        .task(id: primaryPreferenceKey) {
            hasLoadedPrimaryPreference = false
            let storedPlanID = primaryPlanPreference.planID(
                userID: currentUserID,
                comiketNo: comiketNo
            )
            await store.load()
            primaryPlanID = storedPlanID
            hasLoadedPrimaryPreference = true
            reconcilePrimaryPlan()
            guard currentUserID != nil else { return }
            await store.refresh()
            reconcilePrimaryPlan()
        }
        .onChange(of: activePlanSignature) {
            reconcilePrimaryPlan()
        }
        .onChange(of: store.isLoaded) {
            reconcilePrimaryPlan()
        }
        .onChange(of: store.issueMessage) { _, message in
            guard let message else { return }
            AppToast.showError(
                String(localized: "Shared Plan could not be updated"),
                subtitle: message
            )
            store.issueMessage = nil
        }
    }

    @ViewBuilder
    private var primaryPlanHome: some View {
        if !store.isLoaded || !hasLoadedPrimaryPreference {
            ProgressView("Loading your plans…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Shared Plans")
        } else if let primaryPlan {
            SharedPlanDetailScreen(
                store: store,
                planID: primaryPlan.id,
                currentUserID: currentUserID,
                features: features,
                favoriteImportService: favoriteImportService,
                catalogDataSource: catalogDataSource
            )
            .id(primaryPlan.id)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentedSheet = .allPlans
                    } label: {
                        Label("All plans", systemImage: "rectangle.2.swap")
                    }
                    .accessibilityIdentifier("shared-plan-switcher-button")
                }

                ToolbarItem(placement: .primaryAction) {
                    notificationButton
                }
            }
        } else if activePlans.isEmpty {
            SharedPlanEmptyHome(
                comiketNo: comiketNo,
                isSignedIn: currentUserID != nil,
                createUnavailableReason: createUnavailableReason,
                onSignIn: onRequestSignIn,
                onCreate: presentCreateSheet,
                onJoin: { presentedSheet = .join }
            )
            .navigationTitle("Shared Plans")
            .accessibilityIdentifier("shared-plan-empty-home")
            .toolbar { planListToolbar }
        } else {
            SharedPlanListHome(
                plans: activePlans,
                pendingPlanIDs: pendingPlanIDs,
                canCreate: canCreatePlan,
                onSelect: selectPrimaryPlan,
                onCreate: presentCreateSheet,
                onJoin: { presentedSheet = .join }
            )
            .navigationTitle("Shared Plans")
            .accessibilityIdentifier("shared-plan-list-home")
            .toolbar { planListToolbar }
        }
    }

    /// Toolbar for the tab root when no plan is open. Archived plans and
    /// recovery copies stay reachable even when no active plan exists.
    @ToolbarContentBuilder
    private var planListToolbar: some ToolbarContent {
        if !archivedPlans.isEmpty || !store.recoveryDocuments.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    presentedSheet = .allPlans
                } label: {
                    Label("All plans", systemImage: "rectangle.2.swap")
                }
                .accessibilityIdentifier("shared-plan-switcher-button")
            }
        }
        if currentUserID != nil {
            ToolbarItem(placement: .primaryAction) {
                notificationButton
            }
        }
    }

    private var notificationButton: some View {
        Button {
            presentedSheet = .notifications
        } label: {
            Label(
                "Shared Plan notifications",
                systemImage: unreadNotificationCount > 0 ? "bell.badge" : "bell"
            )
        }
        .accessibilityValue(notificationAccessibilityValue)
        .accessibilityIdentifier("shared-plan-notifications-button")
    }

    private var primaryPlan: SharedPlan? {
        guard let primaryPlanID else { return nil }
        return activePlans.first { $0.id == primaryPlanID }
    }

    private var primaryPreferenceKey: String {
        SharedPlanPrimaryPlanPreference.storageKey(
            userID: currentUserID,
            comiketNo: comiketNo
        )
    }

    private var activePlanSignature: String {
        activePlans.map(\.id).joined(separator: ",")
    }

    private var canCreatePlan: Bool {
        createUnavailableReason == nil
    }

    /// Why Create is disabled, shown under the button instead of a dimmed
    /// control with no explanation.
    private var createUnavailableReason: LocalizedStringResource? {
        guard currentUserID != nil else {
            return "Sign in to create a plan."
        }
        guard let comiketNo else {
            return "Open a Comiket catalog to create a plan for that event."
        }
        guard features.writesEnabled else {
            return "Shared Plans are read-only right now. Try again later."
        }
        guard store.createAvailability(comiketNo: comiketNo).canCreate else {
            return "You have \(SharedPlanCreateAvailability.maximumOwnedActivePlans) active plans for C\(comiketNo), which is the limit. Archive a plan to create another."
        }
        return nil
    }

    private var pendingPlanIDs: Set<String> {
        Set((store.pendingRESTWrites + store.quarantinedRESTWrites).map(\.planID))
    }

    private func reconcilePrimaryPlan() {
        guard store.isLoaded, hasLoadedPrimaryPreference else { return }
        // Several plans with no stored choice show the inline plan list in
        // the tab root instead of a required picker.
        let resolvedPlanID = SharedPlanPrimaryPlanPreference.resolvedPlanID(
            primaryPlanID,
            among: activePlans
        )
        guard resolvedPlanID != primaryPlanID else { return }
        primaryPlanID = resolvedPlanID
        primaryPlanPreference.setPlanID(
            resolvedPlanID,
            userID: currentUserID,
            comiketNo: comiketNo
        )
        navigationPath.removeAll()
    }

    private func selectPrimaryPlan(_ planID: String) {
        guard activePlans.contains(where: { $0.id == planID }) else { return }
        primaryPlanID = planID
        primaryPlanPreference.setPlanID(
            planID,
            userID: currentUserID,
            comiketNo: comiketNo
        )
        navigationPath.removeAll()
        presentedSheet = nil
    }

    private func queueOpeningPlan(_ planID: String) {
        queuedRoute = .plan(planID)
        presentedSheet = nil
    }

    private func queueOpeningCirclePlan(_ planID: String, publicCircleID: Int?) {
        queuedRoute = publicCircleID.map {
            .circlePlan(planID: planID, publicCircleID: $0)
        } ?? .plan(planID)
        presentedSheet = nil
    }

    private func queueSheet(_ sheet: SharedPlansSheet) {
        queuedSheet = sheet
        presentedSheet = nil
    }

    /// Stores a pasted invitation in the shared inbox. The root view presents
    /// the confirmation sheet only after the join sheet has fully dismissed,
    /// because two sheets cannot animate at the same time.
    private func receiveInvitationLink(_ url: URL) -> Bool {
        guard invitationInbox.receive(url: url) else { return false }
        presentsInvitationAfterDismissal = true
        return true
    }

    private func requestSignInAfterDismissal() {
        requestsSignInAfterDismissal = true
        presentedSheet = nil
    }

    private func completeQueuedSheetTransition() {
        if requestsSignInAfterDismissal {
            requestsSignInAfterDismissal = false
            onRequestSignIn?()
            return
        }
        if presentsInvitationAfterDismissal {
            presentsInvitationAfterDismissal = false
            invitationInbox.requestPresentation()
            return
        }
        if let queuedSheet {
            self.queuedSheet = nil
            presentedSheet = queuedSheet
            return
        }
        if let queuedRoute {
            self.queuedRoute = nil
            switch queuedRoute {
            case .plan(let planID):
                navigationPath = planID == primaryPlanID ? [] : [queuedRoute]
            case .circlePlan:
                navigationPath = [queuedRoute]
            }
            return
        }
        reconcilePrimaryPlan()
    }

    private func presentCreateSheet() {
        guard let comiketNo else { return }
        presentedSheet = .create(comiketNo: comiketNo)
    }

    private var activePlans: [SharedPlan] {
        store.plans.filter {
            (comiketNo == nil || $0.comiketNo == comiketNo)
                && $0.lifecycle == .active
        }
    }

    private var archivedPlans: [SharedPlan] {
        store.plans.filter {
            (comiketNo == nil || $0.comiketNo == comiketNo)
                && $0.lifecycle == .archived
        }
    }

    private var unreadNotificationCount: Int {
        store.notifications.count {
            $0.readAt == nil && !store.pendingNotificationReadIDs.contains($0.id)
        }
    }

    private var notificationAccessibilityValue: Text {
        Text("\(unreadNotificationCount) unread notifications")
    }
}

/// The tab root when no active plan exists. It explains what a Shared Plan is
/// and leads with one labeled primary action: Sign in when signed out, Create
/// otherwise.
private struct SharedPlanEmptyHome: View {
    let comiketNo: Int?
    let isSignedIn: Bool
    let createUnavailableReason: LocalizedStringResource?
    let onSignIn: (() -> Void)?
    let onCreate: () -> Void
    let onJoin: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let comiketNo {
                    Text("Plans for C\(comiketNo)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }

                Text("Shop the event together")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    if let comiketNo {
                        Text("A Shared Plan is a shopping list of circles for C\(comiketNo). Everyone in the plan can add circles, ask for items, and mark what they bought.")
                    } else {
                        Text("A Shared Plan is a shopping list of circles that you and your friends edit together. Everyone in the plan can add circles, ask for items, and mark what they bought.")
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    if isSignedIn {
                        SharedPlanHomeActionButton(
                            title: "Create a plan",
                            subtitle: "Start a new list, then invite friends.",
                            icon: "plus",
                            isProminent: true,
                            action: onCreate
                        )
                        .disabled(createUnavailableReason != nil)
                        .accessibilityIdentifier("shared-plan-create-button")

                        if let createUnavailableReason {
                            Label {
                                Text(createUnavailableReason)
                            } icon: {
                                LucideIcon("info", size: 15)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("shared-plan-create-unavailable-reason")
                        }
                    } else if let onSignIn {
                        SharedPlanHomeActionButton(
                            title: "Sign in",
                            subtitle: "Sign in to ComiNavi to create or join a plan.",
                            icon: "circle-user",
                            isProminent: true,
                            action: onSignIn
                        )
                        .accessibilityIdentifier("shared-plan-sign-in-button")
                    } else {
                        Text("Sign in from the Profile tab to create or join a plan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("shared-plan-sign-in-hint")
                    }

                    SharedPlanHomeActionButton(
                        title: "Join with an invite link",
                        subtitle: "Paste a link that a friend sent you.",
                        icon: "users",
                        isProminent: false,
                        action: onJoin
                    )
                    .accessibilityIdentifier("shared-plan-join-button")
                }
                .padding(.top, 24)
            }
            // A readable column on iPad, on the same leading edge as the
            // navigation title instead of centered in empty space.
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
    }
}

/// A full-width action with a visible subtitle. The prominent style is the
/// lime fill behind dark text; the other style is a plain grouped surface.
private struct SharedPlanHomeActionButton: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    let isProminent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LucideIcon(icon, size: 22)
                    .foregroundStyle(isProminent ? Color.onAccentFill : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(isProminent ? Color.onAccentFill.opacity(0.8) : Color.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(isProminent ? Color.onAccentFill : Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                isProminent
                    ? Color.accentFill
                    : Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 16)
            )
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The tab root when several plans exist and none has been opened on this
/// device yet. Choosing a plan opens it and remembers the choice.
private struct SharedPlanListHome: View {
    let plans: [SharedPlan]
    let pendingPlanIDs: Set<String>
    let canCreate: Bool
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onJoin: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(plans) { plan in
                    Button {
                        onSelect(plan.id)
                    } label: {
                        SharedPlanPickerRow(
                            plan: plan,
                            hasPendingChanges: pendingPlanIDs.contains(plan.id),
                            isSelected: false,
                            isArchived: false,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shared-plan-picker-\(plan.id)")
                }
            } header: {
                Text("Your plans")
            } footer: {
                Text("Choose a plan to open. You can switch plans later from All plans.")
            }

            Section {
                if canCreate {
                    Button(action: onCreate) {
                        LucideLabel("Create a plan", icon: "plus")
                    }
                    .accessibilityIdentifier("shared-plan-create-button")
                }
                Button(action: onJoin) {
                    LucideLabel("Join with an invite link", icon: "users")
                }
                .accessibilityIdentifier("shared-plan-join-button")
            }
        }
    }
}

private struct SharedPlanSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    let activePlans: [SharedPlan]
    let archivedPlans: [SharedPlan]
    let recoveryDocuments: [SharedPlanRecoveryDocument]
    let visiblePlanIDs: Set<String>
    let primaryPlanID: String?
    let pendingPlanIDs: Set<String>
    let canCreate: Bool
    let comiketNo: Int?
    let onSelectPrimary: (String) -> Void
    let onOpenArchived: (String) -> Void
    let onCreate: (Int) -> Void
    let onJoin: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Your plans") {
                    ForEach(activePlans) { plan in
                        Button {
                            onSelectPrimary(plan.id)
                        } label: {
                            SharedPlanPickerRow(
                                plan: plan,
                                hasPendingChanges: pendingPlanIDs.contains(plan.id),
                                isSelected: plan.id == primaryPlanID,
                                isArchived: false
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shared-plan-picker-\(plan.id)")
                    }
                }

                if !archivedPlans.isEmpty {
                    Section("Archived") {
                        ForEach(archivedPlans) { plan in
                            Button {
                                onOpenArchived(plan.id)
                            } label: {
                                SharedPlanPickerRow(
                                    plan: plan,
                                    hasPendingChanges: pendingPlanIDs.contains(plan.id),
                                    isSelected: false,
                                    isArchived: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !recoveryDocuments.isEmpty {
                    Section("Recovery") {
                        ForEach(recoveryDocuments) { recovery in
                            SharedPlanRecoveryPickerRow(
                                recovery: recovery,
                                canOpenPlan: visiblePlanIDs.contains(recovery.planID),
                                onOpenPlan: onOpenArchived
                            )
                        }
                    }
                }

                Section {
                    if canCreate, let comiketNo {
                        Button {
                            onCreate(comiketNo)
                        } label: {
                            Label("Create plan", systemImage: "plus")
                        }
                    }
                    Button(action: onJoin) {
                        Label("Join with an invite link", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle("All Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("shared-plan-switcher-sheet")
    }
}

private struct SharedPlanRecoveryPickerRow: View {
    let recovery: SharedPlanRecoveryDocument
    let canOpenPlan: Bool
    let onOpenPlan: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LucideLabel("Recovery copy", icon: "database")
                .font(.headline)
            Text("\(recovery.pendingOperationCount) item changes and \(recovery.metadataIntentCount) plan updates are available in this recovery copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ShareLink(item: recovery.exportText) {
                    LucideLabel("Download recovery copy", icon: "share")
                }
                Spacer()
                if canOpenPlan {
                    Button("Open") { onOpenPlan(recovery.planID) }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}

private struct SharedPlanPickerRow: View {
    let plan: SharedPlan
    let hasPendingChanges: Bool
    let isSelected: Bool
    let isArchived: Bool
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(isArchived ? "archive" : "list-checks", size: 22)
                .foregroundStyle(isArchived ? Color.secondary : Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .font(.headline)
                Text("C\(plan.comiketNo) · \(plan.circleKeys.count) circles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if hasPendingChanges {
                LucideIcon("cloud-upload", size: 16)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pending changes")
            }
            if isSelected {
                LucideIcon("check", size: 18)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Current plan")
            } else if isArchived || showsDisclosure {
                LucideIcon("chevron-right", size: 16)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SharedPlanJoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appHapticFeedback) private var hapticFeedback
    /// Returns false when the link cannot be stored for confirmation.
    let onSubmitLink: (URL) -> Bool
    @State private var linkText = ""
    @State private var issue: LocalizedStringResource?
    @State private var showsSteps = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Invitation link",
                        text: Binding(
                            get: { linkText },
                            set: {
                                linkText = $0
                                issue = nil
                            }
                        ),
                        prompt: Text(verbatim: "https://cominavi.net/join/…")
                    )
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .onSubmit(submit)
                    .accessibilityIdentifier("shared-plan-join-link-field")

                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            linkText = text
                            submit()
                        }
                    }
                    .accessibilityIdentifier("shared-plan-join-paste")
                } header: {
                    Text("Invitation link")
                } footer: {
                    if let issue {
                        Text(issue)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("shared-plan-join-issue")
                    } else {
                        Text("Paste the link that a plan member sent you. ComiNavi shows the plan before you join.")
                    }
                }

                Section {
                    DisclosureGroup("How invitations work", isExpanded: $showsSteps) {
                        guideStep(
                            number: 1,
                            title: "Get an invitation link",
                            detail: "Ask the plan owner to create and share an invitation from Plan information, then Add member."
                        )
                        guideStep(
                            number: 2,
                            title: "Open the link on this device",
                            detail: "Tap the link, or paste it on this screen. The invitation opens in ComiNavi so you can confirm the plan before joining."
                        )
                        guideStep(
                            number: 3,
                            title: "Confirm your account",
                            detail: "Sign in as the person who should join, then accept the invitation."
                        )
                    }
                }
            }
            .navigationTitle("Join a Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: submit)
                        .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("shared-plan-join-submit")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("shared-plan-join-guide")
    }

    private func submit() {
        guard let url = SharedPlanInvitationLink.url(fromPastedText: linkText) else {
            issue = "This is not a ComiNavi invitation link. Check the link and try again."
            hapticFeedback?.play(.error)
            return
        }
        guard onSubmitLink(url) else {
            issue = "ComiNavi could not open this invitation. Try again."
            hapticFeedback?.play(.error)
            return
        }
        dismiss()
    }

    private func guideStep(
        number: Int,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.headline)
                .foregroundStyle(Color.onAccentFill)
                .frame(width: 30, height: 30)
                .background(Color.accentFill, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
struct SharedPlanListUITestSurface: View {
    private enum Route: Hashable {
        case plan(String)
        case circlePlan(planID: String, publicCircleID: Int)
        case information
        case invitations
    }

    static let planID = "11111111-1111-4111-8111-111111111111"
    static let secondPlanID = "11111111-1111-4111-8111-111111111112"

    @State private var navigationPath: [Route] = []
    @State private var primaryPlanID = Self.planID
    @State private var showsSwitcher = false
    @State private var showsNotifications = false
    @State private var queuedNotificationPlanID: String?
    @State private var queuedNotificationCircleID: Int?

    private let plans = [
        SharedPlan(
            id: Self.planID,
            name: "買い物リスト",
            comiketNo: 108,
            ownership: .owned,
            role: .owner,
            lifecycle: .active,
            revision: 1,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1_786_276_800),
            updatedAt: Date(timeIntervalSince1970: 1_786_276_800)
        ),
        SharedPlan(
            id: Self.secondPlanID,
            name: "Travel team",
            comiketNo: 108,
            ownership: .joined,
            role: .editor,
            lifecycle: .active,
            revision: 2,
            circleKeys: [],
            createdAt: Date(timeIntervalSince1970: 1_786_276_800),
            updatedAt: Date(timeIntervalSince1970: 1_786_276_800)
        ),
    ]

    private let progress = SharedPlanProgressSummary(
        circles: [
            SharedPlanCircleContent(
                key: SharedPlanCircleKey(comiketNo: 108, wcID: 101)!,
                presence: .present,
                memo: "",
                needs: [
                    SharedPlanPurchaseNeed(
                        id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                        requesterUserID: "33333333-3333-4333-8333-333333333333",
                        itemName: "New release set",
                        unitPrice: 2_000,
                        wantedQuantity: 7,
                        buyerAllocations: [
                            "33333333-3333-4333-8333-333333333333": 5,
                        ],
                        fulfilledQuantity: 3
                    ),
                ],
                communicationState: [:]
            ),
        ],
        conflictCount: 0
    )

    var body: some View {
        NavigationStack(path: $navigationPath) {
            planDetail(primaryPlan)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .plan(let planID):
                    planDetail(plans.first { $0.id == planID } ?? primaryPlan)
                case let .circlePlan(planID, publicCircleID):
                    circlePlanDetail(
                        plans.first { $0.id == planID } ?? primaryPlan,
                        publicCircleID: publicCircleID
                    )
                case .information:
                    List {
                        Section("Members") {
                            Text("Member list")
                            Label("Add member", systemImage: "link.badge.plus")
                        }
                    }
                    .navigationTitle("Plan information")
                    .accessibilityIdentifier("shared-plan-test-information")
                case .invitations:
                    List {
                        Text("No invitations")
                    }
                    .navigationTitle("Members and invitations")
                    .accessibilityIdentifier("shared-plan-test-invitations")
                }
            }
        }
        .sheet(isPresented: $showsSwitcher) {
            SharedPlanSwitcherSheet(
                activePlans: plans,
                archivedPlans: [],
                recoveryDocuments: [],
                visiblePlanIDs: Set(plans.map(\.id)),
                primaryPlanID: primaryPlanID,
                pendingPlanIDs: [],
                canCreate: true,
                comiketNo: 108,
                onSelectPrimary: { planID in
                    primaryPlanID = planID
                    navigationPath.removeAll()
                    showsSwitcher = false
                },
                onOpenArchived: { _ in },
                onCreate: { _ in },
                onJoin: {}
            )
        }
        .sheet(
            isPresented: $showsNotifications,
            onDismiss: openQueuedNotificationPlan
        ) {
            NavigationStack {
                List {
                    Button {
                        queuedNotificationPlanID = Self.secondPlanID
                        queuedNotificationCircleID = 101
                        showsNotifications = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Purchase progress updated")
                                .font(.headline)
                            Text("Travel team • Purchased: 3")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("shared-plan-test-notification")
                }
                .navigationTitle("Notifications")
            }
            .accessibilityIdentifier("shared-plan-notifications-sheet")
        }
    }

    private var primaryPlan: SharedPlan {
        plans.first { $0.id == primaryPlanID } ?? plans[0]
    }

    private func planDetail(_ plan: SharedPlan) -> some View {
        List {
            Section {
                SharedPlanProgressOverview(progress: progress)
            } header: {
                Text("Plan progress")
            } footer: {
                SharedPlanTotalAmountFooter(totalAmount: progress.totalAmount)
            }
            Section("Circles and purchases") {
                SharedPlanEmptyCirclesView(canEdit: true)
            }
        }
        .navigationTitle(plan.name)
        .accessibilityIdentifier("shared-plan-test-detail")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsSwitcher = true
                } label: {
                    Label("All plans", systemImage: "rectangle.2.swap")
                }
                .accessibilityIdentifier("shared-plan-switcher-button")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsNotifications = true
                } label: {
                    Label("Shared Plan notifications", systemImage: "bell")
                }
                .accessibilityIdentifier("shared-plan-notifications-button")

                NavigationLink(value: Route.information) {
                    Label("Plan information", systemImage: "info.circle")
                }
                .accessibilityIdentifier("shared-plan-information-button")
            }
        }
    }

    private func circlePlanDetail(_ plan: SharedPlan, publicCircleID: Int) -> some View {
        List {
            Section("Plan") {
                LabeledContent("Shared Plan", value: plan.name)
                LabeledContent("Circle ID", value: String(publicCircleID))
            }
            Section("Purchases") {
                Text("New release set")
            }
        }
        .navigationTitle("Circle purchases")
        .accessibilityIdentifier("shared-plan-test-circle-purchases")
    }

    private func openQueuedNotificationPlan() {
        guard let queuedNotificationPlanID else { return }
        self.queuedNotificationPlanID = nil
        if let queuedNotificationCircleID {
            self.queuedNotificationCircleID = nil
            navigationPath = [
                .circlePlan(
                    planID: queuedNotificationPlanID,
                    publicCircleID: queuedNotificationCircleID
                ),
            ]
            return
        }
        navigationPath = queuedNotificationPlanID == primaryPlanID
            ? []
            : [.plan(queuedNotificationPlanID)]
    }
}

struct SharedPlanEmptyUITestSurface: View {
    private enum Sheet: Identifiable {
        case create
        case join

        var id: String {
            switch self {
            case .create: "create"
            case .join: "join"
            }
        }
    }

    @State private var presentedSheet: Sheet?

    var body: some View {
        NavigationStack {
            SharedPlanEmptyHome(
                comiketNo: 108,
                isSignedIn: true,
                createUnavailableReason: nil,
                onSignIn: nil,
                onCreate: { presentedSheet = .create },
                onJoin: { presentedSheet = .join }
            )
            .navigationTitle("Shared Plans")
            .accessibilityIdentifier("shared-plan-empty-home")
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .create:
                NavigationStack {
                    Text("Create plan")
                        .navigationTitle("Create plan")
                        .accessibilityIdentifier("shared-plan-create-test-surface")
                }
            case .join:
                SharedPlanJoinSheet(onSubmitLink: { _ in true })
            }
        }
    }
}
#endif

private struct SharedPlanNotificationInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: SharedPlanStore
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let catalogDataSource: CirclemsDataSource?
    let onOpenCirclePlan: (String, Int?) -> Void

    var body: some View {
        NavigationStack {
            SharedPlanNotificationInboxScreen(
                store: store,
                currentUserID: currentUserID,
                catalogDataSource: catalogDataSource,
                features: features,
                onOpenCirclePlan: onOpenCirclePlan
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("shared-plan-notifications-done")
                }
            }
        }
        .accessibilityIdentifier("shared-plan-notifications-sheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SharedPlanCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appHapticFeedback) private var hapticFeedback
    let store: SharedPlanStore
    let onCreated: (String) -> Void
    let onSignIn: (() -> Void)?
    @State private var name = ""
    @State private var isSaving = false
    @State private var issue: String?
    @State private var requiresSignIn = false
    let comiketNo: Int

    init(
        store: SharedPlanStore,
        comiketNo: Int,
        onCreated: @escaping (String) -> Void = { _ in },
        onSignIn: (() -> Void)? = nil
    ) {
        self.store = store
        self.comiketNo = comiketNo
        self.onCreated = onCreated
        self.onSignIn = onSignIn
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    TextField("Plan name", text: $name)
                        .textInputAutocapitalization(.never)
                    LabeledContent("Comiket", value: "C\(comiketNo)")
                }
                if requiresSignIn {
                    Section {
                        Label {
                            Text("Sign in to ComiNavi to create a plan.")
                        } icon: {
                            LucideIcon("circle-user")
                        }
                        if let onSignIn {
                            Button("Sign in", action: onSignIn)
                                .accessibilityIdentifier("shared-plan-create-sign-in")
                        }
                    }
                } else if let issue {
                    Section {
                        Text(issue)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Create Shared Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                let plan = try await store.createPlan(name: name, comiketNo: comiketNo)
                onCreated(plan.id)
                hapticFeedback?.play(.completion)
                dismiss()
            } catch {
                issue = error.localizedDescription
                requiresSignIn = (error as? SharedPlanError) == .profileRequired
                if store.pendingRESTWrites.contains(where: {
                    $0.kind == .create && $0.name == name && $0.comiketNo == comiketNo
                }) {
                    hapticFeedback?.play(.completion)
                    dismiss()
                } else {
                    hapticFeedback?.play(.error)
                }
            }
            isSaving = false
        }
    }
}

struct SharedPlanDetailScreen: View {
    let store: SharedPlanStore
    let planID: String
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing
    let catalogDataSource: CirclemsDataSource?
    let initialPublicCircleID: Int?

    init(
        store: SharedPlanStore,
        planID: String,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared,
        catalogDataSource: CirclemsDataSource? = AppData.catalogLibrary.dataSource,
        initialPublicCircleID: Int? = nil
    ) {
        self.store = store
        self.planID = planID
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
        self.initialPublicCircleID = initialPublicCircleID
    }

    var body: some View {
        SharedPlanEditorScreen(
            store: store,
            planID: planID,
            currentUserID: currentUserID,
            features: features,
            catalogDataSource: catalogDataSource,
            initialPublicCircleID: initialPublicCircleID
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SharedPlanInformationScreen(
                        store: store,
                        planID: planID,
                        features: features,
                        favoriteImportService: favoriteImportService,
                        catalogDataSource: catalogDataSource
                    )
                } label: {
                    Label("Plan information", systemImage: "info.circle")
                }
                .accessibilityIdentifier("shared-plan-information-button")
            }
        }
    }
}

private struct SharedPlanInformationScreen: View {
    private enum Confirmation: Identifiable {
        case archive
        case administrative(SharedPlanAdministrativeAction)

        var id: String {
            switch self {
            case .archive: "archive-plan"
            case .administrative(let action): action.id
            }
        }
    }

    let store: SharedPlanStore
    @State private var editedName = ""
    @State private var issue: String?
    @State private var showsFavoriteImport = false
    @State private var managementModel: SharedPlanManagementModel
    @State private var presentedManagementSheet: SharedPlanManagementSheet?
    @State private var confirmation: Confirmation?
    let planID: String
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing
    let catalogDataSource: CirclemsDataSource?

    init(
        store: SharedPlanStore,
        planID: String,
        features: SharedPlanPresentationFeatures,
        favoriteImportService: any CirclemsFavoriteImportServicing,
        catalogDataSource: CirclemsDataSource?
    ) {
        self.store = store
        self.planID = planID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
        _managementModel = State(initialValue: SharedPlanManagementModel(
            planID: planID,
            features: features
        ))
    }

    var body: some View {
        Group {
            if let plan {
                List {
                    if !features.writesEnabled {
                        SharedPlanReadOnlyNotice()
                    }

                    if !quarantinedChanges.isEmpty {
                        Section("Changes to review") {
                            Text("This is the latest version of the plan. Review your remaining changes.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                            ForEach(quarantinedChanges) { write in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(quarantinedTitle(write))
                                        .font(.headline)
                                    if let message = write.quarantineMessage {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button("Discard this change", role: .destructive) {
                                        discard(write)
                                    }
                                    .font(.callout)
                                }
                            }
                            if features.writesEnabled,
                               quarantinedChanges.allSatisfy({
                                $0.quarantineReason == .revisionConflict
                            }) {
                                Button("Try again with the latest plan") { retryConflict() }
                                    .buttonStyle(.borderedProminent)
                                Button("Discard all remaining changes", role: .destructive) {
                                    discardAllConflicts()
                                }
                            }
                        }
                    }

                    Section("Plan name") {
                        if features.writesEnabled {
                            TextField("Plan name", text: $editedName)
                                .disabled(plan.role != .owner || !quarantinedChanges.isEmpty)
                                .onSubmit { saveName() }
                            if plan.role == .owner, editedName != plan.name {
                                Button("Save name") { saveName() }
                            }
                        } else {
                            Text(plan.name)
                        }
                    }

                    membersSection
                    invitationLinksSection

                    Section("Circle import") {
                        Button {
                            showsFavoriteImport = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Import Circle.ms favorites")
                                    Text("Review and add only the circles that are not in this plan yet.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    }

                    if let catalogDataSource {
                        Section {
                            NavigationLink {
                                SharedPlanExportScreen(
                                    store: store,
                                    planID: plan.id,
                                    dataSource: catalogDataSource
                                )
                            } label: {
                                Label("Export sharing plan", systemImage: "archivebox")
                            }
                            .accessibilityIdentifier("shared-plan-export-button")
                        }
                    }

                    if features.writesEnabled, plan.role == .owner {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(role: plan.lifecycle == .active ? .destructive : nil) {
                                if plan.lifecycle == .active {
                                    confirmation = .archive
                                } else {
                                    toggleArchive(plan)
                                }
                            } label: {
                                HStack {
                                    Text(archiveButtonTitle(for: plan))
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(plan.lifecycle == .active ? .red : .accentColor)
                            .frame(maxWidth: .infinity)
                            .disabled(!quarantinedChanges.isEmpty)

                            Text(plan.lifecycle == .active
                                ? String(localized: "Archived plans remain available but cannot be edited.")
                                : String(localized: "Reopen this plan to make it editable again."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if let issue {
                        Section {
                            Text(issue)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle("Plan information")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("shared-plan-information-screen")
                .onAppear { editedName = plan.name }
                .onChange(of: plan.name) { _, value in editedName = value }
                .refreshable { await managementModel.refresh(using: store) }
                .task(id: planID) { await managementModel.load(using: store) }
                .sheet(isPresented: $showsFavoriteImport) {
                    SharedPlanFavoriteImportScreen(
                        store: store,
                        previewService: favoriteImportService,
                        planID: plan.id,
                        eventNumber: plan.comiketNo,
                        features: features
                    )
                }
                .sheet(item: $presentedManagementSheet) { sheet in
                    switch sheet {
                    case .createInvitation:
                        SharedPlanCreateInvitationSheet(
                            model: managementModel,
                            store: store,
                            presentedSheet: $presentedManagementSheet
                        )
                    case .createdInvitation(let invitation):
                        SharedPlanCreatedInvitationSheet(
                            invitation: invitation,
                            model: managementModel
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
                .onChange(of: managementModel.actionIssue) { _, message in
                    guard let message else { return }
                    AppToast.showError(
                        String(localized: "Shared Plan could not be updated"),
                        subtitle: message
                    )
                    managementModel.dismissActionIssue()
                }
            } else {
                FocusedActionSurface(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Text("Plan not found")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("This plan was deleted, or you no longer have access to it.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var plan: SharedPlan? {
        store.plans.first { $0.id == planID }
    }

    private var quarantinedChanges: [SharedPlanRESTWrite] {
        store.quarantinedChanges(planID: planID)
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if managementModel.members.isEmpty,
               managementModel.memberIssue == nil,
               managementModel.isRefreshing
            {
                SharedPlanLoadingRow(label: "Loading members")
            } else if managementModel.members.isEmpty {
                ContentUnavailableView(
                    "No members available",
                    systemImage: "person.2.slash",
                    description: Text(
                        managementModel.memberIssue
                            ?? String(localized: "Pull to refresh and try again.")
                    )
                )
            } else {
                ForEach(managementModel.members) { member in
                    SharedPlanMemberRow(
                        member: member,
                        canManage: managementModel.permitsMembershipAdministration
                    ) { action in
                        confirmation = .administrative(action)
                    }
                }
                if managementModel.canLoadMoreMembers {
                    SharedPlanLoadMoreRow(
                        label: "Load more members",
                        isLoading: managementModel.isLoadingMoreMembers
                    ) {
                        Task { await managementModel.loadMoreMembers(using: store) }
                    }
                }
            }

            if managementModel.permitsInvitationCreation {
                Button {
                    presentedManagementSheet = .createInvitation
                } label: {
                    Label("Add member", systemImage: "link.badge.plus")
                }
                .disabled(managementModel.isPerformingAction)
                .accessibilityIdentifier("shared-plan-add-member")
            }

            if let issue = managementModel.memberIssue,
               !managementModel.members.isEmpty
            {
                SharedPlanInlineIssue(message: issue) {
                    Task { await managementModel.refresh(using: store) }
                }
            }
        } header: {
            Text("Members")
        } footer: {
            if managementModel.isOwner {
                Text("Removed members remain listed so the owner can explicitly reinstate them.")
            }
        }
    }

    @ViewBuilder
    private var invitationLinksSection: some View {
        if !managementModel.visibleInvitations.isEmpty
            || managementModel.isRefreshing
            || managementModel.invitationIssue != nil
        {
            Section("Invitation links") {
                if managementModel.visibleInvitations.isEmpty,
                   managementModel.invitationIssue == nil,
                   managementModel.isRefreshing
                {
                    SharedPlanLoadingRow(label: "Loading invitation links")
                }

                ForEach(managementModel.visibleInvitations) { invitation in
                    SharedPlanInvitationRow(
                        invitation: invitation,
                        canManage: managementModel.permitsInvitationRevocation(
                            invitationID: invitation.invitationID
                        )
                    ) {
                        confirmation = .administrative(.revokeInvitation(
                            invitationID: invitation.invitationID
                        ))
                    }
                }

                if managementModel.canLoadMoreInvitations {
                    SharedPlanLoadMoreRow(
                        label: "Load more invitation links",
                        isLoading: managementModel.isLoadingMoreInvitations
                    ) {
                        Task { await managementModel.loadMoreInvitations(using: store) }
                    }
                }

                if let issue = managementModel.invitationIssue {
                    SharedPlanInlineIssue(message: issue) {
                        Task { await managementModel.refresh(using: store) }
                    }
                }
            }
        }
    }

    private func archiveButtonTitle(for plan: SharedPlan) -> LocalizedStringResource {
        plan.lifecycle == .active ? "Archive..." : "Reopen"
    }

    @ViewBuilder
    private func confirmationActions(_ item: Confirmation) -> some View {
        switch item {
        case .archive:
            Button("Archive", role: .destructive) {
                confirmation = nil
                guard let plan else { return }
                toggleArchive(plan)
            }
        case .administrative(let action):
            Button(role: action.isDestructive ? .destructive : nil) {
                confirmation = nil
                Task { await managementModel.perform(action, using: store) }
            } label: {
                Text(action.confirmationButtonTitle)
            }
        }
        Button("Cancel", role: .cancel) { confirmation = nil }
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .archive:
            String(localized: "This plan will become read-only. You can reopen it later.")
        case .administrative(let action):
            action.confirmationMessage
        }
    }

    private func quarantinedTitle(_ write: SharedPlanRESTWrite) -> String {
        switch write.kind {
        case .rename: String(localized: "Rename to “\(write.name ?? "")”")
        case .archive: String(localized: "Archive")
        case .reopen: String(localized: "Reopen")
        case .create: String(localized: "Create plan")
        case .acceptInvitation: String(localized: "Join from invitation")
        case .revokeMember: String(localized: "Remove member")
        case .reinstateMember: String(localized: "Reinstate member")
        case .transferOwnership: String(localized: "Transfer ownership")
        case .createInvitation: String(localized: "Create invitation")
        case .revokeInvitation: String(localized: "Revoke invitation")
        }
    }

    private func retryConflict() {
        Task {
            do {
                try await store.retryQuarantinedMetadataChanges(planID: planID)
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

    private func discardAllConflicts() {
        Task {
            do {
                try await store.discardQuarantinedMetadataChanges(planID: planID)
                if let plan { editedName = plan.name }
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

    private func discard(_ write: SharedPlanRESTWrite) {
        Task {
            do {
                try await store.discardQuarantinedWrite(id: write.id)
                if let plan { editedName = plan.name }
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

    private func saveName() {
        Task {
            do {
                try await store.renamePlan(id: planID, name: editedName)
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

    private func toggleArchive(_ plan: SharedPlan) {
        Task {
            do {
                if plan.lifecycle == .active {
                    try await store.archivePlan(id: plan.id)
                } else {
                    try await store.reopenPlan(id: plan.id)
                }
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

}
