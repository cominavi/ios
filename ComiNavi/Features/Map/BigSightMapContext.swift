import CoreGraphics
import Foundation

enum BigSightMapLayer: String, CaseIterable, Identifiable, Sendable {
    case gates
    case essentials
    case assistance
    case verticalAccess
    case cosplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gates: String(localized: "Gates & Tickets")
        case .essentials: String(localized: "Food, Shops & Restrooms")
        case .assistance: String(localized: "Information & Medical")
        case .verticalAccess: String(localized: "Elevators & Stairs")
        case .cosplay: String(localized: "Cosplay")
        }
    }

    var systemImage: String {
        switch self {
        case .gates: "door.left.hand.open"
        case .essentials: "cart.fill"
        case .assistance: "cross.case.fill"
        case .verticalAccess: "figure.stairs"
        case .cosplay: "theatermasks.fill"
        }
    }

    static let defaultVisible = Set(allCases)
}

enum BigSightMapContextCatalog {
    /// Permanent campus and nearby-station amenities. Coordinates are from the
    /// OpenStreetMap snapshot captured 2026-07-22 and cross-checked against the
    /// current Tokyo Big Sight facility/shop directory.
    static let permanentFacilities: [BigSightFacilityLocation] = [
        facility("conference-tower", "Conference Tower", .conferenceTower, 35.6297628, 139.7939817),
        facility(
            "general-information", "General Information", .information, 35.6301962, 139.7946672,
            layer: .assistance, minimumZoom: 1.2),
        facility(
            "north-concourse-restroom", "North Concourse Restroom", .restroom, 35.6311241,
            139.7935820,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "entrance-hall-restroom", "Entrance Hall Restroom", .restroom, 35.6307891, 139.7937983,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "conference-tower-restroom", "Conference Tower Restroom", .restroom, 35.6300751,
            139.7931608,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "entrance-plaza-restroom", "Entrance Plaza Restroom", .restroom, 35.6299510,
            139.7936510,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "west-atrium-restroom", "West Atrium Restroom", .restroom, 35.6291640, 139.7947830,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "south-concourse-restroom", "South Concourse Restroom", .restroom, 35.6279200,
            139.7950350,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "meeting-plaza-restroom", "Meeting Plaza Restroom", .restroom, 35.6284100, 139.7955550,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "east7-restroom", "East Hall 7 Restroom", .restroom, 35.6333350, 139.7990800,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "east8-restroom", "East Hall 8 Restroom", .restroom, 35.6338250, 139.7997250,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "kokusai-station-restroom", "Kokusai-tenjijo Station Restroom", .restroom, 35.6334851,
            139.7914391, layer: .essentials, minimumZoom: 2.2, detail: "Accessible restroom"),
        facility(
            "ariake-corridor-restroom", "Ariake Corridor Restroom", .restroom, 35.6318525,
            139.7926836,
            layer: .essentials, minimumZoom: 2.2, detail: "Accessible restroom"),
        facility(
            "entrance-plaza-smoking-area", "Entrance Plaza Smoking Area", .smokingArea, 35.6302819,
            139.7942352, minimumZoom: 2.2),
        facility(
            "conference-tower-smoking-area", "Conference Tower Smoking Area", .smokingArea,
            35.6291328,
            139.7939653, minimumZoom: 2.2),
        facility(
            "east-parking-entrance", "East Parking Entrance", .parking, 35.6310747, 139.7961552,
            minimumZoom: 1.2),
        facility(
            "conference-tower-underground-parking", "Conference Tower Underground Parking",
            .parking,
            35.6296920, 139.7932926, minimumZoom: 1.2),
        facility("bus-terminal", "Tokyo Big Sight Bus Terminal", .bus, 35.6303156, 139.7931589),
        facility(
            "taxi-stand", "Tokyo Big Sight Taxi Stand", .taxi, 35.6304789, 139.7936554,
            minimumZoom: 1.2),
        facility(
            "tokyo-big-sight-station", "Tokyo Big Sight Station", .train, 35.6301970, 139.7913701),
        facility(
            "kokusai-tenjijo-station", "Kokusai-tenjijo Station · Rinkai Line", .train, 35.6344374,
            139.7917555),
        facility(
            "ariake-passenger-terminal", "Ariake Passenger Terminal", .waterBus, 35.6293753,
            139.7925456),

        facility(
            "lawson-kokusai-station", "Lawson · Kokusai-tenjijo Station", .convenienceStore,
            35.6340671,
            139.7912456, layer: .essentials, minimumZoom: 1.2),
        facility(
            "seven-eleven-kokusai-station", "7-Eleven · Kokusai-tenjijo Station", .convenienceStore,
            35.6346199, 139.7922610, layer: .essentials, minimumZoom: 1.2),
        facility(
            "daily-yamazaki-ariake", "Daily Yamazaki · Ariake", .convenienceStore, 35.6326970,
            139.7927166, layer: .essentials, minimumZoom: 1.2, detail: "ATM available"),
        facility(
            "familymart-ariake-frontier", "FamilyMart · Ariake Frontier", .convenienceStore,
            35.6318354,
            139.7916974, layer: .essentials, minimumZoom: 1.6),
        facility(
            "seven-eleven-tft", "7-Eleven · TFT", .convenienceStore, 35.6313923, 139.7904562,
            layer: .essentials, minimumZoom: 1.6, detail: "ATM available"),
        facility(
            "lawson-ariake-central", "Lawson · Ariake Central Tower", .convenienceStore, 35.6320021,
            139.7940015, layer: .essentials, minimumZoom: 1.6),
        facility(
            "ministop-tft", "Ministop · TFT", .convenienceStore, 35.6306063, 139.7902689,
            layer: .essentials, minimumZoom: 1.6),
        facility(
            "lawson-big-sight", "Lawson · Entrance Hall", .convenienceStore, 35.6302740,
            139.7952500,
            layer: .essentials, minimumZoom: 2.2, detail: "2F"),
        facility(
            "familymart-galleria", "FamilyMart · Galleria", .convenienceStore, 35.6313741,
            139.7966759,
            layer: .essentials, minimumZoom: 2.2, detail: "2F"),
        facility(
            "familymart-entrance", "FamilyMart · Conference Tower", .convenienceStore, 35.6295837,
            139.7933403, layer: .essentials, minimumZoom: 2.2),
        facility(
            "lawson-south", "Lawson · South Hall", .convenienceStore, 35.6275388, 139.7949276,
            layer: .essentials, minimumZoom: 2.2, detail: "2F"),
        facility(
            "food-east-galleria", "East Galleria Food & Restaurants", .food, 35.6316000,
            139.7972600,
            layer: .essentials, minimumZoom: 2.2, detail: "2F–3F"),
        facility(
            "food-entrance-conference", "Entrance Hall Cafes & Food", .food, 35.6298500,
            139.7944000,
            layer: .essentials, minimumZoom: 2.2, detail: "1F–2F"),
        facility(
            "food-west-cafe", "West Hall Cafe", .food, 35.6289000, 139.7950000, layer: .essentials,
            minimumZoom: 2.2, detail: "2F"),
        facility(
            "food-south-square", "South Hall Food Square", .food, 35.6276000, 139.7952000,
            layer: .essentials, minimumZoom: 2.2, detail: "3F–4F"),
        facility(
            "food-tft", "TFT Restaurants", .food, 35.6309000, 139.7905000, layer: .essentials,
            minimumZoom: 2.2),

        facility(
            "big-sight-atm", "Tokyo Big Sight ATM", .atm, 35.6299400, 139.7947300,
            layer: .essentials,
            minimumZoom: 2.2, detail: "Entrance Hall 2F"),
        facility(
            "seven-bank-kokusai", "Seven Bank ATM · Station", .atm, 35.6341411, 139.7913592,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "japan-post-atm-tft", "Japan Post ATM · TFT", .atm, 35.6308028, 139.7900793,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "mizuho-atm-tft", "Mizuho ATM · TFT", .atm, 35.6308357, 139.7902681, layer: .essentials,
            minimumZoom: 2.2),
        facility(
            "seven-bank-atm-tft", "Seven Bank ATM · TFT", .atm, 35.6310453, 139.7906876,
            layer: .essentials, minimumZoom: 2.2),
        facility(
            "wanza-pharmacy-tft", "Wanza Pharmacy · TFT", .pharmacy, 35.6309306, 139.7902241,
            layer: .assistance, minimumZoom: 2.2),
    ]

