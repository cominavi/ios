import CoreGraphics
import Foundation

struct BigSightNavigationRoute: Equatable, Sendable {
    let points: [CGPoint]
    let distanceMeters: Int
    let usesFallback: Bool

    var estimatedWalkingMinutes: Int {
        max(1, Int(ceil(Double(distanceMeters) / 70)))
    }
}

enum PedestrianRoutePlanner {
    private enum NodeKey: Hashable {
        private static let precision: CGFloat = 4

        case osm(Int64)
        case coordinate(x: Int64, y: Int64)

        static func coordinate(_ point: CGPoint) -> Self {
            .coordinate(
                x: Int64((point.x * precision).rounded()),
                y: Int64((point.y * precision).rounded())
            )
        }
    }

    private struct Edge {
        let destination: Int
        let cost: CGFloat
    }

    private struct Segment {
        let start: Int
        let end: Int
        let multiplier: CGFloat
    }

    private struct Attachment {
        let node: Int
        let segmentIndex: Int
        let progress: CGFloat
    }

    private struct Graph {
        var points: [CGPoint] = []
        var edges: [[Edge]] = []
        var nodeByKey: [NodeKey: Int] = [:]
        var segments: [Segment] = []

        mutating func addLine(
            _ line: [CGPoint],
            nodeIDs: [Int64]? = nil,
            multiplier: CGFloat
        ) {
            guard line.count > 1 else { return }
            for index in 0 ..< line.count - 1 {
                let startPoint = line[index]
                let endPoint = line[index + 1]
                guard startPoint != endPoint else { continue }
                let startNodeID = nodeIDs.flatMap { ids in
                    ids.indices.contains(index) ? ids[index] : nil
                }
                let endNodeID = nodeIDs.flatMap { ids in
                    ids.indices.contains(index + 1) ? ids[index + 1] : nil
                }
                let start = addNode(startPoint, nodeID: startNodeID)
                let end = addNode(endPoint, nodeID: endNodeID)
                let distance = startPoint.distance(to: endPoint)
                connect(start, end, cost: distance * multiplier)
                segments.append(Segment(start: start, end: end, multiplier: multiplier))
            }
        }

        mutating func attach(_ point: CGPoint, maximumCandidates: Int = 3) -> (Int, [Attachment]) {
            let attachmentNode = addNode(point)
            let rankedCandidates = segments.enumerated().map { index, segment in
                let start = points[segment.start]
                let end = points[segment.end]
                let projection = point.projected(ontoSegmentFrom: start, to: end)
                return (
                    index: index,
                    segment: segment,
                    projection: projection.point,
                    progress: projection.progress,
                    distance: point.distance(to: projection.point)
                )
            }
            .sorted { $0.distance < $1.distance }
            guard let nearestDistance = rankedCandidates.first?.distance else {
                return (attachmentNode, [])
            }
            let candidates = rankedCandidates
                .lazy
                .filter { $0.distance <= nearestDistance + 3 }
                .prefix(maximumCandidates)

            var attachments: [Attachment] = []
            for candidate in candidates {
                let projectionNode = addNode(candidate.projection)
                connect(attachmentNode, projectionNode, cost: candidate.distance)

                let start = points[candidate.segment.start]
                let end = points[candidate.segment.end]
                connect(
                    projectionNode,
                    candidate.segment.start,
                    cost: candidate.projection.distance(to: start) * candidate.segment.multiplier
                )
                connect(
                    projectionNode,
                    candidate.segment.end,
                    cost: candidate.projection.distance(to: end) * candidate.segment.multiplier
                )
                attachments.append(Attachment(
                    node: projectionNode,
                    segmentIndex: candidate.index,
                    progress: candidate.progress
                ))
            }
            return (attachmentNode, attachments)
        }

        mutating func connectSharedSegments(_ lhs: [Attachment], _ rhs: [Attachment]) {
            for start in lhs {
                for end in rhs where start.segmentIndex == end.segmentIndex {
                    let segment = segments[start.segmentIndex]
                    let length = points[segment.start].distance(to: points[segment.end])
                    connect(
                        start.node,
                        end.node,
                        cost: abs(start.progress - end.progress) * length * segment.multiplier
                    )
                }
            }
        }

