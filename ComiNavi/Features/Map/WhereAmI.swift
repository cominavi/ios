import CoreGraphics
import Foundation

struct WhereAmIVenueOption: Identifiable, Equatable, Sendable {
    var id: Int { placement.id }

    let displayName: String
    let placement: BigSightVenuePlacement
}

struct WhereAmILocationReading: Equatable, Sendable {
    let coordinate: GeographicCoordinate
    let horizontalAccuracy: Double
    let timestamp: Date

    func isLive(at date: Date = .now) -> Bool {
        horizontalAccuracy >= 0 && abs(date.timeIntervalSince(timestamp)) <= 15
    }
}

struct ComiketSpaceAddress: Equatable, Sendable {
    let day: Int
    let hallName: String
    let blockName: String
    let spaceNumber: Int
    let subspace: Int?
    let isCombinedAB: Bool

    init(
        day: Int,
        hallName: String,
        blockName: String,
        spaceNumber: Int,
        subspace: Int?,
        isCombinedAB: Bool = false
    ) {
        self.day = day
        self.hallName = hallName
        self.blockName = blockName
        self.spaceNumber = spaceNumber
        self.subspace = subspace
        self.isCombinedAB = isCombinedAB
    }

    var spaceCode: String {
        let number = String(format: "%02d", spaceNumber)
        let side = isCombinedAB ? "a+b" : (subspace.map { $0 == 0 ? "a" : "b" } ?? "")
        return "\(blockName)\(number)\(side)"
    }

    var canonicalDayText: String { "\(day)日目" }

    var venueLocationText: String {
        "\(Self.canonicalHallName(hallName)) \(spaceCode)"
    }

    var navigationSubtitle: String {
        String(localized: "Day \(day) · \(venueLocationText)")
    }

    var canonicalText: String {
        "\(canonicalDayText) \(venueLocationText)"
    }

    var nearbyText: String { "\(canonicalText)付近" }

    func selecting(subspace: Int?) -> Self {
        Self(
            day: day,
            hallName: hallName,
            blockName: blockName,
            spaceNumber: spaceNumber,
            subspace: subspace,
            isCombinedAB: false
        )
    }

    static func canonicalHallName(_ value: String) -> String {
        let normalized = value.unicodeScalars.reduce(into: "") { result, scalar in
            if (0xFF10...0xFF19).contains(scalar.value),
                let asciiDigit = UnicodeScalar(scalar.value - 0xFEE0)
            {
                result.unicodeScalars.append(asciiDigit)
            } else if scalar != " " {
                result.unicodeScalars.append(scalar)
            }
        }
        return normalized.hasSuffix("ホール") ? normalized : "\(normalized)ホール"
    }
}

struct LocatedMapUser: Identifiable, Equatable, Sendable {
    enum Source: Hashable, Sendable {
        case guidedLocator
        case mapLongPress
        case gps
    }

    let sceneID: CatalogMapScene.ID
    let tableID: CatalogMapTable.ID
    let blockName: String
    let subspace: Int?
    let venueDisplayName: String
    let canonicalVenueName: String
    let point: CGPoint
    let headingDegrees: Double?
    let venueRotationRadians: Double
    let locationReading: WhereAmILocationReading?
    let source: Source
    let placedAt: Date

    var id: Date { placedAt }

    var mapHeadingRadians: Double? {
        headingDegrees.map { $0 * .pi / 180 - venueRotationRadians }
    }

    var spaceCode: String {
        address.spaceCode
    }

    var canonicalLocationText: String {
        address.nearbyText
    }

    private var address: ComiketSpaceAddress {
        ComiketSpaceAddress(
            day: sceneID.day,
            hallName: canonicalVenueName,
            blockName: blockName,
            spaceNumber: tableID.spaceNumber,
            subspace: subspace
        )
    }
}

struct MapDestination: Identifiable, Equatable, Sendable {
    let sceneID: CatalogMapScene.ID
    let tableID: CatalogMapTable.ID
    let blockName: String
    let subspace: Int?
    let venueDisplayName: String
    let canonicalVenueName: String
    let point: CGPoint
    let selectedAt: Date

    var id: Date { selectedAt }

    var spaceCode: String { address.spaceCode }