    static func facilities(
        eventNumber: Int,
        venues: [BigSightVenuePlacement]
    ) -> [BigSightFacilityLocation] {
        var result = permanentFacilities
        result += eastHallPermanentFacilities(venues: venues)
        if eventNumber == 108 {
            result += c108Facilities
        }
        return result
    }

    private static let c108Facilities: [BigSightFacilityLocation] = [
        facility(
            "c108-east-entry", "East Entry / Exit / Re-entry · Early & Morning", .entryGate,
            35.6312555,
            139.7962873, layer: .gates, maximumZoom: 16,
            detail: "Follow current staff directions; access may change"),
        facility(
            "c108-west-south-entry", "West / South Entry / Exit / Re-entry · Early & Morning",
            .entryGate,
            35.6297844, 139.7940718, layer: .gates, maximumZoom: 16),
        facility(
            "c108-afternoon-entry", "Afternoon Entry & Wristband Sales", .entryGate, 35.6296500,
            139.7939200, layer: .gates, maximumZoom: 16, detail: "Entrance Plaza · from 12:30"),
        facility(
            "c108-east-waiting", "East Early / AM Waiting Area", .waitingArea, 35.6327300,
            139.7970200,
            layer: .gates, maximumZoom: 12),
        facility(
            "c108-west-waiting", "West Early / AM Waiting Area", .waitingArea, 35.6289100,
            139.7929100,
            layer: .gates, maximumZoom: 12),
        facility(
            "c108-east-waiting-restroom", "East Waiting Area Restroom", .restroom, 35.6330150,
            139.7968350, layer: .essentials, minimumZoom: 1.6, maximumZoom: 16,
            detail: "Temporary event-day location; follow staff signs"),
        facility(
            "c108-west-waiting-restroom", "West Waiting Area Restroom", .restroom, 35.6287050,
            139.7929600, layer: .essentials, minimumZoom: 1.6, maximumZoom: 16,
            detail: "Temporary event-day location; follow staff signs"),
        facility(
            "c108-qr-exchange-station", "QR Wristband Exchange · 8:00–12:30", .ticketExchange,
            35.6324200,
            139.7925200, layer: .gates, maximumZoom: 16, detail: "Near Kokusai-tenjijo Station"),
        facility(
            "c108-qr-exchange-entrance", "QR Wristband Exchange · after 12:30", .ticketExchange,
            35.6299300, 139.7940100, layer: .gates, maximumZoom: 16, detail: "Entrance Plaza"),
        facility(
            "c108-cosplay-early-tft", "Cosplay Early Entry Exchange / Changing", .ticketExchange,
            35.6306500, 139.7905200, layer: .gates, maximumZoom: 16, detail: "TFT West 2F"),

        facility(
            "c108-west-information", "West Information Desk", .information, 35.6290300, 139.7947200,
            layer: .assistance, minimumZoom: 1.6),
        facility(
            "c108-west-international", "International Desk · West Atrium", .internationalDesk,
            35.6291300,
            139.7948100, layer: .assistance, minimumZoom: 1.6),
        facility(
            "c108-east-international", "International Desk · East Galleria", .internationalDesk,
            35.6312200, 139.7964900, layer: .assistance, minimumZoom: 1.6),
        facility(
            "c108-conference-first-aid", "First Aid & Emergency Help · Conference Tower", .firstAid,
            35.6297200, 139.7939000, layer: .assistance, minimumZoom: 1.6,
            detail: "1F Room 102 · temporary care; ask staff for ambulance assistance"),
        facility(
            "c108-west-first-aid", "First Aid & Emergency Help · West Atrium", .firstAid,
            35.6289300,
            139.7946500, layer: .assistance, minimumZoom: 1.6,
            detail: "Ask staff for ambulance assistance"),
        facility(
            "c108-south-first-aid", "First Aid & Emergency Help · South", .firstAid, 35.6277200,
            139.7950200, layer: .assistance, minimumZoom: 1.6,
            detail: "2F Meeting Room B · ask staff for ambulance assistance"),

        facility(
            "c108-cosplay-east8", "Cosplay Area · East Hall 8", .cosplayArea, 35.6336500,
            139.7999200,
            layer: .cosplay, minimumZoom: 1.2),
        facility(
            "c108-cosplay-east7-outdoor", "Cosplay Area · East 7 Antenna Site", .cosplayArea,
            35.6340200,
            139.8000200, layer: .cosplay, minimumZoom: 1.2,
            detail: "Afternoon; may change with weather or congestion"),
        facility(
            "c108-cosplay-garden", "Cosplay Area · Gardens", .cosplayArea, 35.6292600, 139.7935300,
            layer: .cosplay, minimumZoom: 1.2),
        facility(
            "c108-cosplay-rooftop", "Cosplay Area · Rooftop Exhibition Area", .cosplayArea,
            35.6288200,
            139.7952200, layer: .cosplay, minimumZoom: 1.2, detail: "Afternoon"),
        facility(
            "c108-cosplay-changing-women", "Cosplay Changing · Women", .cosplayChanging, 35.6297000,
            139.7939000, layer: .cosplay, minimumZoom: 2.2, detail: "Conference Tower 1F"),
        facility(
            "c108-cosplay-changing-men", "Cosplay Changing · Men", .cosplayChanging, 35.6298200,
            139.7940400, layer: .cosplay, minimumZoom: 2.2, detail: "Conference Tower 6F"),

        facility(
            "c108-east456-closed", "East Halls 4–6 · Closed for construction", .closedArea,
            35.6323708251,
            139.7975145454, maximumZoom: 14, detail: "Refurbishment closure · Mar 30–Dec 31, 2026"),
    ]

