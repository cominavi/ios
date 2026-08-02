import CoreGraphics
import Foundation

struct GeographicCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct BigSightCampusScene: Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let day: Int
        let mapIDs: [Int]
    }

    let id: ID
    let venues: [BigSightVenuePlacement]
    let connections: [BigSightCampusConnection]
    let openStreetMapFeatures: [BigSightOpenStreetMapFeature]
    let facilities: [BigSightFacilityLocation]
    let operationalRoutes: [BigSightOperationalRoute]
    let bounds: CGRect

    init(
        id: ID,
        venues: [BigSightVenuePlacement],
        connections: [BigSightCampusConnection],
        openStreetMapFeatures: [BigSightOpenStreetMapFeature] = [],
        facilities: [BigSightFacilityLocation] = [],
        operationalRoutes: [BigSightOperationalRoute] = [],
        bounds: CGRect
    ) {
        self.id = id
        self.venues = venues
        self.connections = connections
        self.openStreetMapFeatures = openStreetMapFeatures
        self.facilities = facilities
        self.operationalRoutes = operationalRoutes
        self.bounds = bounds
    }
}

struct BigSightOpenStreetMapFeature: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case connectingBridge
        case footway
        case steps
    }

    let id: Int64
    let name: String
    let kind: Kind
    let coordinates: [GeographicCoordinate]
    let nodeIDs: [Int64]?
    let level: String?
    let isIndoor: Bool
    let isCovered: Bool

    init(
        id: Int64,
        name: String,
        kind: Kind,
        coordinates: [GeographicCoordinate],
        nodeIDs: [Int64]? = nil,
        level: String? = nil,
        isIndoor: Bool = false,
        isCovered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.coordinates = coordinates
        self.nodeIDs = nodeIDs
        self.level = level
        self.isIndoor = isIndoor
        self.isCovered = isCovered
    }

    var points: [CGPoint] { coordinates.map(BigSightCampusLayout.project) }
}

enum BigSightMapIcon: String, CaseIterable, Sendable {
    struct VenueBadge: Equatable, Sendable {
        struct ColorComponents: Equatable, Sendable {
            let red: Double
            let green: Double
            let blue: Double
        }

        let japanese: String
        let english: String
        let color: ColorComponents
    }

    enum Accent: Equatable, Sendable {
        case ink
        case red
        case green
        case blue
        case amber
        case taupe
    }

    enum Backdrop: Equatable, Sendable {
        case standard
        case transitYellowCircle
        case venueBilingualBadge
    }

    case accessibleFacilities = "BigSightAccessibleFacilities"
    case aed = "BigSightAED"
    case babyCareRoom = "BigSightBabyCareRoom"
    case bus = "BigSightBus"
    case coinLockers = "BigSightCoinLockers"
    case conferenceTower = "BigSightConferenceTower"
    case convenienceStore = "BigSightConvenienceStore"
    case cosplayArea = "BigSightCosplayArea"
    case cosplayChanging = "BigSightCosplayChanging"
    case closedArea = "BigSightClosedArea"
    case eastHalls = "BigSightEastHalls"
    case elevator = "BigSightElevator"
    case entryGate = "BigSightEntryGate"
    case escalator = "BigSightEscalator"
    case firstAidRoom = "BigSightFirstAidRoom"
    case food = "BigSightFood"
    case infantFacilities = "BigSightInfantFacilities"
    case information = "BigSightInformation"
    case nursingRoom = "BigSightNursingRoom"
    case ostomateRestroom = "BigSightOstomateRestroom"
    case parking = "BigSightParking"
    case pharmacy = "BigSightPharmacy"
    case postBox = "BigSightPostBox"
    case prayerRoom = "BigSightPrayerRoom"
    case restroom = "BigSightRestroom"
    case smokingArea = "BigSightSmokingArea"
    case southHalls = "BigSightSouthHalls"
    case stairs = "BigSightStairs"
    case taxi = "BigSightTaxi"
    case ticketExchange = "BigSightTicketExchange"
    case train = "BigSightTrain"
    case atm = "BigSightATM"
    case waitingArea = "BigSightWaitingArea"
    case waterBus = "BigSightWaterBus"
    case westHalls = "BigSightWestHalls"
    case workspace = "BigSightWorkspace"