    var canonicalLocationText: String { address.canonicalText }

    private var address: ComiketSpaceAddress {
        ComiketSpaceAddress(
            day: sceneID.day,
            hallName: canonicalVenueName,
            blockName: blockName,
            spaceNumber: tableID.spaceNumber,
            subspace: subspace
        )
    }
}

struct WhereAmICharacterLayout: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case kana(columns: [KanaColumn])
        case alphabet([String])
    }

    struct KanaColumn: Identifiable, Equatable, Sendable {
        let id: String
        let cells: [KanaCell]
    }

    struct KanaCell: Identifiable, Equatable, Sendable {
        let id: Int
        let character: String?
    }

    let mode: Mode

    var orderedCharacters: [String] {
        switch mode {
        case .kana(let columns):
            columns.flatMap { $0.cells.compactMap(\.character) }
        case .alphabet(let characters):
            characters
        }
    }

    var usesOnlyLatinAlphabet: Bool {
        guard case .alphabet(let characters) = mode, !characters.isEmpty else { return false }
        return characters.allSatisfy(Self.isLatinAlphabetCharacter)
    }

    static func make(availableCharacters: [String]) -> WhereAmICharacterLayout {
        let available = Set(availableCharacters.filter { !$0.isEmpty })
        let hiragana = kanaColumns(using: hiraganaColumns, available: available)
        let katakana = kanaColumns(using: katakanaColumns, available: available)

        if !hiragana.isEmpty || !katakana.isEmpty {
            return WhereAmICharacterLayout(mode: .kana(columns: hiragana + katakana))
        }

        return WhereAmICharacterLayout(
            mode: .alphabet(available.sorted(by: alphabeticallyPrecedes))
        )
    }

    private static let hiraganaColumns: [[String?]] = [
        ["あ", "い", "う", "え", "お"],
        ["か", "き", "く", "け", "こ"],
        ["さ", "し", "す", "せ", "そ"],
        ["た", "ち", "つ", "て", "と"],
        ["な", "に", "ぬ", "ね", "の"],
        ["は", "ひ", "ふ", "へ", "ほ"],
        ["ま", "み", "む", "め", "も"],
        ["や", nil, "ゆ", nil, "よ"],
        ["ら", "り", "る", "れ", "ろ"],
        ["わ", nil, nil, nil, "を"],
        ["ん", nil, nil, nil, nil],
    ]

    private static let katakanaColumns: [[String?]] = [
        ["ア", "イ", "ウ", "エ", "オ"],
        ["カ", "キ", "ク", "ケ", "コ"],
        ["サ", "シ", "ス", "セ", "ソ"],
        ["タ", "チ", "ツ", "テ", "ト"],
        ["ナ", "ニ", "ヌ", "ネ", "ノ"],
        ["ハ", "ヒ", "フ", "ヘ", "ホ"],
        ["マ", "ミ", "ム", "メ", "モ"],
        ["ヤ", nil, "ユ", nil, "ヨ"],
        ["ラ", "リ", "ル", "レ", "ロ"],
        ["ワ", nil, nil, nil, "ヲ"],
        ["ン", nil, nil, nil, nil],
    ]

    private static func kanaColumns(
        using template: [[String?]],
        available: Set<String>
    ) -> [KanaColumn] {
        template.compactMap { column in
            let filtered = column.map { character in
                character.flatMap { available.contains($0) ? $0 : nil }
            }
            guard filtered.contains(where: { $0 != nil }),
                let id = filtered.compactMap({ $0 }).first
            else {
                return nil
            }
            return KanaColumn(
                id: id,
                cells: filtered.enumerated().map { index, character in
                    KanaCell(id: index, character: character)
                }
            )
        }
    }

    private static func alphabeticallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        normalizedLatin(lhs).localizedStandardCompare(normalizedLatin(rhs)) == .orderedAscending
    }

    private static func normalizedLatin(_ value: String) -> String {
        value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
    }

    private static func isLatinAlphabetCharacter(_ value: String) -> Bool {
        let normalized = normalizedLatin(value)
        guard !normalized.isEmpty else { return false }
        return normalized.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
    }
}

enum WhereAmICharacterSearch {
    static func filter(_ characters: [String], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return characters }

