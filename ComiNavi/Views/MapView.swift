//
//  MapView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import SwiftUI

struct MapView: View {
    @StateObject var circle = CirclemsDataSource.shared

    @State var circles: [CirclemsDataSchema.ComiketCircleWC] = []
    @State var background: CirclemsImageSchema.ComiketCommonImage?

    func fetch() {
        Task {
            self.circles = await circle.getCircles()
//            self.background = await circle.getCommonImage(name: "")
        }
    }

    var body: some View {
        // make a zoomable map here. not MapKit, we need to draw everything ourselves
        Text("Map: \(circles.count) circles")
            .onAppear {
                fetch()
            }
    }
}

#Preview {
    MapView()
}
