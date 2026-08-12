import Foundation
import Observation

@MainActor
protocol SharedPlanCircleImporting: AnyObject {
    func editorSnapshot(planID: String) async throws -> SharedPlanEditorSnapshot
    func addCircle(
        _ key: SharedPlanCircleKey,
        to planID: String,
        now: Date
    ) async throws -> Bool
}

extension SharedPlanStore: SharedPlanCircleImporting {}

struct SharedPlanFavoriteImportFailure: Equatable, Identifiable, Sendable {
    let wcID: Int
    let message: String

    var id: Int { wcID }
}

@MainActor
@Observable
final class SharedPlanFavoriteImportModel {
    let planID: String
    let eventNumber: Int
    let features: SharedPlanPresentationFeatures

    private(set) var items: [CirclemsFavoriteImportItem] = []
    private(set) var existingWCIDs: Set<Int> = []
    private(set) var selectedWCIDs: Set<Int> = []
    private(set) var importedWCIDs: Set<Int> = []
    private(set) var failures: [SharedPlanFavoriteImportFailure] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var issueMessage: String?
    private(set) var permitsImport = false

    init(
        planID: String,
        eventNumber: Int,
        features: SharedPlanPresentationFeatures = .production
    ) {
        self.planID = planID
        self.eventNumber = eventNumber
        self.features = features
    }

    var missingItems: [CirclemsFavoriteImportItem] {
        items.filter { !existingWCIDs.contains($0.wcID) }
    }

    var selectedCount: Int { selectedWCIDs.count }

    func load(
        preview: any CirclemsFavoriteImportServicing,
        plan: any SharedPlanCircleImporting
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await plan.editorSnapshot(planID: planID)
            guard snapshot.plan.comiketNo == eventNumber else {
                throw SharedPlanError.eventMismatch(
                    expected: snapshot.plan.comiketNo,
                    received: eventNumber
                )
            }
            existingWCIDs = Set(snapshot.circles.map(\.key.wcID))
            permitsImport = features.writesEnabled
                && snapshot.plan.lifecycle == .active
                && snapshot.plan.role != .viewer
                && snapshot.permitsContentMutations

            var cursor: String?
            var loaded: [Int: CirclemsFavoriteImportItem] = [:]
            var seenCursors: Set<String> = []
            repeat {
                let page = try await preview.circlemsFavoriteImportPage(
                    eventNumber: eventNumber,
                    cursor: cursor
                )
                guard page.eventNumber == eventNumber else {
                    throw CominaviServiceError.invalidResponse
                }
                for item in page.items { loaded[item.wcID] = item }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw CominaviServiceError.invalidResponse
                }
                guard seenCursors.count <= 100 else {
                    throw CominaviServiceError.invalidResponse
                }
            } while cursor != nil

            items = loaded.values.sorted { left, right in
                if left.circleName == right.circleName { return left.wcID < right.wcID }
                return left.circleName.localizedStandardCompare(right.circleName)
                    == .orderedAscending
            }
            selectedWCIDs = Set(missingItems.map(\.wcID))
            failures = []
            issueMessage = nil
        } catch {
            guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                return
            }
            issueMessage = error.localizedDescription
        }
    }

    func setSelected(_ selected: Bool, wcID: Int) {
        guard missingItems.contains(where: { $0.wcID == wcID }) else { return }
        if selected {
            selectedWCIDs.insert(wcID)
        } else {
            selectedWCIDs.remove(wcID)
        }
    }

    func importSelected(
        into plan: any SharedPlanCircleImporting,
        now: Date = Date()
    ) async {
        guard permitsImport, !isImporting else {
            issueMessage = String(localized: "Shared Plan changes are currently read-only.")
            return
        }
        isImporting = true
        defer { isImporting = false }
        var nextFailures: [SharedPlanFavoriteImportFailure] = []
        for item in missingItems where selectedWCIDs.contains(item.wcID) {
            guard let key = SharedPlanCircleKey(comiketNo: eventNumber, wcID: item.wcID) else {
                continue
            }
            do {
                _ = try await plan.addCircle(key, to: planID, now: now)
                importedWCIDs.insert(item.wcID)
                existingWCIDs.insert(item.wcID)
                selectedWCIDs.remove(item.wcID)
            } catch {
                guard !SharedPlanErrorHandling.isCancellation(error), !Task.isCancelled else {
                    return
                }
                nextFailures.append(
                    SharedPlanFavoriteImportFailure(
                        wcID: item.wcID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        failures = nextFailures
        issueMessage = nextFailures.isEmpty
            ? nil
            : String(localized: "Some favorites could not be imported. You can retry them.")
    }
}
