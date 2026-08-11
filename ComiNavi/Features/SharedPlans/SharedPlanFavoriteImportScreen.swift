import SwiftUI

struct SharedPlanFavoriteImportScreen: View {
    let store: SharedPlanStore
    let previewService: any CirclemsFavoriteImportServicing
    @State private var model: SharedPlanFavoriteImportModel
    @Environment(\.dismiss) private var dismiss

    init(
        store: SharedPlanStore,
        previewService: any CirclemsFavoriteImportServicing,
        planID: String,
        eventNumber: Int,
        features: SharedPlanPresentationFeatures
    ) {
        self.store = store
        self.previewService = previewService
        _model = State(initialValue: SharedPlanFavoriteImportModel(
            planID: planID,
            eventNumber: eventNumber,
            features: features
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading, model.items.isEmpty {
                    FocusedActionSurface(
                        symbolName: "star",
                        animatesBackdrop: true
                    ) {
                        Text("お気に入りを確認中…")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Circle.msから、このプランにまだないサークルを探しています。")
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                        CatalogActivityIndicator(
                            accessibilityLabel: "Circle.msのお気に入りを確認中…"
                        )
                        .padding(.top, 30)
                    }
                } else if let issue = model.issueMessage, model.items.isEmpty {
                    FocusedActionSurface(
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .orange
                    ) {
                        Text("お気に入りを読み込めません")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(issue)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                        FocusedActionButton(action: load) {
                            LucideLabel("もう一度試す", icon: "arrow.clockwise")
                        }
                        .padding(.top, 28)
                    }
                } else {
                    favoritesList
                }
            }
            .navigationTitle("お気に入りから追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加（\(model.selectedCount)件）") {
                        Task { await model.importSelected(into: store) }
                    }
                    .disabled(
                        model.selectedCount == 0
                            || model.isImporting
                            || !model.permitsImport
                    )
                }
            }
        }
        .task { await model.load(preview: previewService, plan: store) }
    }

    private var favoritesList: some View {
        List {
            if !model.permitsImport {
                Section {
                    Label(
                        "このプランは現在読み取り専用です。お気に入りの確認だけできます。",
                        systemImage: "lock"
                    )
                }
            }

            if !model.failures.isEmpty {
                Section("追加できなかったサークル") {
                    ForEach(model.failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A selected circle")
                                .font(.headline)
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("選択したサークルを再試行") {
                        Task { await model.importSelected(into: store) }
                    }
                    .disabled(model.isImporting || !model.permitsImport)
                }
            }

            Section {
                if model.missingItems.isEmpty {
                    ContentUnavailableView(
                        "追加できるサークルはありません",
                        systemImage: "checkmark.circle",
                        description: Text("Circle.msのお気に入りはすべてこのプランに含まれています。")
                    )
                } else {
                    ForEach(model.missingItems) { item in
                        Toggle(
                            isOn: Binding(
                                get: { model.selectedWCIDs.contains(item.wcID) },
                                set: { model.setSelected($0, wcID: item.wcID) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.circleName.isEmpty ? String(localized: "Unnamed circle") : item.circleName)
                                if !item.memo.isEmpty {
                                    Text(item.memo)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .accessibilityIdentifier("shared-plan-favorite-import-\(item.wcID)")
                    }
                }
            } header: {
                Text("プランにまだないお気に入り")
            } footer: {
                Text("追加してもCircle.msやComiNaviのお気に入りは変更されません。")
            }

            if !model.existingWCIDs.isEmpty {
                Section("追加済み・登録済み") {
                    Text("\(model.existingWCIDs.count)件は重複せずにスキップしました。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.isImporting {
                ProgressView("サークルを追加中…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func load() {
        Task { await model.load(preview: previewService, plan: store) }
    }
}
