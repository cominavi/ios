//
//  GroupedCircles.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

struct CircleBlockGroup {
    var block: UFDSchema.Block
    var circles: [Circle]

    static func from(circles: [Circle]) -> [CircleBlockGroup] {
        var groupedCircles: [CircleBlockGroup] = []

        let blocks: [Int: [Circle]] = Dictionary(grouping: circles, by: { $0.blockId ?? 0 })
        for blockId in blocks.keys.sorted() {
            guard let block = CirclemsDataSource.shared.comiket.blocks.first(where: { $0.externalBlockId == blockId }) else {
                continue
            }

            groupedCircles.append(CircleBlockGroup(block: block, circles: blocks[blockId] ?? []))
        }

        return groupedCircles
    }
}
