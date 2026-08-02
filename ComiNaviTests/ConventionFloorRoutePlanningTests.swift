import XCTest
@testable import ComiNavi

final class ConventionFloorRoutePlanningTests: XCTestCase {
    func testIntersectionDistanceTreatsEveryDirectionEqually() {
        let column = 10
        let row = 20
        let twoBlocksAway = [
            ConventionFloorBlockCoordinate(column: 9, row: 20),
            ConventionFloorBlockCoordinate(column: 12, row: 20),
            ConventionFloorBlockCoordinate(column: 10, row: 19),
            ConventionFloorBlockCoordinate(column: 10, row: 22),
        ]

        XCTAssertEqual(
            twoBlocksAway.map {
                ConventionFloorRoutePlanning.distance(
                    fromIntersectionColumn: column,
                    row: row,
                    to: $0
                )
            },
            [2, 2, 2, 2]
        )
    }

    func testExactTwoBlockDestinationsWinOverCloserAndFartherTables() {
        XCTAssertEqual(
            ConventionFloorRoutePlanning.preferredCandidateIndices(
                for: [1, 2, 3, 2, 4]
            ),
            [1, 3]
        )
    }

    func testPlannerFallsForwardWhenNoTwoBlockDestinationExists() {
        XCTAssertEqual(
            ConventionFloorRoutePlanning.preferredCandidateIndices(
                for: [1, 4, 3, 1, 3]
            ),
            [2, 4]
        )
    }

    func testPlannerUsesAvailableTablesOnAConstrainedMap() {
        XCTAssertEqual(
            ConventionFloorRoutePlanning.preferredCandidateIndices(for: [1, 1]),
            [0, 1]
        )
    }
}
