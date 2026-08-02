import Foundation

enum BigSightPedestrianWayCatalog {
    private struct Collection: Decodable {
        let features: [Feature]
    }

    private struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }

    private struct Properties: Decodable {
        let osmID: Int64
        let kind: String
        let level: String?
        let indoor: Bool
        let covered: Bool
        let name: String?
        let nodeRefs: [Int64]?

        enum CodingKeys: String, CodingKey {
            case osmID = "osm_id"
            case kind
            case level
            case indoor
            case covered
            case name
            case nodeRefs = "node_refs"
        }
    }

    private struct Geometry: Decodable {
        let type: String
        let coordinates: [[Double]]
    }

    static let features: [BigSightOpenStreetMapFeature] = {
        do {
            guard let url = resourceURL(in: .main) else {
                assertionFailure("BigSightPedestrianWays.geojson is missing from the app bundle")
                return []
            }
            return try decode(Data(contentsOf: url))
        } catch {
            assertionFailure("Unable to load Big Sight pedestrian ways: \(error)")
            return []
        }
    }()

    static func decode(_ data: Data) throws -> [BigSightOpenStreetMapFeature] {
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        return collection.features.compactMap { feature -> BigSightOpenStreetMapFeature? in
            guard feature.geometry.type == "LineString",
                  feature.geometry.coordinates.count >= 2,
                  let kind = kind(named: feature.properties.kind)
            else { return nil }

            let coordinates = feature.geometry.coordinates.compactMap {
                coordinate -> GeographicCoordinate? in
                guard coordinate.count >= 2,
                      coordinate[0].isFinite,
                      coordinate[1].isFinite,
                      (-180...180).contains(coordinate[0]),
                      (-90...90).contains(coordinate[1])
                else { return nil }
                return GeographicCoordinate(
                    latitude: coordinate[1],
                    longitude: coordinate[0]
                )
            }
            guard coordinates.count == feature.geometry.coordinates.count else { return nil }

            return BigSightOpenStreetMapFeature(
                id: feature.properties.osmID,
                name: feature.properties.name ?? String(localized: "Pedestrian walkway"),
                kind: kind,
                coordinates: coordinates,
                nodeIDs: feature.properties.nodeRefs?.count == coordinates.count
                    ? feature.properties.nodeRefs
                    : nil,
                level: feature.properties.level,
                isIndoor: feature.properties.indoor,
                isCovered: feature.properties.covered
            )
        }
    }

    private static func resourceURL(in bundle: Bundle) -> URL? {
        let name = "BigSightPedestrianWays"
        return bundle.url(forResource: name, withExtension: "geojson")
            ?? bundle.url(forResource: name, withExtension: "geojson", subdirectory: "MapData")
            ?? bundle.url(
                forResource: name,
                withExtension: "geojson",
                subdirectory: "Resources/MapData"
            )
    }

    private static func kind(named name: String) -> BigSightOpenStreetMapFeature.Kind? {
        switch name {
        case "footway": .footway
        case "steps": .steps
        default: nil
        }
    }
}
