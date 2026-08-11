import SwiftUI

private enum SharedPlansRoute: Hashable {
    case plan(String)
}

private enum SharedPlansSheet: Identifiable {
    case create(comiketNo: Int)
    case notifications
    case planSwitcher(required: Bool)
    case joinGuide

    var id: String {
        switch self {
        case .create(let comiketNo): "create-\(comiketNo)"
        case .notifications: "notifications"
        case .planSwitcher(let required): "plan-switcher-\(required)"
        case .joinGuide: "join-guide"
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
    let comiketNo: Int?
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing
    let catalogDataSource: CirclemsDataSource?
    private let primaryPlanPreference: SharedPlanPrimaryPlanPreference

    init(
        store: SharedPlanStore,
        comiketNo: Int?,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared,
        catalogDataSource: CirclemsDataSource? = AppData.catalogLibrary.dataSource,
        primaryPlanDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.comiketNo = comiketNo
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
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
                    }
                }
        }
        .sheet(item: $presentedSheet, onDismiss: completeQueuedSheetTransition) { sheet in
            switch sheet {
            case .create(let comiketNo):
                SharedPlanCreateSheet(
                    store: store,
                    comiketNo: comiketNo,
                    onCreated: selectPrimaryPlan
                )
            case .notifications:
                SharedPlanNotificationInboxSheet(
                    store: store,
                    currentUserID: currentUserID,
                    features: features,
                    catalogDataSource: catalogDataSource,
                    onOpenPlan: queueOpeningPlan
                )
            case .planSwitcher(let required):
                SharedPlanSwitcherSheet(
                    activePlans: activePlans,
                    archivedPlans: archivedPlans,
                    recoveryDocuments: store.recoveryDocuments,
                    visiblePlanIDs: Set(store.plans.map(\.id)),
                    primaryPlanID: primaryPlanID,
                    required: required,
                    pendingPlanIDs: pendingPlanIDs,
                    canCreate: canCreatePlan,
                    comiketNo: comiketNo,
                    onSelectPrimary: selectPrimaryPlan,
                    onOpenArchived: queueOpeningPlan,
                    onCreate: { queueSheet(.create(comiketNo: $0)) },
                    onJoin: { queueSheet(.joinGuide) }
                )
            case .joinGuide:
                SharedPlanJoinGuideSheet()
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
            await store.refresh()
            reconcilePrimaryPlan()
        }
        .onChange(of: activePlanSignature) {
            reconcilePrimaryPlan()
        }
        .onChange(of: store.isLoaded) {
            reconcilePrimaryPlan()
        }
        .alert(
            "共有プランを更新できませんでした",
            isPresented: Binding(
                get: { store.issueMessage != nil },
                set: { if !$0 { store.issueMessage = nil } }
            )
        ) {
            Button("OK") { store.issueMessage = nil }
        } message: {
            Text(store.issueMessage ?? "しばらくしてからもう一度お試しください。")
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
                        presentedSheet = .planSwitcher(required: false)
                    } label: {
                        Label("Switch primary plan", systemImage: "rectangle.2.swap")
                    }
                    .accessibilityIdentifier("shared-plan-switcher-button")
                }

