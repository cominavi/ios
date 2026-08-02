import Foundation

enum MapRoutePlanner {
    static func plan(
        bookmarks: [MapBookmark],
        in scene: CatalogMapScene
    ) -> [MapBookmark] {
        let tableByID = Dictionary(uniqueKeysWithValues: scene.tables.map { ($0.id, $0) })
        let eligible = bookmarks.filter { tableByID[$0.tableID] != nil }
        guard eligible.count > 1 else {
            return eligible.enumerated().map { index, bookmark in
                var bookmark = bookmark
                bookmark.routeOrder = index
                return bookmark
            }
        }

        let start = eligible.min { lhs, rhs in
            switch (lhs.routeOrder, rhs.routeOrder) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.modifiedAt < rhs.modifiedAt
            }
        }!

        var remaining = Dictionary(uniqueKeysWithValues: eligible.map { ($0.publicCircleID, $0) })
        remaining[start.publicCircleID] = nil
        var ordered = [start]

        while let current = ordered.last,
              let currentTable = tableByID[current.tableID],
              !remaining.isEmpty
        {
            let currentPoint = CGPoint(
                x: currentTable.origin.x + scene.tableSize.width / 2,
                y: currentTable.origin.y + scene.tableSize.height / 2
            )
            let next = remaining.values.min { lhs, rhs in
                let leftDistance = squaredDistance(
                    from: currentPoint,
                    to: center(of: tableByID[lhs.tableID]!, tableSize: scene.tableSize)
                )
                let rightDistance = squaredDistance(
                    from: currentPoint,
                    to: center(of: tableByID[rhs.tableID]!, tableSize: scene.tableSize)
                )
                if leftDistance == rightDistance {
                    return lhs.publicCircleID < rhs.publicCircleID
                }
                return leftDistance < rightDistance
            }!
            ordered.append(next)
            remaining[next.publicCircleID] = nil
        }

        return ordered.enumerated().map { index, bookmark in
            var bookmark = bookmark
            bookmark.routeOrder = index
            return bookmark
        }
    }

    private static func center(of table: CatalogMapTable, tableSize: CGSize) -> CGPoint {
        CGPoint(
            x: table.origin.x + tableSize.width / 2,
            y: table.origin.y + tableSize.height / 2
        )
    }

    private static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }
}
