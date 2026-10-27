import SwiftUI

/// A stacked capsule progress bar. Every progress bar in the app that is not a
/// plain system `ProgressView` uses this one track, at one height.
///
/// Segments are drawn in order from the back, so list the largest fraction
/// first: `CapsuleProgressBar(segments: [.init(fraction: 0.6, color: .orange),
/// .init(fraction: 0.3, color: .green)])`.
struct CapsuleProgressBar: View {
    struct Segment {
        var fraction: Double
        var color: Color
    }

    let segments: [Segment]
    @ScaledMetric(relativeTo: .body) private var height = 8.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                ForEach(segments.indices, id: \.self) { index in
                    let fraction = min(max(segments[index].fraction, 0), 1)
                    Capsule()
                        .fill(segments[index].color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
