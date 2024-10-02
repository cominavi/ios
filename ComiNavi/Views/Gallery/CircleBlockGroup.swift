//
//  GroupedCircles.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation

struct UnifiedCircle {
    var circle: CirclemsDataSchema.ComiketCircleWC
    var trailingItemMergable: Bool
    var selfBeenMerged: Bool
}

struct CircleBlockGroup {
    var block: UFDSchema.Block
    var unifiedCircles: [UnifiedCircle]

    static func from(circles: [CirclemsDataSchema.ComiketCircleWC]) -> [CircleBlockGroup] {
        var groupedCircles: [CircleBlockGroup] = []

        let blocks: [Int: [CirclemsDataSchema.ComiketCircleWC]] = Dictionary(grouping: circles, by: { $0.blockId ?? 0 })
        for blockId in blocks.keys.sorted() {
            guard let block = AppData.circlems.comiket.blocks.first(where: { $0.externalBlockId == blockId }) else {
                continue
            }

            let circles = blocks[blockId] ?? []
            var unifiedCircles: [UnifiedCircle] = []
            var markNextMergable = false
            for i in 0 ..< circles.count {
                let current = circles[i]
                if markNextMergable {
                    markNextMergable = false
                    unifiedCircles.append(UnifiedCircle(circle: current, trailingItemMergable: false, selfBeenMerged: true))
                    continue
                }

                let next = circles[safe: i + 1]
                if current.sameCircle(as: next) {
                    markNextMergable = true
                }
                unifiedCircles.append(UnifiedCircle(circle: current, trailingItemMergable: markNextMergable, selfBeenMerged: false))
            }

            groupedCircles.append(CircleBlockGroup(block: block, unifiedCircles: unifiedCircles))
        }

        return groupedCircles
    }
}
