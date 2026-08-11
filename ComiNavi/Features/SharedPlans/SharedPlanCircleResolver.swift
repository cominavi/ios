import Foundation

struct SharedPlanResolvedCircle: Equatable, Identifiable, Sendable {
    let key: SharedPlanCircleKey
    let catalogCircleID: Int?

    var id: String { key.id }
    var isStaleInCurrentCatalog: Bool { catalogCircleID == nil }
}

enum SharedPlanCircleResolver {
    /// Resolves current, mutable catalog IDs from stable WCIDs without ever
    /// persisting the catalog-local ID back into Shared Plan identity.
    static func resolve(
        keys: [SharedPlanCircleKey],
        comiketNo: Int,
        catalogIDsByWCID: [Int: Int]
    ) -> [SharedPlanResolvedCircle] {
        keys.map { key in
            SharedPlanResolvedCircle(
                key: key,
                catalogCircleID: key.comiketNo == comiketNo
                    ? catalogIDsByWCID[key.wcID]
                    : nil
            )
        }
    }
}
