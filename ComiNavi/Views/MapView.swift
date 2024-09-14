//
//  MapView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import SwiftUI

struct MapView: View {
    @State private var background: CirclemsImageSchema.ComiketCommonImage?

    @State private var day: Int = CirclemsDataSource.shared.comiket.days.first?.dayIndex ?? 1
    @State private var area: String = CirclemsDataSource.shared.comiket.days.first?.halls.first?.mapName ?? ""

    @State private var image: Image?

    var halls: [UFDSchema.DayHall] {
        CirclemsDataSource.shared.comiket.days.first(where: { $0.dayIndex == day })?.halls ?? []
    }

    func fetch() {
        Task {
            self.image = nil
            print("Fetching \(day) \(area)")
            let image = await CirclemsDataSource.shared.getFloorMap(layer: .base, day: day, areaFileNameFragment: area)
            if let backgroundData = image?.image {
                self.image = await Image.asyncInit(data: backgroundData)
            }
        }
    }

    var body: some View {
        VStack {
            HStack {
                Picker("Day", selection: $day) {
                    ForEach(CirclemsDataSource.shared.comiket.days, id: \.self) { day in
                        Text("\(day.dayIndex)日目").tag(day.dayIndex)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Hall", selection: $area) {
                    ForEach(halls, id: \.self) { hall in
                        Text(hall.name).tag(hall.mapName)
                    }
                }
                .pickerStyle(.segmented)
            }

            ZoomableScrollView {
                if let image = image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
        }
        .onAppear {
            fetch()
        }
        .onChange(of: day) { _ in
            fetch()
        }
        .onChange(of: area) { _ in
            fetch()
        }
    }
}

#Preview {
    MapView()
}