    var accent: Accent {
        switch self {
        case .aed, .closedArea, .eastHalls:
            .red
        case .firstAidRoom, .pharmacy, .southHalls:
            .green
        case .accessibleFacilities, .information, .westHalls:
            .blue
        case .bus, .taxi, .train, .waterBus:
            .amber
        case .conferenceTower:
            .taupe
        default:
            .ink
        }
    }

    var backdrop: Backdrop {
        switch self {
        case .eastHalls, .southHalls, .westHalls:
            .venueBilingualBadge
        case .bus, .taxi, .train, .waterBus:
            .transitYellowCircle
        default:
            .standard
        }
    }

    var assetName: String? {
        venueBadge == nil ? rawValue : nil
    }

    var venueBadge: VenueBadge? {
        switch self {
        case .eastHalls:
            VenueBadge(
                japanese: "東",
                english: "EAST",
                color: VenueBadge.ColorComponents(
                    red: 216.0 / 255.0,
                    green: 11.0 / 255.0,
                    blue: 42.0 / 255.0
                )
            )
        case .westHalls:
            VenueBadge(
                japanese: "西",
                english: "WEST",
                color: VenueBadge.ColorComponents(
                    red: 0,
                    green: 85.0 / 255.0,
                    blue: 157.0 / 255.0
                )
            )
        case .southHalls:
            VenueBadge(
                japanese: "南",
                english: "SOUTH",
                color: VenueBadge.ColorComponents(
                    red: 0,
                    green: 169.0 / 255.0,
                    blue: 58.0 / 255.0
                )
            )
        default:
            nil
        }
    }
}

struct BigSightFacilityLocation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case conferenceTower
        case information
        case parking
        case restroom
        case smokingArea
        case bus
        case taxi
        case train
        case waterBus
        case convenienceStore
        case food
        case atm
        case pharmacy
        case firstAid
        case internationalDesk
        case entryGate
        case waitingArea
        case ticketExchange
        case elevator
        case escalator
        case stairs
        case cosplayArea
        case cosplayChanging
        case closedArea

        var icon: BigSightMapIcon {
            switch self {
            case .conferenceTower: .conferenceTower
            case .information, .internationalDesk: .information
            case .parking: .parking
            case .restroom: .restroom
            case .smokingArea: .smokingArea
            case .bus: .bus
            case .taxi: .taxi
            case .train: .train
            case .waterBus: .waterBus
            case .firstAid: .firstAidRoom
            case .elevator: .elevator
            case .escalator: .escalator
            case .convenienceStore: .convenienceStore
            case .food: .food
            case .atm: .atm
            case .pharmacy: .pharmacy
            case .entryGate: .entryGate
            case .waitingArea: .waitingArea
            case .ticketExchange: .ticketExchange
            case .stairs: .stairs
            case .cosplayArea: .cosplayArea
            case .cosplayChanging: .cosplayChanging
            case .closedArea: .closedArea
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let coordinate: GeographicCoordinate
    let layer: BigSightMapLayer?
    /// Minor indoor services wait until the user has zoomed into the campus.
    let minimumZoom: CGFloat
    /// Upper cutoff for markers inside a calibrated venue footprint. Exterior
    /// facilities remain visible at detailed zoom so the map never loses
    /// nearby transport and campus infrastructure.
    let maximumZoom: CGFloat
    let detail: String?

    init(
        id: String,
        name: String,
        kind: Kind,
        coordinate: GeographicCoordinate,
        layer: BigSightMapLayer? = nil,
        minimumZoom: CGFloat,
        maximumZoom: CGFloat = 24,
        detail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.coordinate = coordinate
        self.layer = layer
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.detail = detail
    }

    var center: CGPoint { BigSightCampusLayout.project(coordinate) }
}

struct BigSightVenuePlacement: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case east123
        case east456
        case east7
        case west
        case south

        var displayName: String {
            switch self {
            case .east123: String(localized: "East 1–3")
            case .east456: String(localized: "East 4–6")
            case .east7: String(localized: "East 7")
            case .west: String(localized: "West Halls")
            case .south: String(localized: "South Halls")
            }
        }

        var icon: BigSightMapIcon {
            switch self {
            case .east123, .east456, .east7: .eastHalls
            case .west: .westHalls
            case .south: .southHalls
            }
        }
    }

    var id: Int { scene.id.mapID }

    let kind: Kind
    let scene: CatalogMapScene
    let coordinate: GeographicCoordinate
    let center: CGPoint
    let rotation: CGFloat
    let metersPerMapPoint: CGFloat
    let verticalMetersPerMapPoint: CGFloat

    init(
        kind: Kind,
        scene: CatalogMapScene,
        coordinate: GeographicCoordinate,
        center: CGPoint,
        rotation: CGFloat,
        metersPerMapPoint: CGFloat,
        verticalMetersPerMapPoint: CGFloat? = nil
    ) {
        self.kind = kind
        self.scene = scene
        self.coordinate = coordinate
        self.center = center
        self.rotation = rotation
        self.metersPerMapPoint = metersPerMapPoint
        self.verticalMetersPerMapPoint = verticalMetersPerMapPoint ?? metersPerMapPoint
    }

    var transform: CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: rotation)
            .scaledBy(x: metersPerMapPoint, y: verticalMetersPerMapPoint)
            .translatedBy(x: -scene.size.width / 2, y: -scene.size.height / 2)
    }

    var bounds: CGRect {
        CGRect(origin: .zero, size: scene.size).applying(transform)
    }

    func contains(campusPoint: CGPoint) -> Bool {
        CGRect(origin: .zero, size: scene.size)
            .contains(campusPoint.applying(transform.inverted()))
    }
}

