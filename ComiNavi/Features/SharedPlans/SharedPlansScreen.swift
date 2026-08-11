import SwiftUI

private enum SharedPlansRoute: Hashable {
    case plan(String)
}

private enum SharedPlansSheet: Identifiable {
    case create(comiketNo: Int)
    case notifications

    var id: String {
        switch self {
        case .create(let comiketNo): "create-\(comiketNo)"
        case .notifications: "notifications"
        }
    }
}

struct SharedPlansScreen: View {
    let store: SharedPlanStore
    @State private var presentedSheet: SharedPlansSheet?
    @State private var recoveryPlanToDiscard: String?
    let comiketNo: Int?
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing
    let catalogDataSource: CirclemsDataSource?

    init(
        store: SharedPlanStore,
        comiketNo: Int?,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared,
        catalogDataSource: CirclemsDataSource? = AppData.catalogLibrary.dataSource
    ) {
        self.store = store
        self.comiketNo = comiketNo
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
        self.catalogDataSource = catalogDataSource
    }

    var body: some View {
        NavigationStack {
            sidebar
                .navigationDestination(for: SharedPlansRoute.self) { route in
                    switch route {
                    case let .plan(planID):
                        SharedPlanDetailScreen(
                            store: store,
                            planID: planID,
                            currentUserID: currentUserID,
                            features: features,
                            favoriteImportService: favoriteImportService
                        )
                    }
                }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .create(let comiketNo):
                SharedPlanCreateSheet(
                    store: store,
                    comiketNo: comiketNo
                )
            case .notifications:
                SharedPlanNotificationInboxSheet(
                    store: store,
                    currentUserID: currentUserID,
                    features: features,
                    catalogDataSource: catalogDataSource
                )
            }
        }
        .task {
            await store.load()
            await store.refresh()
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
        .confirmationDialog(
            "この復旧データを端末から削除しますか？",
            isPresented: Binding(
                get: { recoveryPlanToDiscard != nil },
                set: { if !$0 { recoveryPlanToDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                guard let recoveryID = recoveryPlanToDiscard else { return }
                recoveryPlanToDiscard = nil
                Task {
                    do {
                        try await store.discardRecoveryDocument(id: recoveryID)
                    } catch {
                        store.issueMessage = error.localizedDescription
                    }
                }
            }
            Button("キャンセル", role: .cancel) { recoveryPlanToDiscard = nil }
        } message: {
            Text("先に「書き出す」で保存できます。削除したデータは元に戻せません。")
        }
    }

    private var sidebar: some View {
        List {
            if !features.writesEnabled {
                SharedPlanReadOnlyNotice()
            }
            pendingSection
            recoverySection
            activeSection
            archiveSection
        }
        .navigationTitle("共有プラン")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if store.isRefreshing || store.isDrainingOutbox {
                    ProgressView()
                        .accessibilityLabel("プランを同期中")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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

                if features.writesEnabled, let comiketNo {
                    Button {
                        presentedSheet = .create(comiketNo: comiketNo)
                    } label: {
                        Label("プランを作成", systemImage: "plus")
                    }
                    .disabled(!store.createAvailability(comiketNo: comiketNo).canCreate)
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private var pendingSection: some View {
        if !pendingWrites.isEmpty {
            Section("送信待ち") {
                ForEach(pendingWrites) { write in
                    SharedPlanPendingRow(
                        write: write,
                        issue: store.restWriteIssues[write.id],
                        onDiscard: write.isQuarantined ? { discard(write) } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if !store.recoveryDocuments.isEmpty {
            Section {
                ForEach(store.recoveryDocuments) { recovery in
                    let isVisiblePlan = recovery.id == recovery.planID
                        && store.plans.contains { $0.id == recovery.planID }
                    SharedPlanRecoveryRow(
                        recovery: recovery,
                        planRoute: isVisiblePlan ? .plan(recovery.planID) : nil,
                        onDiscard: isVisiblePlan ? nil : {
                            recoveryPlanToDiscard = recovery.id
                        }
                    )
                }
            } header: {
                Text("復旧データ")
            } footer: {
                Text("表示中のプランは詳細画面で復旧方法を選べます。アクセスできない以前のデータは、書き出してから端末から削除できます。")
            }
        }
    }

    private var activeSection: some View {
        Section("有効なプラン") {
            if activePlans.isEmpty {
                ContentUnavailableView(
                    "プランはまだありません",
                    systemImage: "list.bullet.clipboard",
                    description: Text(features.writesEnabled
                        ? String(localized: "サークルや買い物を共有するプランを作成できます。")
                        : String(localized: "No Shared Plans are available."))
                )
            } else {
                ForEach(activePlans) { plan in planLink(plan) }
            }
        }
    }

    @ViewBuilder
    private var archiveSection: some View {
        if !archivedPlans.isEmpty {
            Section("アーカイブ") {
                ForEach(archivedPlans) { plan in planLink(plan) }
            }
        }
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

    private var pendingWrites: [SharedPlanRESTWrite] {
        (store.pendingRESTWrites + store.quarantinedRESTWrites).filter {
            ($0.kind == .create && (comiketNo == nil || $0.comiketNo == comiketNo))
                || $0.kind == .acceptInvitation
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

    private func planLink(_ plan: SharedPlan) -> some View {
        NavigationLink(value: SharedPlansRoute.plan(plan.id)) {
            SharedPlanNavigationRow(
                plan: plan,
                hasPendingChanges: store.hasPendingChanges(planID: plan.id)
            )
        }
        .accessibilityIdentifier("shared-plan-row-\(plan.id)")
    }

    private func discard(_ write: SharedPlanRESTWrite) {
        Task {
            do {
                try await store.discardQuarantinedWrite(id: write.id)
            } catch {
                store.issueMessage = error.localizedDescription
            }
        }
    }
}

private struct SharedPlanRecoveryRow: View {
    let recovery: SharedPlanRecoveryDocument
    let planRoute: SharedPlansRoute?
    let onDiscard: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                planRoute != nil ? "復旧が必要なプラン" : "アクセスできないプラン",
                systemImage: planRoute != nil
                    ? "externaldrive.badge.exclamationmark"
                    : "lock.trianglebadge.exclamationmark"
            )
            .font(.headline)
            Text(recovery.planID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ShareLink(item: recovery.exportText) {
                    Label("書き出す", systemImage: "square.and.arrow.up")
                }
                Spacer()
                if let planRoute {
                    NavigationLink("復旧内容を確認", value: planRoute)
                }
                if let onDiscard {
                    Button("端末から削除", role: .destructive, action: onDiscard)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        "未同期の編集 \(recovery.pendingOperationCount)件・プラン情報の変更 \(recovery.metadataIntentCount)件"
    }
}

private struct SharedPlanNavigationRow: View {
    let plan: SharedPlan
    let hasPendingChanges: Bool

    var body: some View {
        SharedPlanRow(plan: plan, hasPendingChanges: hasPendingChanges)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

private struct SharedPlanRow: View {
    let plan: SharedPlan
    let hasPendingChanges: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: plan.lifecycle == .archived
                ? "archivebox"
                : "list.bullet.clipboard")
                .font(.title3.weight(.semibold))
                .foregroundStyle(plan.lifecycle == .archived ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 32)
                .accessibilityLabel("共有プラン")
                .accessibilityIdentifier("shared-plan-row-icon-\(plan.id)")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(plan.name)
                        .font(.headline)
                    Spacer(minLength: 8)
                    if hasPendingChanges {
                        Label("送信待ち", systemImage: "icloud.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("送信待ちの変更があります")
                    }
                }
                HStack(spacing: 8) {
                    Text("C\(plan.comiketNo)")
                    Text("サークル \(plan.circleKeys.count)件")
                    Text(roleLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }

    private var roleLabel: LocalizedStringKey {
        switch plan.role {
        case .owner: "オーナー"
        case .editor: "編集者"
        case .viewer: "閲覧者"
        }
    }
}

#if DEBUG
struct SharedPlanListUITestSurface: View {
    private enum Route: Hashable {
        case plan
        case invitations
    }

    static let planID = "11111111-1111-4111-8111-111111111111"

    private let plan = SharedPlan(
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
    )

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: Route.plan) {
                    SharedPlanNavigationRow(
                        plan: plan,
                        hasPendingChanges: false
                    )
                }
                .accessibilityIdentifier("shared-plan-row-\(plan.id)")
            }
            .navigationTitle("共有プラン")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .plan:
                    List {
                        NavigationLink(value: Route.invitations) {
                            Label("Members and invitations", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("shared-plan-open-management")
                    }
                    .navigationTitle(plan.name)
                    .accessibilityIdentifier("shared-plan-test-detail")
                case .invitations:
                    List {
                        Text("No invitations")
                    }
                    .navigationTitle("Members and invitations")
                    .accessibilityIdentifier("shared-plan-test-invitations")
                }
            }
        }
    }
}
#endif

private struct SharedPlanPendingRow: View {
    let write: SharedPlanRESTWrite
    let issue: String?
    let onDiscard: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: write.isQuarantined ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .foregroundStyle(write.isQuarantined ? .orange : .secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                if let onDiscard {
                    Button("破棄", role: .destructive, action: onDiscard)
                        .buttonStyle(.borderless)
                }
            }
            Text(issue ?? (write.isQuarantined
                ? "自動送信を停止しました。内容を確認して破棄してください。"
                : "ネットワーク接続後に自動で再送します。"))
                .font(.caption)
                .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
        }
    }

    private var title: String {
        switch write.kind {
        case .create: write.name ?? "新しいプラン"
        case .acceptInvitation: "招待への参加"
        case .rename, .archive, .reopen: "プランの更新"
        case .revokeMember: "メンバーの参加解除"
        case .reinstateMember: "メンバーの再参加"
        case .transferOwnership: "オーナーの変更"
        case .createInvitation: "招待の作成"
        case .revokeInvitation: "招待の取り消し"
        }
    }
}

private struct SharedPlanNotificationInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: SharedPlanStore
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let catalogDataSource: CirclemsDataSource?

    var body: some View {
        NavigationStack {
            SharedPlanNotificationInboxScreen(
                store: store,
                currentUserID: currentUserID,
                catalogDataSource: catalogDataSource,
                features: features
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
    @State private var name = ""
    @State private var isSaving = false
    @State private var issue: String?
    let comiketNo: Int

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
                _ = try await store.createPlan(name: name, comiketNo: comiketNo)
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
    @State private var editedName = ""
    @State private var issue: String?
    @State private var showsFavoriteImport = false
    let planID: String
    let currentUserID: String?
    let features: SharedPlanPresentationFeatures
    let favoriteImportService: any CirclemsFavoriteImportServicing

    init(
        store: SharedPlanStore,
        planID: String,
        currentUserID: String? = nil,
        features: SharedPlanPresentationFeatures = .production,
        favoriteImportService: any CirclemsFavoriteImportServicing = CominaviServiceClient.shared
    ) {
        self.store = store
        self.planID = planID
        self.currentUserID = currentUserID
        self.features = features
        self.favoriteImportService = favoriteImportService
    }

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

                    Section("Content and purchases") {
                        NavigationLink {
                            SharedPlanEditorScreen(
                                store: store,
                                planID: plan.id,
                                currentUserID: currentUserID,
                                features: features
                            )
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Circles, memos, and purchases")
                                    Text("Review collaborative content, conflicts, and saved recovery data.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "list.bullet.clipboard")
                            }
                        }
                        .accessibilityIdentifier(SharedPlanEditorAccessibilityID.openEditor)

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

                    if let issue {
                        Section {
                            Text(issue)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle(plan.name)
                .toolbar {
                    if features.writesEnabled, plan.role == .owner {
                        ToolbarItem(placement: .primaryAction) {
                            Button(archiveButtonTitle(for: plan)) {
                                toggleArchive(plan)
                            }
                            .disabled(!quarantinedChanges.isEmpty)
                        }
                    }
                }
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
                ContentUnavailableView("プランが見つかりません", systemImage: "exclamationmark.triangle")
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
