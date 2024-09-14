//
//  GalleryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import SwiftUI

struct GalleryView: View {
    @StateObject var circle = CirclemsDataSource.shared

    @State var circles: [CirclemsDataSchema.ComiketCircleWC] = []

    func fetch() {
        Task {
            self.circles = await circle.getCircles()
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 50), spacing: 4),
                    GridItem(.adaptive(minimum: 50), spacing: 4),
                    GridItem(.adaptive(minimum: 50), spacing: 4),
                    GridItem(.adaptive(minimum: 50), spacing: 4),
                    GridItem(.adaptive(minimum: 50), spacing: 4),
                    GridItem(.adaptive(minimum: 50), spacing: 4)
                ]) {
                    ForEach(circles, id: \.id) { circle in
                        NavigationLink(destination: Text(circle.circleName ?? "")) {
                            GalleryViewCircleItem(circle: circle)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Circles")
        }
        .onAppear {
            fetch()
        }
    }
}

#Preview {
    GalleryView()
}
