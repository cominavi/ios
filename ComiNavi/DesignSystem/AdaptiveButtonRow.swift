import SwiftUI

/// Lays out buttons side by side at equal widths, or stacks them at full width
/// when the widest title does not fit on one line in an equal share.
///
/// `ViewThatFits` with an `HStack` is not enough for equal-width buttons: the
/// row fits by total width, so a long title such as "Add to shared plan" still
/// wraps in its half while a short sibling stays on one line. This layout
/// compares the widest ideal width with the equal share instead.
///
/// ```swift
/// AdaptiveButtonRow {
///     Button("Favorite") { … }.buttonStyle(.primaryAction)
///     Button("Add to shared plan") { … }.buttonStyle(.secondaryAction)
/// }
/// ```
struct AdaptiveButtonRow: Layout {
    var spacing: CGFloat = Spacing.medium

    init(spacing: CGFloat = Spacing.medium) {
        self.spacing = spacing
    }

    struct Cache {
        var widestIdealWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(widestIdealWidth: subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let isHorizontal = fitsHorizontally(width: proposal.width, subviews: subviews, cache: cache)
        if isHorizontal {
            let share = shareWidth(total: proposal.width, subviews: subviews, cache: cache)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: nil)).height }.max() ?? 0
            return CGSize(width: share * CGFloat(subviews.count) + totalSpacing(subviews), height: height)
        } else {
            let width = proposal.width ?? cache.widestIdealWidth
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + totalSpacing(subviews))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard !subviews.isEmpty else { return }
        if fitsHorizontally(width: bounds.width, subviews: subviews, cache: cache) {
            let share = (bounds.width - totalSpacing(subviews)) / CGFloat(subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: nil)).height }.max() ?? 0
            var x = bounds.minX
            for subview in subviews {
                // Every button gets the row height, so a sibling never looks shorter.
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: share, height: height)
                )
                x += share + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let proposal = ProposedViewSize(width: bounds.width, height: nil)
                let height = subview.sizeThatFits(proposal).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }

    private func totalSpacing(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func shareWidth(total: CGFloat?, subviews: Subviews, cache: Cache) -> CGFloat {
        guard let total else { return cache.widestIdealWidth }
        return (total - totalSpacing(subviews)) / CGFloat(subviews.count)
    }

    private func fitsHorizontally(width: CGFloat?, subviews: Subviews, cache: Cache) -> Bool {
        guard let width else { return true }
        return shareWidth(total: width, subviews: subviews, cache: cache) >= cache.widestIdealWidth
    }
}
