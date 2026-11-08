//
//  CirclePreviewView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI

/// The context-menu preview of a circle in the gallery. The gallery hosts it
/// in a fixed 300 × 400 pt preview, so the cut has a capped height and the
/// description has a line limit instead of growing past the preview.
struct CirclePreviewView: View {
    var circle: CirclemsDataSchema.ComiketCircleWC

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            GalleryViewCircleItem(circle: circle)
                .frame(maxHeight: 220)
                .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(circle.circleName ?? "")
                    .font(.rowTitle)

                Text(circle.penName ?? "")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
            .wrapsFully()

            Text(circle.description ?? "")
                .font(.rowSubtitle)
                .multilineTextAlignment(.leading)
                // The preview has a fixed height: wrap, then end with "…".
                .lineLimit(4)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CirclePreviewView_Previews: PreviewProvider {
    static var previews: some View {
//    use AppData.circlems.getDemoCircles() to get a list of demo circles
        ForEach(AppData.circlems.getDemoCircles(), id: \.id) { circle in
            CirclePreviewView(circle: circle)
                .padding()
                .previewLayout(.sizeThatFits)
        }
    }
}
