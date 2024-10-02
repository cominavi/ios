//
//  GalleryViewCircleItem.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/14/24.
//

import SwiftUI

struct GalleryViewCircleItem: View {
    var circle: CirclemsDataSchema.ComiketCircleWC
    @State private var image: Image?

    // save fetch task so we could cancel it if needed
    @State private var fetchTask: Task<Void, Error>?

    func fetchImage() {
        self.fetchTask = Task {
            if let imageData = await AppData.circlems.getCircleImage(circleId: circle.id) {
                self.image = await Image.asyncInit(data: imageData)
            }
            self.fetchTask = nil
        }
    }

    var body: some View {
        Group {
            if let image = image {
                image.resizable()
            } else {
                Color.gray
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        // I know that the image is 211x300. specify the aspect ratio
        .aspectRatio(211 / 300, contentMode: .fit)
        .onAppear {
            fetchImage()
        }
        .onDisappear {
            self.fetchTask?.cancel()
        }
    }
}

struct GalleryViewCircleItem_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            GalleryViewCircleItem(circle: AppData.circlems.getDemoCircle())
                .padding()
                .frame(width: 200)

            GalleryViewCircleItem(circle: AppData.circlems.getDemoCircle())
                .padding()

            GalleryViewCircleItem(circle: AppData.circlems.getDemoCircle())
                .padding()
                .frame(width: 100)
        }
        .previewLayout(.sizeThatFits)
    }
}
