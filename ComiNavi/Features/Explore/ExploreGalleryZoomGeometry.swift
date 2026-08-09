import CoreGraphics
import UIKit

enum ExploreGalleryZoomGeometry {
    static let columnLevels: [CGFloat] = [1, 2, 3, 4, 5]

    static var columnRange: ClosedRange<CGFloat> {
        (columnLevels.first ?? 1)...(columnLevels.last ?? 5)
    }

    static func columns(
        initialColumns: CGFloat,
        magnification: CGFloat
    ) -> CGFloat {
        let safeMagnification = max(magnification, 0.01)
        return min(
            max(initialColumns / safeMagnification, columnRange.lowerBound),
            columnRange.upperBound
        )
    }

    static func nearestColumnLevel(to columns: CGFloat) -> CGFloat {
        columnLevels.min { lhs, rhs in
            abs(lhs - columns) < abs(rhs - columns)
        } ?? columns
    }

    static func preferredInitialColumnCount(for width: CGFloat) -> CGFloat {
        if width >= 1_100 {
            return 4
        }
        if width >= 700 {
            return 3
        }
        return 2
    }

    static func leadingPlaceholderCount(
        aligningItemAtIndex itemIndex: Int,
        with targetColumn: Int,
        columns: Int
    ) -> Int {
        guard columns > 0 else { return 0 }
        let clampedTargetColumn = min(max(targetColumn, 0), columns - 1)
        let currentColumn = itemIndex % columns
        return (clampedTargetColumn - currentColumn + columns) % columns
    }

    static func unitPoint(in frame: CGRect, at contentPoint: CGPoint) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((contentPoint.x - frame.minX) / frame.width, 0), 1),
            y: min(max((contentPoint.y - frame.minY) / frame.height, 0), 1)
        )
    }

    static func anchoredContentOffset(
        itemFrame: CGRect,
        itemUnitPoint: CGPoint,
        viewportPoint: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize,
        adjustedInsets: UIEdgeInsets
    ) -> CGPoint {
        let contentPoint = CGPoint(
            x: itemFrame.minX + itemFrame.width * itemUnitPoint.x,
            y: itemFrame.minY + itemFrame.height * itemUnitPoint.y
        )
        let proposed = CGPoint(
            x: contentPoint.x - viewportPoint.x,
            y: contentPoint.y - viewportPoint.y
        )
        let minimum = CGPoint(x: -adjustedInsets.left, y: -adjustedInsets.top)
        let maximum = CGPoint(
            x: max(minimum.x, contentSize.width - viewportSize.width + adjustedInsets.right),
            y: max(minimum.y, contentSize.height - viewportSize.height + adjustedInsets.bottom)
        )
        return CGPoint(
            x: min(max(proposed.x, minimum.x), maximum.x),
            y: min(max(proposed.y, minimum.y), maximum.y)
        )
    }
}
