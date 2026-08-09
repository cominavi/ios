import XCTest

@testable import ComiNavi

final class CatalogCirclePairingTests: XCTestCase {
    func testSameCircleOnBothSidesBecomesOneABGroup() {
        let a = circle(id: 1, side: 0, name: "一年戦争", penName: "武田")
        let b = circle(id: 2, side: 1, name: "一年戦争", penName: "武田")

        let groups = CatalogCirclePairing.groups(circles: [b, a], extensionsByCircleID: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.id), [1, 2])
    }

    func testDifferentCirclesAtTheSameTableRemainIndependent() {
        let a = circle(id: 1, side: 0, name: "Alpha", penName: "A")
        let b = circle(id: 2, side: 1, name: "Beta", penName: "B")

        let groups = CatalogCirclePairing.groups(circles: [a, b], extensionsByCircleID: [:])

        XCTAssertEqual(groups.map { $0.map(\.id) }, [[1], [2]])
    }

    func testSharedPortalIdentityCanPairSpellingVariants() {
        let a = circle(id: 1, side: 0, name: "一年戦争", penName: "武田")
        let b = circle(id: 2, side: 1, name: "一年戦争。", penName: "武田")
        let portal = "https://portal.circle.ms/Circle/Index/10030286"
        let extensions = [
            1: extensionRecord(id: 1, publicID: 10, portal: portal),
            2: extensionRecord(id: 2, publicID: 11, portal: portal + "?from=catalog"),
        ]

        let groups = CatalogCirclePairing.groups(
            circles: [a, b],
            extensionsByCircleID: extensions
        )

        XCTAssertEqual(groups.map { $0.map(\.id) }, [[1, 2]])
    }

    private func circle(
        id: Int,
        side: Int,
        name: String,
        penName: String
    ) -> CirclemsDataSchema.ComiketCircleWC {
        CirclemsDataSchema.ComiketCircleWC(
            comiketNo: 108,
            id: id,
            pageNo: 1,
            cutIndex: id,
            day: 1,
            blockId: 1,
            spaceNo: 1,
            spaceNoSub: side,
            genreId: 1,
            circleName: name,
            circleKana: nil,
            penName: penName,
            bookName: nil,
            url: nil,
            mailAddr: nil,
            description: nil,
            memo: nil,
            updateId: 100 + id,
            updateData: nil,
            circlems: nil,
            rss: nil,
            updateFlag: nil
        )
    }

    private func extensionRecord(
        id: Int,
        publicID: Int,
        portal: String
    ) -> CirclemsDataSchema.ComiketCircleExtend {
        CirclemsDataSchema.ComiketCircleExtend(
            comiketNo: 108,
            id: id,
            WCId: publicID,
            twitterURL: nil,
            pixivURL: nil,
            CirclemsPortalURL: portal
        )
    }
}
