import SwiftUI

struct ExploreExpandedFilterField<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExploreFilterChoice<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 48, minHeight: 44)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected
                                ? Color.accentColor.opacity(0.8)
                                : Color(uiColor: .separator).opacity(0.45),
                            lineWidth: 1
                        )
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct ExploreFavoriteColorFilter: View {
    @Binding var selection: Set<BookmarkColor>

    var body: some View {
        ExploreExpandedFilterField(title: "Color") {
            ExploreFilterFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(BookmarkColor.selectableColors) { color in
                    let isSelected = selection.contains(color)

                    Button {
                        if isSelected {
                            selection.remove(color)
                        } else {
                            selection.insert(color)
                        }
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 26, height: 26)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Circle()
                                    .stroke(
                                        isSelected
                                            ? Color.primary
                                            : Color(uiColor: .separator).opacity(0.45),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            }
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Color.accentColor, in: .circle)
                                        .overlay {
                                            Circle()
                                                .stroke(
                                                    Color(uiColor: .systemBackground),
                                                    lineWidth: 2
                                                )
                                        }
                                }
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.displayName)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("explore-favorite-color-\(color.rawValue)")
                }
            }
        }
    }
}

struct ExploreFilterFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let sizes = subviews.map { size(for: $0, maxWidth: maxWidth) }
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if currentX > 0, currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            contentWidth = max(contentWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? contentWidth,
            height: currentY + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = size(for: subview, maxWidth: bounds.width)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func size(for subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let intrinsicSize = subview.sizeThatFits(.unspecified)
        guard intrinsicSize.width > maxWidth else { return intrinsicSize }

        return subview.sizeThatFits(
            ProposedViewSize(width: maxWidth, height: nil)
        )
    }
}
