//
//  CirclePreviewView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI

struct CirclePreviewView: View {
    var circle: CirclemsDataSchema.ComiketCircleWC

    var body: some View {
        VStack(alignment: .leading) {
            GalleryViewCircleItem(circle: circle)
                .frame(width: 250, height: 250, alignment: .leading)

            Text(circle.circleName ?? "")
                .font(.title)
                .bold()

            Text(circle.penName ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(circle.description ?? "")
                .font(.body)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
        }
    }
}

struct CirclePreviewView_Previews: PreviewProvider {
    static var previews: some View {
//    use CirclemsDataSource.shared.getDemoCircles() to get a list of demo circles
        ForEach(CirclemsDataSource.shared.getDemoCircles(), id: \.id) { circle in
            CirclePreviewView(circle: circle)
                .padding()
                .previewLayout(.sizeThatFits)
        }
    }
}
