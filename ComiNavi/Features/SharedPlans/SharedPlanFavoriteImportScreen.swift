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
                    EmptyStateView(
                        "Checking favorites…",
                        icon: "star",
                        message: "ComiNavi is looking in Circle.ms for circles that are not in this plan yet."
                    ) {
                        CatalogActivityIndicator(
                            accessibilityLabel: "Checking Circle.ms favorites…"
                        )
                    }
                } else if let issue = model.issueMessage, model.items.isEmpty {
                    EmptyStateView("Cannot load favorites", icon: "triangle-alert") {
                        Text(issue)
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .wrapsFully()
                        Button(action: load) {
                            LucideLabel("Try Again", icon: "arrow.clockwise")
                        }
                        .buttonStyle(.primaryAction)
                    }
                } else {
                    favoritesList
                }
            }
            .navigationTitle("Add from Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(model.selectedCount))") {
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
                        "This plan is read-only right now. You can only view your favorites.",
                        systemImage: "lock"
                    )
                }
            }

            if !model.failures.isEmpty {
                Section("Circles not added") {
                    ForEach(model.failures) { failure in
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text("A selected circle")
                                .font(.rowTitle)
                            Text(failure.message)
                                .font(.meta)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Retry selected circles") {
                        Task { await model.importSelected(into: store) }
                    }
                    .disabled(model.isImporting || !model.permitsImport)
                }
            }

            Section {
                if model.missingItems.isEmpty {
                    ContentUnavailableView(
                        "No circles to add",
                        systemImage: "checkmark.circle",
                        description: Text("All of your Circle.ms favorites are already in this plan.")
                    )
                } else {
                    ForEach(model.missingItems) { item in
                        Toggle(
                            isOn: Binding(
                                get: { model.selectedWCIDs.contains(item.wcID) },
                                set: { model.setSelected($0, wcID: item.wcID) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                Text(item.circleName.isEmpty ? String(localized: "Unnamed circle") : item.circleName)
                                if !item.memo.isEmpty {
                                    Text(item.memo)
                                        .font(.meta)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .accessibilityIdentifier("shared-plan-favorite-import-\(item.wcID)")
                    }
                }
            } header: {
                Text("Favorites not in this plan")
            } footer: {
                Text("Adding circles here does not change your Circle.ms or ComiNavi favorites.")
            }

            if !model.existingWCIDs.isEmpty {
                Section("Already in this plan") {
                    Text("Skipped \(model.existingWCIDs.count) circles that are already in this plan.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.isImporting {
                ProgressView("Adding circles…")
                    .surface(.floating, padding: Spacing.large)
            }
        }
    }

    private func load() {
        Task { await model.load(preview: previewService, plan: store) }
    }
}