struct BigSightCampusConnection: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let points: [CGPoint]
    let distanceMeters: Int

    init(id: String, name: String, points: [CGPoint]) {
        self.id = id
        self.name = name
        self.points = points
        distanceMeters = Int(
            zip(points, points.dropFirst()).reduce(0) { distance, pair in
                distance + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            }.rounded()
        )
    }
}

enum BigSightCampusLayout {
    /// A standard Comiket table is approximately 1.8 m wide and 40 catalog-map points wide.
    static let metersPerMapPoint: CGFloat = 1.8 / 40

    /// Venue artwork alignment authored against OpenStreetMap for a specific event.
    /// `baseRotation` excludes the catalog's `mapRotation` so rotated map variants still
    /// compose correctly. Width and height remain independent because the alignment tool
    /// allows each edge to be fitted precisely to the basemap.
    private struct VenueCalibration {
        let coordinate: GeographicCoordinate
        let baseRotation: CGFloat
        let metersPerMapPoint: CGFloat
        let verticalMetersPerMapPoint: CGFloat

        init(
            coordinate: GeographicCoordinate,
            baseRotation: CGFloat,
            widthMeters: CGFloat,
            heightMeters: CGFloat,
            sceneSize: CGSize
        ) {
            self.coordinate = coordinate
            self.baseRotation = baseRotation
            metersPerMapPoint = widthMeters / sceneSize.width
            verticalMetersPerMapPoint = heightMeters / sceneSize.height
        }
    }