                ToolbarItem(placement: .primaryAction) {
                    notificationButton
                }
            }
        } else if activePlans.isEmpty {
            SharedPlanEmptyHome(
                canCreate: canCreatePlan,
                onAdd: presentCreateSheet,
                onJoin: { presentedSheet = .joinGuide }
            )
            .navigationTitle("Shared Plans")
            .accessibilityIdentifier("shared-plan-empty-home")
            .toolbar {
                if !archivedPlans.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            presentedSheet = .planSwitcher(required: false)
                        } label: {
                            Label("View archived plans", systemImage: "archive")
                        }
                        .accessibilityIdentifier("shared-plan-switcher-button")
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Shared Plans")
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
        guard features.writesEnabled, let comiketNo else { return false }
        return store.createAvailability(comiketNo: comiketNo).canCreate
    }

    private var pendingPlanIDs: Set<String> {
        Set((store.pendingRESTWrites + store.quarantinedRESTWrites).map(\.planID))
    }

    private func reconcilePrimaryPlan() {
        guard store.isLoaded, hasLoadedPrimaryPreference else { return }
        let validPlanID = SharedPlanPrimaryPlanPreference.validPlanID(
            primaryPlanID,
            among: activePlans
        )
        if validPlanID != primaryPlanID {
            primaryPlanID = validPlanID
            primaryPlanPreference.setPlanID(
                validPlanID,
                userID: currentUserID,
                comiketNo: comiketNo
            )
            navigationPath.removeAll()
        }
        guard validPlanID == nil, !activePlans.isEmpty else { return }
        if presentedSheet == nil {
            presentedSheet = .planSwitcher(required: true)
        }
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

    private func queueSheet(_ sheet: SharedPlansSheet) {
        queuedSheet = sheet
        presentedSheet = nil
    }

    private func completeQueuedSheetTransition() {
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

private struct SharedPlanEmptyHome: View {
    let canCreate: Bool
    let onAdd: () -> Void
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            actionButton(
                title: "Add",
                icon: "plus",
                hint: "Creates a new Shared Plan.",
                action: onAdd
            )
            .disabled(!canCreate)

            actionButton(
                title: "Join",
                icon: "person.crop.circle.badge.plus",
                hint: "Shows how to join a Shared Plan.",
                action: onJoin
            )
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func actionButton(
        title: LocalizedStringKey,
        icon: String,
        hint: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                LucideIcon(icon, size: 30)
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(.background, in: .rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }
}

private struct SharedPlanSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    let activePlans: [SharedPlan]
    let archivedPlans: [SharedPlan]
    let recoveryDocuments: [SharedPlanRecoveryDocument]
    let visiblePlanIDs: Set<String>
    let primaryPlanID: String?
    let required: Bool
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

                if !required, !archivedPlans.isEmpty {
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

                if !required, !recoveryDocuments.isEmpty {
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
                        Label("How to join a plan", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle(required ? "Choose a primary plan" : "Switch plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !required {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(required)
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
            LucideLabel("Saved recovery copy", icon: "database")
                .font(.headline)
            Text("\(recovery.pendingOperationCount) item changes and \(recovery.metadataIntentCount) plan updates are saved on this device.")
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
                    .accessibilityLabel("Primary plan")
            } else if isArchived {
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

private struct SharedPlanJoinGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    guideStep(
                        number: 1,
                        title: "Get an invitation link",
                        detail: "Ask the plan owner to create and share an invitation from Plan information, then Members and invitations."
                    )
                    guideStep(
                        number: 2,
                        title: "Open the link on this iPhone",
                        detail: "The invitation opens in ComiNavi so you can confirm the plan before joining."
                    )
                    guideStep(
                        number: 3,
                        title: "Confirm your account",
                        detail: "Sign in as the person who should join, then accept the invitation."
                    )
                } footer: {
                    Text("Joining starts from an invitation link; there is no code to enter on this screen.")
                }
            }
            .navigationTitle("How to join a plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("shared-plan-join-guide")
    }

    private func guideStep(
        number: Int,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: .circle)
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
                case .information:
                    List {
                        NavigationLink(value: Route.invitations) {
                            Label("Members and invitations", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("shared-plan-open-management")
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
                required: false,
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
                        showsNotifications = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Travel team updated a purchase")
                                .font(.headline)
                            Text("Open the plan to review this update.")
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
            Section("Plan progress") {
                SharedPlanProgressOverview(progress: progress)
            }
            Section("Circles and purchases") {
                Text("No circles in this plan")
            }
        }
        .navigationTitle(plan.name)
        .accessibilityIdentifier("shared-plan-test-detail")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsSwitcher = true
                } label: {
                    Label("Switch primary plan", systemImage: "rectangle.2.swap")
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

    private func openQueuedNotificationPlan() {
        guard let queuedNotificationPlanID else { return }
        self.queuedNotificationPlanID = nil
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
                canCreate: true,
                onAdd: { presentedSheet = .create },
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
                SharedPlanJoinGuideSheet()
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
    let onOpenPlan: (String) -> Void

    var body: some View {
        NavigationStack {
            SharedPlanNotificationInboxScreen(
                store: store,
                currentUserID: currentUserID,
                catalogDataSource: catalogDataSource,
                features: features,
                onOpenPlan: onOpenPlan
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
    let store: SharedPlanStore
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var isSaving = false
    @State private var issue: String?
    let comiketNo: Int

    init(
        store: SharedPlanStore,
        comiketNo: Int,
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.comiketNo = comiketNo
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("プラン") {
                    TextField("プラン名", text: $name)
                        .textInputAutocapitalization(.never)
                    LabeledContent("コミケ", value: "C\(comiketNo)")
                }
                if let issue {
                    Section {
                        Text(issue)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("作成にはネットワーク接続が必要です。送信できない場合は、同じリクエストを端末に保存して自動で再試行します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("共有プランを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") { create() }
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
                dismiss()
            } catch {
                issue = error.localizedDescription
                if store.pendingRESTWrites.contains(where: {
                    $0.kind == .create && $0.name == name && $0.comiketNo == comiketNo
                }) {
                    dismiss()
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

    init(
        store: SharedPlanStore,
        planID: String,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared,
        catalogDataSource: CirclemsDataSource? = AppData.catalogLibrary.dataSource
    ) {
        self.store = store
        self.planID = planID
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
    }

    var body: some View {
        SharedPlanEditorScreen(
            store: store,
            planID: planID,
            currentUserID: currentUserID,
            features: features,
            catalogDataSource: catalogDataSource
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SharedPlanInformationScreen(
                        store: store,
                        planID: planID,
                        features: features,
                        favoriteImportService: favoriteImportService
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
    let store: SharedPlanStore
    @State private var editedName = ""
    @State private var issue: String?
    @State private var showsFavoriteImport = false
    let planID: String
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing

    var body: some View {
        Group {
            if let plan {
                List {
                    if !features.writesEnabled {
                        SharedPlanReadOnlyNotice()
                    }

                    if !quarantinedChanges.isEmpty {
                        Section("確認が必要な変更") {
                            Text("サーバー上の最新状態を表示しています。端末に残した変更は自動送信されません。")
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
                                    Button("この変更を破棄", role: .destructive) {
                                        discard(write)
                                    }
                                    .font(.callout)
                                }
                            }
                            if features.writesEnabled,
                               quarantinedChanges.allSatisfy({
                                $0.quarantineReason == .revisionConflict
                            }) {
                                Button("最新状態でもう一度試す") { retryConflict() }
                                    .buttonStyle(.borderedProminent)
                                Button("端末の変更をすべて破棄", role: .destructive) {
                                    discardAllConflicts()
                                }
                            }
                        }
                    }

                    Section("プラン名") {
                        if features.writesEnabled {
                            TextField("プラン名", text: $editedName)
                                .disabled(plan.role != .owner || !quarantinedChanges.isEmpty)
                                .onSubmit { saveName() }
                            if plan.role == .owner, editedName != plan.name {
                                Button("名前を保存") { saveName() }
                            }
                        } else {
                            Text(plan.name)
                        }
                    }

                    Section("Collaboration") {
                        NavigationLink {
                            SharedPlanManagementScreen(
                                store: store,
                                planID: plan.id,
                                features: features
                            )
                        } label: {
                            Label("Members and invitations", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("shared-plan-open-management")
                    }

                    Section("Circle import") {
                        Button {
                            showsFavoriteImport = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Circle.msのお気に入りを読み込む")
                                    Text("プランにまだないサークルだけを確認して追加します。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    }

                    if features.writesEnabled, plan.role == .owner {
                        Section {
                            Button(archiveButtonTitle(for: plan)) {
                                toggleArchive(plan)
                            }
                            .disabled(!quarantinedChanges.isEmpty)
                        } header: {
                            Text("Plan status")
                        } footer: {
                            Text(plan.lifecycle == .active
                                ? String(localized: "Archived plans remain available but cannot be edited.")
                                : String(localized: "Reopen this plan to make it editable again."))
                        }
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
                .sheet(isPresented: $showsFavoriteImport) {
                    SharedPlanFavoriteImportScreen(
                        store: store,
                        previewService: favoriteImportService,
                        planID: plan.id,
                        eventNumber: plan.comiketNo,
                        features: features
                    )
                }
            } else {
                FocusedActionSurface(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Text("プランが見つかりません")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("このプランは削除されたか、アクセスできなくなった可能性があります。")
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

    private func archiveButtonTitle(for plan: SharedPlan) -> String {
        plan.lifecycle == .active ? "アーカイブ" : "再開"
    }

    private func quarantinedTitle(_ write: SharedPlanRESTWrite) -> String {
        switch write.kind {
        case .rename: "名前の変更「\(write.name ?? "")」"
        case .archive: "アーカイブ"
        case .reopen: "再開"
        case .create: "プランの作成"
        case .acceptInvitation: "招待への参加"
        case .revokeMember: "メンバーの参加解除"
        case .reinstateMember: "メンバーの再参加"
        case .transferOwnership: "オーナーの変更"
        case .createInvitation: "招待の作成"
        case .revokeInvitation: "招待の取り消し"
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
