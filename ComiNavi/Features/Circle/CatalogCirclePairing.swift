import Foundation

enum CatalogCirclePairing {
    static func groups(
        circles: [CirclemsDataSchema.ComiketCircleWC],
        extensionsByCircleID: [Int: CirclemsDataSchema.ComiketCircleExtend]
    ) -> [[CirclemsDataSchema.ComiketCircleWC]] {
        let placementGroups = Dictionary(grouping: circles, by: PlacementKey.init(circle:))
        return placementGroups.values.flatMap { placedCircles in
            let ordered = placedCircles.sorted(by: catalogOrder)
            guard ordered.count == 2,
                  ordered.compactMap(\.spaceNoSub) == [0, 1],
                  sameIdentity(
                      ordered[0],
                      ordered[1],
                      lhsExtension: extensionsByCircleID[ordered[0].id],
                      rhsExtension: extensionsByCircleID[ordered[1].id]
                  )
            else {
                return ordered.map { [$0] }
            }
            return [ordered]
        }
        .sorted { lhs, rhs in
            guard let lhs = lhs.first, let rhs = rhs.first else { return !lhs.isEmpty }
            return catalogOrder(lhs, rhs)
        }
    }

    static func sameIdentity(
        _ lhs: CirclemsDataSchema.ComiketCircleWC,
        _ rhs: CirclemsDataSchema.ComiketCircleWC,
        lhsExtension: CirclemsDataSchema.ComiketCircleExtend? = nil,
        rhsExtension: CirclemsDataSchema.ComiketCircleExtend? = nil
    ) -> Bool {
        guard let day = lhs.day, day > 0, rhs.day == day,
              let blockID = lhs.blockId, blockID > 0, rhs.blockId == blockID,
              let spaceNumber = lhs.spaceNo, spaceNumber > 0, rhs.spaceNo == spaceNumber,
              let lhsSubspace = lhs.spaceNoSub,
              let rhsSubspace = rhs.spaceNoSub,
              Set([lhsSubspace, rhsSubspace]) == Set([0, 1])
        else { return false }

        let lhsPortal = normalizedPortal(lhsExtension?.CirclemsPortalURL)
        let rhsPortal = normalizedPortal(rhsExtension?.CirclemsPortalURL)
        if let lhsPortal, lhsPortal == rhsPortal { return true }

        let lhsName = normalizedIdentity(lhs.circleName)
        let rhsName = normalizedIdentity(rhs.circleName)
        guard !lhsName.isEmpty, lhsName == rhsName else { return false }
        return normalizedIdentity(lhs.penName) == normalizedIdentity(rhs.penName)
    }

    static func sameIdentity(_ lhs: CatalogMapCircle, _ rhs: CatalogMapCircle) -> Bool {
        guard Set([lhs.subspace, rhs.subspace]) == Set([0, 1]) else { return false }
        if let lhsPortal = normalizedPortal(lhs.circlemsPortalURL?.absoluteString),
           lhsPortal == normalizedPortal(rhs.circlemsPortalURL?.absoluteString)
        {
            return true
        }
        let lhsName = normalizedIdentity(lhs.circleName)
        return !lhsName.isEmpty
            && lhsName == normalizedIdentity(rhs.circleName)
            && normalizedIdentity(lhs.penName) == normalizedIdentity(rhs.penName)
    }

    private struct PlacementKey: Hashable {
        let day: Int
        let blockID: Int
        let spaceNumber: Int

        init(circle: CirclemsDataSchema.ComiketCircleWC) {
            day = circle.day ?? 0
            blockID = circle.blockId ?? 0
            spaceNumber = circle.spaceNo ?? 0
        }
    }

    private static func normalizedPortal(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              var components = URLComponents(string: value)
        else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        let normalized = components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized?.lowercased()
    }

    private static func normalizedIdentity(_ value: String?) -> String {
        JapaneseSearchNormalizer.normalize(
            value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private static func catalogOrder(
        _ lhs: CirclemsDataSchema.ComiketCircleWC,
        _ rhs: CirclemsDataSchema.ComiketCircleWC
    ) -> Bool {
        let lhsKey = [
            lhs.day ?? 0,
            lhs.blockId ?? 0,
            lhs.spaceNo ?? 0,
            lhs.spaceNoSub ?? 0,
            lhs.id,
        ]
        let rhsKey = [
            rhs.day ?? 0,
            rhs.blockId ?? 0,
            rhs.spaceNo ?? 0,
            rhs.spaceNoSub ?? 0,
            rhs.id,
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
}