    /// Positions are normalized against the official East 1–3 top-down plan.
    /// They follow the catalog artwork itself, so they remain aligned after the
    /// venue's calibrated rotation and non-uniform scale are applied.
    private static func eastHallPermanentFacilities(
        venues: [BigSightVenuePlacement]
    ) -> [BigSightFacilityLocation] {
        guard let venue = venues.first(where: { $0.kind == .east123 }) else { return [] }
        return [
            localFacility(
                "east1-first-aid", "First Aid · East Hall 1", .firstAid, venue, 0.720, 0.965,
                layer: .assistance, minimumZoom: 8,
                detail: "Organizer office · ask staff for ambulance assistance"),
            localFacility(
                "east1-information", "Information · East Hall 1", .information, venue, 0.700, 0.950,
                layer: .assistance, minimumZoom: 8),
            localFacility(
                "east2-information", "Information · East Hall 2", .information, venue, 0.380, 0.950,
                layer: .assistance, minimumZoom: 8),
            localFacility(
                "east3-information", "Information · East Hall 3", .information, venue, 0.060, 0.950,
                layer: .assistance, minimumZoom: 8),

            localFacility(
                "east1-restroom-outer", "East 1 Outer Restroom", .restroom, venue, 0.720, 0.018,
                layer: .essentials, minimumZoom: 9),
            localFacility(
                "east1-restroom-galleria", "East 1 Galleria Restroom", .restroom, venue, 0.895,
                0.982,
                layer: .essentials, minimumZoom: 9),
            localFacility(
                "east2-restroom-outer", "East 2 Outer Restroom", .restroom, venue, 0.410, 0.018,
                layer: .essentials, minimumZoom: 9),
            localFacility(
                "east2-restroom-galleria", "East 2 Galleria Restroom", .restroom, venue, 0.625,
                0.982,
                layer: .essentials, minimumZoom: 9),
            localFacility(
                "east3-restroom-outer", "East 3 Outer Restroom", .restroom, venue, 0.100, 0.018,
                layer: .essentials, minimumZoom: 9),
            localFacility(
                "east3-restroom-galleria", "East 3 Galleria Restroom", .restroom, venue, 0.295,
                0.982,
                layer: .essentials, minimumZoom: 9),

            localFacility(
                "east1-elevator-west", "East 1 Elevator · West · Staff-directed", .elevator, venue,
                0.675,
                0.970, layer: .verticalAccess, minimumZoom: 10,
                detail: "Direction is staff-controlled"),
            localFacility(
                "east1-escalator-west", "East 1 Escalator · West · Staff-directed", .escalator,
                venue,
                0.705, 0.970, layer: .verticalAccess, minimumZoom: 10,
                detail: "Do not walk; follow staff direction"),
            localFacility(
                "east1-elevator-east", "East 1 Elevator · East · Staff-directed", .elevator, venue,
                0.945,
                0.960, layer: .verticalAccess, minimumZoom: 10,
                detail: "Direction is staff-controlled"),
            localFacility(
                "east1-escalator-east", "East 1 Escalator · East · Staff-directed", .escalator,
                venue,
                0.970, 0.960, layer: .verticalAccess, minimumZoom: 10,
                detail: "Do not walk; follow staff direction"),
            localFacility(
                "east1-stairs-east", "East 1 Stairs · Staff-directed", .stairs, venue, 0.982, 0.500,
                layer: .verticalAccess, minimumZoom: 10,
                detail: "Direction may change with crowd control"),
        ]
    }

