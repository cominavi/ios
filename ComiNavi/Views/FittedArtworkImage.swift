import SwiftUI

/// Presents the complete artwork over a subdued edge-to-edge version of itself.
///
/// The explicit container-sized frames are important here: `scaledToFill()` and
/// `scaledToFit()` otherwise retain image-driven ideal sizes when embedded in a
/// UIKit hosting configuration.
struct FittedArtworkImage: View {
    let image: Image

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .saturation(0)
                    .brightness(-0.35)
                    .blur(radius: 12, opaque: true)
                    .scaleEffect(1.12)
                    .accessibilityHidden(true)

                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipped()
    }
}