        mutating func addNode(_ point: CGPoint, nodeID: Int64? = nil) -> Int {
            let key = nodeID.map(NodeKey.osm) ?? NodeKey.coordinate(point)
            if let existing = nodeByKey[key] { return existing }
            let index = points.count
            points.append(point)
            edges.append([])
            nodeByKey[key] = index
            return index
        }

        mutating func connect(_ lhs: Int, _ rhs: Int, cost: CGFloat) {
            guard lhs != rhs, cost.isFinite else { return }
            edges[lhs].append(Edge(destination: rhs, cost: cost))
            edges[rhs].append(Edge(destination: lhs, cost: cost))
        }
    }

    static func route(
        from user: LocatedMapUser,
        to destination: MapNavigationDestination,
        in campus: BigSightCampusScene
    ) -> BigSightNavigationRoute? {
        guard let originVenue = campus.venues.first(where: { $0.id == user.sceneID.mapID }),
              let destinationVenue = campus.venues.first(where: { $0.id == destination.sceneID.mapID })
        else { return nil }

        return route(
            from: user.point.applying(originVenue.transform),
            to: destination.point.applying(destinationVenue.transform),
            in: campus
        )
    }

    static func route(
        from start: CGPoint,
        to destination: CGPoint,
        in campus: BigSightCampusScene
    ) -> BigSightNavigationRoute {
        var graph = Graph()
        for feature in campus.openStreetMapFeatures {
            switch feature.kind {
            case .footway:
                graph.addLine(feature.points, nodeIDs: feature.nodeIDs, multiplier: 1)
            case .steps:
                graph.addLine(feature.points, nodeIDs: feature.nodeIDs, multiplier: 1.18)
            case .connectingBridge:
                continue
            }
        }

        guard !graph.segments.isEmpty else {
            return fallbackRoute(from: start, to: destination)
        }

        let startAttachment = graph.attach(start)
        let destinationAttachment = graph.attach(destination)
        graph.connectSharedSegments(startAttachment.1, destinationAttachment.1)

        guard let indices = shortestPath(
            from: startAttachment.0,
            to: destinationAttachment.0,
            points: graph.points,
            edges: graph.edges
        ) else {
            return fallbackRoute(from: start, to: destination)
        }

        let points = simplify(indices.map { graph.points[$0] })
        return BigSightNavigationRoute(
            points: points,
            distanceMeters: Int(polylineDistance(points).rounded()),
            usesFallback: false
        )
    }

    private static func shortestPath(
        from start: Int,
        to destination: Int,
        points: [CGPoint],
        edges: [[Edge]]
    ) -> [Int]? {
        var distances = Array(repeating: CGFloat.infinity, count: points.count)
        var previous = Array<Int?>(repeating: nil, count: points.count)
        var unvisited = Set(points.indices)
        distances[start] = 0

        while let current = unvisited.min(by: { distances[$0] < distances[$1] }) {
            guard distances[current].isFinite else { break }
            unvisited.remove(current)
            if current == destination { break }

            for edge in edges[current] where unvisited.contains(edge.destination) {
                let candidate = distances[current] + edge.cost
                if candidate < distances[edge.destination] {
                    distances[edge.destination] = candidate
                    previous[edge.destination] = current
                }
            }
        }

        guard distances[destination].isFinite else { return nil }
        var path = [destination]
        while let predecessor = previous[path.last!] {
            path.append(predecessor)
        }
        return path.reversed()
    }

    private static func fallbackRoute(from start: CGPoint, to destination: CGPoint) -> BigSightNavigationRoute {
        BigSightNavigationRoute(
            points: [start, destination],
            distanceMeters: Int(start.distance(to: destination).rounded()),
            usesFallback: true
        )
    }

    private static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for index in 1 ..< points.count - 1 {
            let previous = result.last!
            let current = points[index]
            let next = points[index + 1]
            let first = CGVector(dx: current.x - previous.x, dy: current.y - previous.y)
            let second = CGVector(dx: next.x - current.x, dy: next.y - current.y)
            let cross = abs(first.dx * second.dy - first.dy * second.dx)
            if cross > 0.02 { result.append(current) }
        }
        result.append(points.last!)
        return result
    }

    private static func polylineDistance(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.distance(to: pair.1)
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func projected(ontoSegmentFrom start: CGPoint, to end: CGPoint) -> (point: CGPoint, progress: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (start, 0) }
        let progress = max(0, min(1, ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared))
        return (
            CGPoint(x: start.x + progress * dx, y: start.y + progress * dy),
            progress
        )
    }
}
