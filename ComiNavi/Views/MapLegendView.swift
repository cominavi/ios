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
                HStack(spacing: 10) {
                    LucideIcon("square.3.layers.3d.top.filled")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Genre overlay")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 12)
                    LucideIcon(isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide genre legend" : "Show genre legend")
            .accessibilityIdentifier("map-legend-toggle")

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                if genres.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading genre colors…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(genres) { genre in
                                GenreLegendRow(genre: genre)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
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
        .frame(maxWidth: 286)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
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
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 4)
                .fill(genreColor.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(genreColor, lineWidth: 1)
                }
                .frame(width: 34, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(genre.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(genre.spaceCount.formatted()) table spaces")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
