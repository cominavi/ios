import Foundation
import Observation

struct SharedPlanCirclePurchasePreview: Equatable, Identifiable, Sendable {
    let planID: String
    let need: SharedPlanPurchaseNeed
    let hasConflict: Bool

    var id: String {
        "\(planID):\(need.id.uuidString.lowercased())"
    }
}

struct SharedPlanCirclePurchaseGroup: Equatable, Identifiable, Sendable {
    let planID: String
    let planName: String
    let purchases: [SharedPlanCirclePurchasePreview]

    var id: String { planID }

    init?(
        snapshot: SharedPlanEditorSnapshot,
        circle: SharedPlanCircleKey
    ) {
        guard let content = snapshot.circles.first(where: { $0.key == circle }),
              !content.needs.isEmpty
        else { return nil }

        planID = snapshot.plan.id
        planName = snapshot.plan.name
        purchases = content.needs.map { need in
            SharedPlanCirclePurchasePreview(
                planID: snapshot.plan.id,
                need: need,
                hasConflict: snapshot.conflicts.contains { conflict in
                    conflict.path.contains(need.id.uuidString.lowercased())
                }
            )
        }
    }
}

@MainActor
@Observable
final class SharedPlanCirclePurchasePreviewModel {
    private(set) var groups: [SharedPlanCirclePurchaseGroup] = []

    @ObservationIgnored private var groupsByPlanID:
        [String: SharedPlanCirclePurchaseGroup] = [:]
    @ObservationIgnored private var planOrder: [String] = []
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    func run(
        circle: SharedPlanCircleKey,
        planIDs: [String],
        using service: any SharedPlanEditorServicing
    ) async {
        observationGeneration &+= 1
        let generation = observationGeneration
        planOrder = planIDs
        groupsByPlanID = groupsByPlanID.filter { planIDs.contains($0.key) }
        publishGroups()

        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        guard !planIDs.isEmpty else { return }

        let tasks = planIDs.map { planID in
            Task { @MainActor [weak self] in
                let updates = service.editorProjectionUpdates(planID: planID)
                for await _ in updates {
                    guard let self,
                          !Task.isCancelled,
                          self.observationGeneration == generation
                    else { return }
                    await self.reload(
                        circle: circle,
                        planID: planID,
                        generation: generation,
                        using: service
                    )
                }
            }
        }
        observationTasks = tasks
        await withTaskCancellationHandler {
            for task in tasks {
                await task.value
            }
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    private func reload(
        circle: SharedPlanCircleKey,
        planID: String,
        generation: UInt64,
        using service: any SharedPlanEditorServicing
    ) async {
        do {
            let projection = try await service.editorProjection(planID: planID)
            guard !Task.isCancelled,
                  observationGeneration == generation
            else { return }
            groupsByPlanID[planID] = SharedPlanCirclePurchaseGroup(
                snapshot: projection.snapshot,
                circle: circle
            )
            publishGroups()
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error),
                  !Task.isCancelled,
                  observationGeneration == generation
            else { return }
            groupsByPlanID[planID] = nil
            publishGroups()
        }
    }

    private func publishGroups() {
        let updatedGroups = planOrder.compactMap { groupsByPlanID[$0] }
        if groups != updatedGroups {
            groups = updatedGroups
        }
    }
}
