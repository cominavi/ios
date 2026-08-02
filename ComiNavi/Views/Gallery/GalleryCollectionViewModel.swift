//
//  GalleryCollectionViewModel.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/19/24.
//

import Foundation

@MainActor
final class GalleryCollectionViewModel {
    private let allCircles: [CirclemsDataSchema.ComiketCircleWC]
    private let blocks: [UFDSchema.Block]
    var circleGroups: [CircleBlockGroup] = []
    
    init(circles: [CirclemsDataSchema.ComiketCircleWC], blocks: [UFDSchema.Block]) {
        self.allCircles = circles
        self.blocks = blocks
        self.circleGroups = CircleBlockGroup.from(circles: circles, blocks: blocks)
    }
    
    func setSearchKeyword(_ keyword: String) {
        let keywords = keyword
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }

        guard !keywords.isEmpty else {
            circleGroups = CircleBlockGroup.from(circles: allCircles, blocks: blocks)
            return
        }

        circleGroups = CircleBlockGroup.from(circles: allCircles.filter { circle in
            let searchableText = [circle.penName, circle.circleName, circle.description]
                .compactMap { $0 }
                .joined(separator: "\n")
            return keywords.allSatisfy {
                searchableText.localizedCaseInsensitiveContains($0)
            }
        }, blocks: blocks)
    }
}