        let kanaQuery = JapaneseSearchNormalizer.normalize(query)
        let romajiQuery = romanized(query)
        return characters.filter { character in
            JapaneseSearchNormalizer.normalize(character).contains(kanaQuery)
                || (!romajiQuery.isEmpty && romanized(character).hasPrefix(romajiQuery))
        }
    }

    private static func romanized(_ value: String) -> String {
        let widthFolded = value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
        let latin = widthFolded.applyingTransform(.toLatin, reverse: false) ?? widthFolded
        let unaccented = latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        return unaccented
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ja_JP")
            )
            .filter { $0.isLetter || $0.isNumber }
    }
}

enum WhereAmIResolver {
    static func nearestVenue(
        to reading: WhereAmILocationReading,
        venues: [WhereAmIVenueOption]
    ) -> WhereAmIVenueOption? {
        guard isUsable(reading) else { return nil }

        let nearest = venues.min { lhs, rhs in
            distance(from: reading.coordinate, to: lhs.placement.coordinate)
                < distance(from: reading.coordinate, to: rhs.placement.coordinate)
        }
        guard let nearest else { return nil }

        let maximumUsefulDistance = max(700, reading.horizontalAccuracy * 2)
        return distance(from: reading.coordinate, to: nearest.placement.coordinate)
            <= maximumUsefulDistance
            ? nearest
            : nil
    }

    static func gpsLocatedUser(
        from reading: WhereAmILocationReading,
        headingDegrees: Double?,
        venues: [WhereAmIVenueOption],
        placedAt: Date = .now
    ) -> LocatedMapUser? {
        guard isUsable(reading) else { return nil }

        let campusPoint = BigSightCampusLayout.project(reading.coordinate)
        let venue = venues.first(where: { $0.placement.contains(campusPoint: campusPoint) })
            ?? nearestVenue(to: reading, venues: venues)
        guard let venue else { return nil }

        let localPoint = campusPoint.applying(venue.placement.transform.inverted())
        guard let table = nearestTable(to: localPoint, in: venue.placement.scene) else {
            return nil
        }
        let subspace = subspace(
            at: localPoint,
            in: table,
            scene: venue.placement.scene
        )
        return locatedUser(
            at: table,
            in: venue,
            subspace: subspace,
            point: localPoint,
            headingDegrees: headingDegrees,
            locationReading: reading,
            source: .gps,
            placedAt: placedAt
        )
    }

    static func table(
        blockName: String,
        number: Int,
        in scene: CatalogMapScene
    ) -> CatalogMapTable? {
        scene.tables.first {
            $0.blockName == blockName && $0.id.spaceNumber == number
        }
    }

    static func locatedUser(
        at table: CatalogMapTable,
        in venue: WhereAmIVenueOption,
        subspace: Int?,
        point: CGPoint? = nil,
        headingDegrees: Double?,
        locationReading: WhereAmILocationReading?,
        source: LocatedMapUser.Source = .guidedLocator,
        placedAt: Date = .now
    ) -> LocatedMapUser {
        LocatedMapUser(
            sceneID: venue.placement.scene.id,
            tableID: table.id,
            blockName: table.blockName,
            subspace: subspace,
            venueDisplayName: venue.displayName,
            canonicalVenueName: table.hallName
                ?? canonicalVenueName(for: venue.placement.kind),
            point: point
                ?? CGPoint(
                    x: table.origin.x + venue.placement.scene.tableSize.width / 2,
                    y: table.origin.y + venue.placement.scene.tableSize.height / 2
                ),
            headingDegrees: headingDegrees,
            venueRotationRadians: Double(venue.placement.rotation),
            locationReading: locationReading,
            source: source,
            placedAt: placedAt
        )
    }

    static func destination(
        at table: CatalogMapTable,
        in venue: WhereAmIVenueOption,
        subspace: Int? = nil,
        selectedAt: Date = .now
    ) -> MapDestination {
        MapDestination(
            sceneID: venue.placement.scene.id,
            tableID: table.id,
            blockName: table.blockName,
            subspace: subspace,
            venueDisplayName: venue.displayName,
            canonicalVenueName: table.hallName
                ?? canonicalVenueName(for: venue.placement.kind),
            point: point(at: table, subspace: subspace, in: venue.placement.scene),
            selectedAt: selectedAt
        )
    }