    // Representative building and routing landmarks from OpenStreetMap and the official
    // Tokyo Big Sight floor diagrams. Artwork placement uses the calibrations below.
    static let eastBuilding = GeographicCoordinate(latitude: 35.6317268, longitude: 139.7977084)
    static let newEastBuilding = GeographicCoordinate(latitude: 35.6331039, longitude: 139.7991998)
    static let westBuilding = GeographicCoordinate(latitude: 35.6288139, longitude: 139.7950394)
    static let southBuilding = GeographicCoordinate(latitude: 35.6276546, longitude: 139.7949281)
    static let connectingBridge = GeographicCoordinate(latitude: 35.6311356, longitude: 139.7957938)
    static let entrancePlaza = GeographicCoordinate(latitude: 35.6297844, longitude: 139.7940718)
    static let northConcourse = GeographicCoordinate(latitude: 35.6305780, longitude: 139.7949472)
    static let westAtrium = GeographicCoordinate(latitude: 35.6289595, longitude: 139.7947228)
    static let linkSpace = GeographicCoordinate(latitude: 35.6327740, longitude: 139.7995499)

    /// The level-two Connecting Bridge from OpenStreetMap way 154080996. MapLibre sits
    /// below the opaque catalog artwork, so this boundary is repeated above that artwork
    /// using the source feature's exact geographic geometry.
    static let connectingBridgeFeature = BigSightOpenStreetMapFeature(
        id: 154_080_996,
        name: String(localized: "Connecting Bridge"),
        kind: .connectingBridge,
        coordinates: [
            GeographicCoordinate(latitude: 35.6312555, longitude: 139.7962873),
            GeographicCoordinate(latitude: 35.6312520, longitude: 139.7961186),
            GeographicCoordinate(latitude: 35.6312344, longitude: 139.7952893),
            GeographicCoordinate(latitude: 35.6310157, longitude: 139.7952349),
            GeographicCoordinate(latitude: 35.6310395, longitude: 139.7963414),
            GeographicCoordinate(latitude: 35.6311831, longitude: 139.7963526),
        ]
    )