    private static func localFacility(
        _ id: String,
        _ name: String.LocalizationValue,
        _ kind: BigSightFacilityLocation.Kind,
        _ venue: BigSightVenuePlacement,
        _ x: CGFloat,
        _ y: CGFloat,
        layer: BigSightMapLayer?,
        minimumZoom: CGFloat,
        detail: String.LocalizationValue? = nil
    ) -> BigSightFacilityLocation {
        let local = CGPoint(x: venue.scene.size.width * x, y: venue.scene.size.height * y)
        let coordinate = BigSightCampusLayout.coordinate(from: local.applying(venue.transform))
        return BigSightFacilityLocation(
            id: id,
            name: String(localized: name),
            kind: kind,
            coordinate: coordinate,
            layer: layer,
            minimumZoom: minimumZoom,
            maximumZoom: 70,
            detail: detail.map { String(localized: $0) }
        )
    }

    private static func facility(
        _ id: String,
        _ name: String.LocalizationValue,
        _ kind: BigSightFacilityLocation.Kind,
        _ latitude: Double,
        _ longitude: Double,
        layer: BigSightMapLayer? = nil,
        minimumZoom: CGFloat = 0,
        maximumZoom: CGFloat = 24,
        detail: String.LocalizationValue? = nil
    ) -> BigSightFacilityLocation {
        BigSightFacilityLocation(
            id: id,
            name: String(localized: name),
            kind: kind,
            coordinate: GeographicCoordinate(latitude: latitude, longitude: longitude),
            layer: layer,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            detail: detail.map { String(localized: $0) }
        )
    }

}