    private static func point(
        at table: CatalogMapTable,
        subspace: Int?,
        in scene: CatalogMapScene
    ) -> CGPoint {
        let size = scene.tableSize
        guard let subspace else {
            return CGPoint(
                x: table.origin.x + size.width / 2,
                y: table.origin.y + size.height / 2
            )
        }

        let aSide = subspace == 0
        return switch table.orientation {
        case .aLeft:
            CGPoint(
                x: table.origin.x + size.width * (aSide ? 0.25 : 0.75),
                y: table.origin.y + size.height / 2
            )
        case .aBottom:
            CGPoint(
                x: table.origin.x + size.width / 2,
                y: table.origin.y + size.height * (aSide ? 0.75 : 0.25)
            )
        case .aRight:
            CGPoint(
                x: table.origin.x + size.width * (aSide ? 0.75 : 0.25),
                y: table.origin.y + size.height / 2
            )
        case .aTop:
            CGPoint(
                x: table.origin.x + size.width / 2,
                y: table.origin.y + size.height * (aSide ? 0.25 : 0.75)
            )
        }
    }

    static func nearestTable(
        to point: CGPoint,
        in scene: CatalogMapScene
    ) -> CatalogMapTable? {
        scene.tables.min { lhs, rhs in
            distance(from: point, to: tableRect(lhs, in: scene))
                < distance(from: point, to: tableRect(rhs, in: scene))
        }
    }

    static func subspace(
        at point: CGPoint,
        in table: CatalogMapTable,
        scene: CatalogMapScene
    ) -> Int {
        let rect = tableRect(table, in: scene)
        return switch table.orientation {
        case .aLeft: point.x < rect.midX ? 0 : 1
        case .aBottom: point.y >= rect.midY ? 0 : 1
        case .aRight: point.x >= rect.midX ? 0 : 1
        case .aTop: point.y < rect.midY ? 0 : 1
        }
    }

    static func canonicalVenueName(for kind: BigSightVenuePlacement.Kind) -> String {
        switch kind {
        case .east123: "東1–3ホール"
        case .east456: "東4–6ホール"
        case .east7: "東7ホール"
        case .west: "西ホール"
        case .south: "南ホール"
        }
    }

    static func venueDisplayName(for hallName: String) -> String {
        let normalized = hallName.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        let digits = normalized.filter(\.isNumber)
        let range: String
        if let first = digits.first, let last = digits.last, digits.count > 1 {
            range = "\(first)–\(last)"
        } else {
            range = String(digits)
        }

        if normalized.contains("東") || normalized.uppercased().contains("EAST") {
            return range.isEmpty
                ? String(localized: "East Halls")
                : String(localized: "East \(range)")
        }
        if normalized.contains("西") || normalized.uppercased().contains("WEST") {
            return range.isEmpty
                ? String(localized: "West Halls")
                : String(localized: "West \(range)")
        }
        if normalized.contains("南") || normalized.uppercased().contains("SOUTH") {
            return range.isEmpty
                ? String(localized: "South Halls")
                : String(localized: "South \(range)")
        }
        return hallName
    }

    private static func distance(
        from lhs: GeographicCoordinate,
        to rhs: GeographicCoordinate
    ) -> Double {
        let earthRadius = 6_378_137.0
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let lhsLatitude = lhs.latitude * .pi / 180
        let rhsLatitude = rhs.latitude * .pi / 180
        let haversine =
            sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(lhsLatitude) * cos(rhsLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
    }

    private static func isUsable(_ reading: WhereAmILocationReading) -> Bool {
        reading.coordinate.latitude.isFinite
            && reading.coordinate.longitude.isFinite
            && (-90...90).contains(reading.coordinate.latitude)
            && (-180...180).contains(reading.coordinate.longitude)
            && reading.horizontalAccuracy >= 0
            && reading.horizontalAccuracy < 2_000
    }

    private static func tableRect(
        _ table: CatalogMapTable,
        in scene: CatalogMapScene
    ) -> CGRect {
        CGRect(origin: table.origin, size: scene.tableSize)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