    private static let origin = GeographicCoordinate(latitude: 35.6304, longitude: 139.7960)
    static func make(
        eventNumber: Int,
        day: Int,
        halls: [UFDSchema.DayHall],
        scenes: [Int: CatalogMapScene]
    ) -> BigSightCampusScene? {
        let hallsByMapID = Dictionary(uniqueKeysWithValues: halls.map { ($0.externalMapId, $0) })
        let venues = scenes.values.compactMap { scene -> BigSightVenuePlacement? in
            guard let hall = hallsByMapID[scene.id.mapID],
                  let kind = venueKind(hall: hall, scene: scene)
            else {
                return nil
            }

            let calibration = venueCalibration(
                eventNumber: eventNumber,
                kind: kind,
                sceneSize: scene.size
            )
            let anchor = venueAnchor(for: kind, calibration: calibration)
            return BigSightVenuePlacement(
                kind: kind,
                scene: scene,
                coordinate: anchor.coordinate,
                center: anchor.point,
                rotation: (calibration?.baseRotation ?? defaultRotation(for: kind))
                    + scene.layoutRotation,
                metersPerMapPoint: calibration?.metersPerMapPoint ?? metersPerMapPoint,
                verticalMetersPerMapPoint: calibration?.verticalMetersPerMapPoint
            )
        }
        .sorted { $0.scene.id.mapID < $1.scene.id.mapID }

        guard !venues.isEmpty else { return nil }

        let connections = makeConnections(venues: venues)
        let openStreetMapFeatures = [connectingBridgeFeature]
            + BigSightPedestrianWayCatalog.features
        let facilities = BigSightMapContextCatalog.facilities(
            eventNumber: eventNumber,
            venues: venues
        )
        let operationalRoutes = BigSightMapContextCatalog.routes(eventNumber: eventNumber)
        var bounds = venues.dropFirst().reduce(venues[0].bounds) { $0.union($1.bounds) }
        for point in connections.flatMap(\.points) {
            bounds = bounds.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        for point in openStreetMapFeatures.flatMap(\.points) {
            bounds = bounds.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        for facility in facilities {
            bounds = bounds.union(CGRect(x: facility.center.x, y: facility.center.y, width: 1, height: 1))
        }
        for point in operationalRoutes.flatMap(\.points) {
            bounds = bounds.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        bounds = bounds.insetBy(dx: -70, dy: -70)

        return BigSightCampusScene(
            id: .init(day: day, mapIDs: venues.map(\.id)),
            venues: venues,
            connections: connections,
            openStreetMapFeatures: openStreetMapFeatures,
            facilities: facilities,
            operationalRoutes: operationalRoutes,
            bounds: bounds
        )
    }

    static func project(_ coordinate: GeographicCoordinate) -> CGPoint {
        let earthRadius = 6_378_137.0
        let latitudeRadians = origin.latitude * .pi / 180
        let x = (coordinate.longitude - origin.longitude) * .pi / 180
            * earthRadius * cos(latitudeRadians)
        let north = (coordinate.latitude - origin.latitude) * .pi / 180 * earthRadius
        return CGPoint(x: x, y: -north)
    }

    static func coordinate(from point: CGPoint) -> GeographicCoordinate {
        let earthRadius = 6_378_137.0
        let latitudeRadians = origin.latitude * .pi / 180
        return GeographicCoordinate(
            latitude: origin.latitude - Double(point.y) / earthRadius * 180 / .pi,
            longitude: origin.longitude
                + Double(point.x) / (earthRadius * cos(latitudeRadians)) * 180 / .pi
        )
    }

    private static func venueKind(
        hall: UFDSchema.DayHall,
        scene: CatalogMapScene
    ) -> BigSightVenuePlacement.Kind? {
        let name = "\(hall.name) \(hall.mapName) \(scene.name)"
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")

        if name.contains("東123") || name.contains("E123") || name.contains("EAST123") {
            return .east123
        }
        if name.contains("東456") || name.contains("E456") || name.contains("EAST456") {
            return .east456
        }
        if name.contains("東7") || name.contains("E7") || name.contains("EAST7") {
            return .east7
        }
        if name.contains("西") || name.contains("WEST") || name.contains("W12") || name.contains("W34") {
            return .west
        }
        if name.contains("南") || name.contains("SOUTH") || name.contains("S12") || name.contains("S34") {
            return .south
        }
        return nil
    }

    private static func venueAnchor(
        for kind: BigSightVenuePlacement.Kind,
        calibration: VenueCalibration?
    ) -> (coordinate: GeographicCoordinate, point: CGPoint) {
        if let calibration {
            return (calibration.coordinate, project(calibration.coordinate))
        }

        switch kind {
        case .east123, .east456, .east7, .west:
            preconditionFailure("Calibrated venue is missing alignment data")
        case .south:
            return (southBuilding, project(southBuilding))
        }
    }

    private static func venueCalibration(
        eventNumber: Int,
        kind: BigSightVenuePlacement.Kind,
        sceneSize: CGSize
    ) -> VenueCalibration? {
        if eventNumber == 108 {
            return c108VenueCalibration(for: kind, sceneSize: sceneSize)
                ?? c104VenueCalibration(for: kind, sceneSize: sceneSize)
        }
        return c104VenueCalibration(for: kind, sceneSize: sceneSize)
    }

    private static func c104VenueCalibration(
        for kind: BigSightVenuePlacement.Kind,
        sceneSize: CGSize
    ) -> VenueCalibration? {
        switch kind {
        case .east123:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.631057820055005,
                    longitude: 139.79794721575166
                ),
                baseRotation: degreesToRadians(146.462),
                widthMeters: 275.8224542031329,
                heightMeters: 99.01318868830411,
                sceneSize: sceneSize
            )
        case .east456:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.63237082511334,
                    longitude: 139.7975145453659
                ),
                baseRotation: degreesToRadians(-213.53800000000001),
                widthMeters: 271.05487926318995,
                heightMeters: 97.30175153037587,
                sceneSize: sceneSize
            )
        case .east7:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.633471367816355,
                    longitude: 139.7994204284449
                ),
                baseRotation: degreesToRadians(-33.40707083299674),
                widthMeters: 113.01855361967942,
                heightMeters: 122.28236949014496,
                sceneSize: sceneSize
            )
        case .west:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.62877144202331,
                    longitude: 139.79501092499783
                ),
                baseRotation: degreesToRadians(146.97977914964463),
                widthMeters: 205.27930023717607,
                heightMeters: 145.97639127976964,
                sceneSize: sceneSize
            )
        case .south:
            nil
        }
    }

    private static func c108VenueCalibration(
        for kind: BigSightVenuePlacement.Kind,
        sceneSize: CGSize
    ) -> VenueCalibration? {
        switch kind {
        case .east123:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.631057820055005,
                    longitude: 139.79794721575166
                ),
                baseRotation: degreesToRadians(146.462),
                widthMeters: 275.8224542031329,
                heightMeters: 103.72809983536543,
                sceneSize: sceneSize
            )
        case .east7:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.633471367816355,
                    longitude: 139.7994204284449
                ),
                baseRotation: degreesToRadians(-33.40707083299674),
                widthMeters: 113.01855361967942,
                heightMeters: 122.28236949014496,
                sceneSize: sceneSize
            )
        case .west:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.62877144202331,
                    longitude: 139.79501092499783
                ),
                baseRotation: degreesToRadians(146.97977914964463),
                widthMeters: 205.27930023717607,
                heightMeters: 152.81943451220806,
                sceneSize: sceneSize
            )
        case .south:
            VenueCalibration(
                coordinate: GeographicCoordinate(
                    latitude: 35.62700699450169,
                    longitude: 139.7956005438195
                ),
                baseRotation: degreesToRadians(56.39305764784899),
                widthMeters: 164.32035141970715,
                heightMeters: 90.11116045596845,
                sceneSize: sceneSize
            )
        case .east456:
            nil
        }
    }

    private static func degreesToRadians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
    }

    private static func defaultRotation(for kind: BigSightVenuePlacement.Kind) -> CGFloat {
        switch kind {
        case .east123, .east456, .east7, .west:
            preconditionFailure("Calibrated venue is missing alignment data")
        case .south: CGFloat(50.8873 * .pi / 180)
        }
    }

    private static func makeConnections(
        venues: [BigSightVenuePlacement]
    ) -> [BigSightCampusConnection] {
        let venueByKind = Dictionary(grouping: venues, by: \.kind).mapValues { $0[0] }
        let eastMain = venueByKind[.east123] ?? venueByKind[.east456]
        let eastCenter = project(eastBuilding)
        let link = project(linkSpace)
        let bridge = project(connectingBridge)
        let north = project(northConcourse)
        let entrance = project(entrancePlaza)
        let atrium = project(westAtrium)
        var result: [BigSightCampusConnection] = []

        if venueByKind[.east123] != nil, venueByKind[.east456] != nil {
            result.append(BigSightCampusConnection(
                id: "east-galleria",
                name: String(localized: "Galleria"),
                points: [venueByKind[.east123]!.center, eastCenter, venueByKind[.east456]!.center]
            ))
        }

        if let east7 = venueByKind[.east7], eastMain != nil {
            result.append(BigSightCampusConnection(
                id: "east-link-space",
                name: String(localized: "Link Space"),
                points: [east7.center, link, eastCenter]
            ))
        }

        if eastMain != nil, venueByKind[.west] != nil || venueByKind[.south] != nil {
            result.append(BigSightCampusConnection(
                id: "east-entrance-concourse",
                name: String(localized: "North Concourse"),
                points: [eastCenter, bridge, north, entrance]
            ))
        }

        if let west = venueByKind[.west] {
            result.append(BigSightCampusConnection(
                id: "entrance-west-atrium",
                name: String(localized: "West Atrium"),
                points: [entrance, atrium, west.center]
            ))
        }

        if let south = venueByKind[.south] {
            let southConcourse = CGPoint(
                x: entrance.x * 0.45 + south.center.x * 0.55,
                y: entrance.y * 0.45 + south.center.y * 0.55
            )
            result.append(BigSightCampusConnection(
                id: "entrance-south-concourse",
                name: String(localized: "South Concourse"),
                points: [entrance, southConcourse, south.center]
            ))
        }

        return result
    }
}
