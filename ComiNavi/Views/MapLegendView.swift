import SwiftUI

struct MapLegendView: View {
    let genrePlacements: [CatalogMapGenrePlacement]
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var genres: [GenreLegendEntry] {
        Dictionary(grouping: genrePlacements, by: \.genreID)
            .compactMap { genreID, placements in
                guard let placement = placements.first else { return nil }
                return GenreLegendEntry(
                    id: genreID,
                    name: placement.genreName,
                    spaceCount: placements.count
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.smooth(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: Spacing.small) {
                    // The same glyph as the genre button in the top chrome.
                    LucideIcon("paintbrush", size: IconSize.inline)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Genre overlay")
                        .font(.control)
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                    Spacer(minLength: Spacing.medium)
                    LucideIcon(isExpanded ? "chevron.down" : "chevron.up", size: IconSize.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.large)
                .frame(minHeight: HitArea.minimum)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide genre legend" : "Show genre legend")
            .accessibilityIdentifier("map-legend-toggle")

            if isExpanded {
                Divider()
                    .padding(.horizontal, Spacing.large)

                if genres.isEmpty {
                    HStack(spacing: Spacing.small) {
                        ProgressView()
                        Text("Loading genre colors…")
                            .font(.meta)
                            .foregroundStyle(.secondary)
                            .wrapsFully()
                    }
                    .padding(Spacing.large)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.small) {
                            ForEach(genres) { genre in
                                GenreLegendRow(genre: genre)
                            }
                        }
                        .padding(.horizontal, Spacing.large)
                        .padding(.vertical, Spacing.medium)
                    }
                    .frame(maxHeight: 260)
                    .clipped()
                    .scrollIndicators(.visible)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Genre colors")
                    .accessibilityIdentifier("map-legend-items")
                }
            }
        }
        .frame(maxWidth: ReadableWidth.floatingCard)
        .clipShape(.rect(cornerRadius: Radius.panel, style: .continuous))
        .mapChromeSurface(.panel)
    }
}

private struct GenreLegendEntry: Identifiable {
    let id: Int
    let name: String
    let spaceCount: Int
}

private struct GenreLegendRow: View {
    let genre: GenreLegendEntry

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            RoundedRectangle(cornerRadius: Radius.xSmall, style: .continuous)
                .fill(genreColor.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.xSmall, style: .continuous)
                        .strokeBorder(genreColor, lineWidth: 1)
                }
                // 34 × 24 pt: the swatch keeps the proportion of a table
                // on the map.
                .frame(width: 34, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(genre.name)
                    .font(.meta.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(genre.spaceCount) table spaces")
                    .font(.badge)
                    .foregroundStyle(.secondary)
            }
            .wrapsFully()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(genre.name), \(genre.spaceCount) table spaces")
    }

    private var genreColor: Color {
        Color(
            hue: Double((genre.id * 67) % 360) / 360,
            saturation: 0.58,
            brightness: 0.92
        )
    }
}
