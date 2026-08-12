import SwiftUI

struct SharedPlanCircleQuickAddSheet: View {
    let store: SharedPlanStore
    let currentUserID: String
    let circle: SharedPlanCircleKey
    let circleName: String
    let penName: String?
    let onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlanID: String?
    @State private var editorModel: SharedPlanEditorModel?
    @State private var itemName = ""
    @State private var rawUnitPrice = ""
    @State private var wantedQuantity = 1
    @State private var isLoadingPlans = true
    @State private var isSubmitting = false
    @State private var issueMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case itemName, price }

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingPlans {
                    ProgressView("Loading your plans…")
                } else if eligiblePlans.isEmpty {
                    ContentUnavailableView(
                        "No writable plan for this Comiket",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Create or join an active plan first, then return to this circle.")
                    )
                } else {
                    form
                }
            }
            .navigationTitle("Add purchase request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !eligiblePlans.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { submit() }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("circle-shared-plan-request-submit")
                    }
                }
            }
        }
        .task {
            await store.load()
            await store.refresh()
            let storedPrimaryPlanID = SharedPlanPrimaryPlanPreference().planID(
                userID: currentUserID,
                comiketNo: circle.comiketNo
            )
            selectedPlanID = SharedPlanPrimaryPlanPreference.validPlanID(
                storedPrimaryPlanID,
                among: eligiblePlans
            ) ?? eligiblePlans.first?.id
            isLoadingPlans = false
            focusedField = .itemName
        }
        .task(id: selectedPlanID) {
            guard let selectedPlanID else {
                editorModel = nil
                return
            }
            let model = SharedPlanEditorModel(planID: selectedPlanID)
            editorModel = model
            await model.run(using: store)
        }
        .alert(
            "Purchase request could not be added",
            isPresented: Binding(
                get: { issueMessage != nil },
                set: { if !$0 { issueMessage = nil } }
            )
        ) {
            Button("OK") { issueMessage = nil }
        } message: {
            Text(issueMessage ?? String(localized: "Please try again."))
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var form: some View {
        Form {
            Section("Plan") {
                if eligiblePlans.count == 1, let plan = eligiblePlans.first {
                    LabeledContent("Add to", value: plan.name)
                } else {
                    Picker("Add to", selection: $selectedPlanID) {
                        ForEach(eligiblePlans) { plan in
                            Text(plan.name).tag(Optional(plan.id))
                        }
                    }
                    .accessibilityIdentifier("circle-shared-plan-request-plan")
                }
                LabeledContent("Circle") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(circleName)
                        if let penName, !penName.isEmpty {
                            Text(penName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                TextField(
                    "Item name",
                    text: $itemName,
                    prompt: Text("For example: new-release set, new release only, or acrylic keychain")
                )
                .focused($focusedField, equals: .itemName)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("circle-shared-plan-request-item-name")

                SharedPlanPurchaseItemPresetRow { selectedItemName in
                    itemName = selectedItemName
                    focusedField = .itemName
                }

                Stepper("Quantity: \(wantedQuantity)", value: $wantedQuantity, in: 1...999)
                    .accessibilityIdentifier("circle-shared-plan-request-quantity")

                TextField(
                    "Price per item (optional)",
                    text: $rawUnitPrice,
                    prompt: Text("Yen")
                )
                .focused($focusedField, equals: .price)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("circle-shared-plan-request-price")
            } header: {
                Text("What to buy")
            } footer: {
                Text("The person creating this request can add an estimated whole-yen price.")
            }

            if let editorModel, !editorModel.canEdit {
                Section {
                    Label("Waiting for the plan to finish connecting", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var eligiblePlans: [SharedPlan] {
        store.plans.filter {
            $0.comiketNo == circle.comiketNo
                && $0.lifecycle == .active
                && ($0.role == .owner || $0.role == .editor)
        }
    }

    private var normalizedItemName: String {
        itemName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var unitPrice: Int? {
        let value = rawUnitPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Int(value)
    }

    private var hasValidPrice: Bool {
        let value = rawUnitPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || unitPrice.map { (0...9_999_999).contains($0) } == true
    }

    private var canSubmit: Bool {
        !isSubmitting
            && editorModel?.canEdit == true
            && (1...80).contains(normalizedItemName.count)
            && normalizedItemName.utf8.count <= 512
            && hasValidPrice
    }

    private func submit() {
        guard canSubmit, let editorModel else { return }
        isSubmitting = true
        Task {
            if editorModel.circleContent(for: circle)?.presence != .present {
                await editorModel.setCirclePresence(.active, circle: circle, using: store)
            }
            if editorModel.issueMessage == nil {
                await editorModel.createNeed(
                    requesterUserID: currentUserID,
                    itemName: normalizedItemName,
                    unitPrice: unitPrice,
                    wantedQuantity: wantedQuantity,
                    circle: circle,
                    using: store
                )
            }
            isSubmitting = false
            if let issue = editorModel.issueMessage {
                issueMessage = issue
            } else {
                onAdded(editorModel.plan?.name ?? String(localized: "Shared Plan"))
                dismiss()
            }
        }
    }
}
