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

    /// How a space address is shown to attendees. Every screen that names a
    /// space (Explore cards, circle details, map search, the location sheet)
    /// uses these styles, so one address reads the same everywhere. The
    /// Japanese `canonicalText` remains the copy and staff-facing form.
    enum DisplayStyle: Sendable {
        /// Hall direction and space code: "West あ02a".
        case short
        /// Day, hall, and space code: "Day 1 · West 1 · あ02a".
        case full
    }

    /// The English-first hall name, e.g. "East 1" or "West Halls".
    var localizedHallName: String {
        BigSightVenue.localizedHallName(forCatalogName: hallName)
    }

    func formatted(_ style: DisplayStyle) -> String {
        switch style {
        case .short:
            guard let direction = BigSightVenue.direction(matching: hallName) else {
                return spaceCode
            }
            let name = direction.localizedName
            // A kanji direction joins the code with no space ("西あ01a"),
            // like the venue signs, so the address reads as one unit.
            // Latin and Hangul names keep the space ("West あ01a").
            let isIdeographic =
                name.unicodeScalars.last?.properties.isIdeographic ?? false
            return isIdeographic ? "\(name)\(spaceCode)" : "\(name) \(spaceCode)"
        case .full:
            return String(
                localized: "Day \(day) · \(localizedHallName) · \(spaceCode)",
                comment: "Full space address: event day, hall name, and space code"
            )
        }
    }

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

/// A space code typed into map search, such as "東A01a", "1日目 西あ12",
/// "Day 2 East ア-34b", or a bare "シ01".
///
/// Attendees usually know a circle by its space code, so search resolves the
/// code directly instead of sending them through the block-and-number flow.
struct ComiketSpaceCodeQuery: Equatable, Sendable {
    let day: Int?
    let direction: BigSightVenue.Direction?
    /// The block character with full-width Latin letters folded to ASCII.
    let blockName: String
    let spaceNumber: Int
    /// 0 for the a side, 1 for the b side, `nil` for the whole table.
    let subspace: Int?

    static func parse(_ query: String) -> Self? {
        var rest = Substring(normalized(query))
        guard !rest.isEmpty else { return nil }

        let day = consumeDay(from: &rest)
        var afterDirection = rest
        if let direction = consumeDirection(from: &afterDirection),
            let code = parseSpace(afterDirection, day: day, direction: direction)
        {
            return code
        }
        return parseSpace(rest, day: day, direction: nil)
    }

    private static func parseSpace(
        _ value: Substring,
        day: Int?,
        direction: BigSightVenue.Direction?
    ) -> Self? {
        var rest = value
        guard let first = rest.first, let block = blockCharacter(first) else { return nil }
        rest.removeFirst()

        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...2).contains(digits.count), let spaceNumber = Int(digits), spaceNumber > 0
        else {
            return nil
        }
        rest.removeFirst(digits.count)

        let subspace: Int?
        switch rest.lowercased() {
        case "": subspace = nil
        case "a": subspace = 0
        case "b": subspace = 1
        case "ab", "a+b": subspace = nil
        default: return nil
        }

        return Self(
            day: day,
            direction: direction,
            blockName: block,
            spaceNumber: spaceNumber,
            subspace: subspace
        )
    }

    /// Whether a catalog block name is the block this query names. Block
    /// letters are case-sensitive at Comiket, so `ignoringCase` is only a
    /// fallback when no exact block exists.
    func matches(blockName candidate: String, ignoringCase: Bool = false) -> Bool {
        let folded = Self.foldingFullWidthASCII(candidate)
        return ignoringCase
            ? folded.lowercased() == blockName.lowercased()
            : folded == blockName
    }

    /// Comiket blocks are Latin letters or kana; kanji such as 西 never are.
    /// Half-width katakana is widened so "ｼ01" finds block シ.
    private static func blockCharacter(_ character: Character) -> String? {
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else {
            return nil
        }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x3041...0x309F, 0x30A1...0x30FA:
            return String(character)
        case 0xFF66...0xFF9D:
            return String(character).applyingTransform(.fullwidthToHalfwidth, reverse: true)
        default:
            return nil
        }
    }

    private static func consumeDay(from rest: inout Substring) -> Int? {
        if let digit = rest.first, digit.isASCII, let day = digit.wholeNumberValue,
            rest.dropFirst().hasPrefix("日目")
        {
            rest.removeFirst(1 + "日目".count)
            return day
        }
        if rest.lowercased().hasPrefix("day"),
            let digit = rest.dropFirst(3).first,
            digit.isASCII,
            let day = digit.wholeNumberValue
        {
            rest.removeFirst(4)
            return day
        }
        return nil
    }

    private static func consumeDirection(from rest: inout Substring) -> BigSightVenue.Direction? {
        let prefixes: [(String, BigSightVenue.Direction)] = [
            ("東", .east), ("西", .west), ("南", .south),
            ("east", .east), ("west", .west), ("south", .south),
        ]
        let lowered = rest.lowercased()
        for (prefix, direction) in prefixes where lowered.hasPrefix(prefix) {
            // Only whole English words count, so the block letter in a code
            // such as "E12" or "S03a" is never read as a direction.
            rest.removeFirst(prefix.count)
            return direction
        }
        return nil
    }

    private static func normalized(_ query: String) -> String {
        foldingFullWidthASCII(query).filter { character in
            !character.isWhitespace && !"-‐–・·_".contains(character)
        }
    }

    private static func foldingFullWidthASCII(_ value: String) -> String {
        String(
            String.UnicodeScalarView(
                value.unicodeScalars.map { scalar -> Unicode.Scalar in
                    if (0xFF01...0xFF5E).contains(scalar.value),
                        let ascii = UnicodeScalar(scalar.value - 0xFEE0)
                    {
                        return ascii
                    }
                    return scalar
                }
            )
        )
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

    var address: ComiketSpaceAddress {
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

    var address: ComiketSpaceAddress {
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
