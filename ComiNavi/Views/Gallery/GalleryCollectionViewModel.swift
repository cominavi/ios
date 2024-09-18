//
//  GalleryCollectionViewModel.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/19/24.
//

import Foundation

class GalleryCollectionViewModel: ObservableObject {
    var circleGroups: [CircleBlockGroup] = []
    
    init(circles: [CirclemsDataSchema.ComiketCircleWC]) {
        self.circleGroups = CircleBlockGroup.from(circles: circles)
    }
    
    func setSearchKeyword(_ keyword: String) {
        self.circleGroups = CircleBlockGroup.from(circles: CirclemsDataSource.shared.searchCircles(keyword))
    }
}
