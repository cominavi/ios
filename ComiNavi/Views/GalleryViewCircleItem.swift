//
//  GalleryViewCircleItem.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/14/24.
//

import SwiftUI

struct GalleryViewCircleItem: View {
    var circle: CirclemsDataSchema.ComiketCircleWC
    @State var image: Data?

    func fetchImage() {
        Task {
            self.image = await CirclemsDataSource.shared.getCircleImage(circleId: circle.id)
        }
    }

    var body: some View {
        VStack {
            Group {
                if self.image != nil {
                    Image(data: image)?
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.gray
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
            // I know that the image is 211x300. specify the aspect ratio
            .aspectRatio(211 / 300, contentMode: .fit)
            // fill width
            .frame(minWidth: 0, maxWidth: .infinity)
            .shadow(radius: 5)

            Text(circle.circleName ?? "")
                .font(.caption)
                .lineLimit(1)
        }
        .onAppear {
            fetchImage()
        }
    }
}

struct GalleryViewCircleItem_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            GalleryViewCircleItem(circle: CirclemsDataSource.shared.getDemoCircle())
                .padding()
                .frame(width: 200)

            GalleryViewCircleItem(circle: CirclemsDataSource.shared.getDemoCircle())
                .padding()

            GalleryViewCircleItem(circle: CirclemsDataSource.shared.getDemoCircle())
                .padding()
                .frame(width: 100)
        }
        .previewLayout(.sizeThatFits)
    }
}
