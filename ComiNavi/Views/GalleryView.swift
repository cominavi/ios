//
//  GalleryView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import SwiftUI

struct GalleryView: View {
    @StateObject private var circle = CirclemsDataSource.shared
    @State private var circles: [CirclemsDataSchema.ComiketCircleWC] = []

    func fetch() {
        Task {
            self.circles = await circle.getCircles()
        }
    }

    func circleContextMenu(circle: CirclemsDataSchema.ComiketCircleWC) -> some View {
        return Group {
            Button {
                // Add this item to a list of favorites.
            } label: {
                Label("Add to Favorites", systemImage: "heart")
            }
            Button {
                // Open Maps and center it on this item.
            } label: {
                Label("Show in Maps", systemImage: "mappin")
            }
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
                ], spacing: 4) {
                    ForEach(circles, id: \.id) { circle in
                        let item = GalleryViewCircleItem(circle: circle)

                        NavigationLink(destination: Text(circle.circleName ?? "")) {
                            item
                        }
                        .apply {
                            if #available(iOS 16.0, *) {
                                $0.contextMenu {
                                    circleContextMenu(circle: circle)
                                } preview: {
                                    VStack(alignment: .leading) {
                                        item
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
                                    .frame(width: 300, alignment: .leading)
                                    .padding()
                                }
                            } else {
                                $0.contextMenu {
                                    circleContextMenu(circle: circle)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
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
