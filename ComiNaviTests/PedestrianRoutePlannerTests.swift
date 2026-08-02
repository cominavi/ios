import CoreGraphics
import XCTest
@testable import ComiNavi

final class PedestrianRoutePlannerTests: XCTestCase {
    func testRouteFollowsAuthoredWalkwayInsteadOfDrawingStraightThroughVenue() throws {
        let walkway = BigSightOpenStreetMapFeature(
            id: 1,
            name: "Test aisle",
            kind: .footway,
            coordinates: [
                coordinate(x: 0, y: 0),
                coordinate(x: 0, y: 30),
                coordinate(x: 40, y: 30),
            ],
            level: "1",
            isIndoor: true
        )
        let authoredPoints = walkway.points
        let start = CGPoint(x: authoredPoints[0].x - 3, y: authoredPoints[0].y)
        let destination = CGPoint(x: authoredPoints[2].x, y: authoredPoints[2].y + 4)
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: []),
            venues: [],
            connections: [],
            openStreetMapFeatures: [walkway],
            bounds: CGRect(x: -20, y: -20, width: 100, height: 100)
        )

        let route = PedestrianRoutePlanner.route(from: start, to: destination, in: campus)

        XCTAssertFalse(route.usesFallback)
        XCTAssertEqual(route.points.first, start)
        XCTAssertEqual(route.points.last, destination)
        XCTAssertTrue(route.points.contains { $0.distance(to: authoredPoints[1]) < 0.5 })
        XCTAssertGreaterThan(route.distanceMeters, Int(start.distance(to: destination).rounded()))
    }

    func testMissingWalkwayDataIsExplicitlyMarkedAsFallback() {
        let campus = BigSightCampusScene(
            id: .init(day: 1, mapIDs: []),
            venues: [],
            connections: [],
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        let route = PedestrianRoutePlanner.route(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 40, y: 50),
            in: campus
        )

        XCTAssertTrue(route.usesFallback)
        XCTAssertEqual(route.points, [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 50)])
        XCTAssertEqual(route.distanceMeters, 50)
    }

    private func coordinate(x: CGFloat, y: CGFloat) -> GeographicCoordinate {
        BigSightCampusLayout.coordinate(from: CGPoint(x: x, y: y))
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}
