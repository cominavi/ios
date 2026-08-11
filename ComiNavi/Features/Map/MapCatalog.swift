import Foundation
import GRDB
import ImageIO

struct CatalogMapArtwork: Equatable, @unchecked Sendable {
    let name: String
    let pixelSize: CGSize
    let image: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.pixelSize == rhs.pixelSize
    }
}

struct CatalogMapScene: Identifiable, Equatable, Sendable {
    let id: ID
    let name: String
    let size: CGSize
    let tableSize: CGSize
    let tables: [CatalogMapTable]
    let tableByID: [CatalogMapTable.ID: CatalogMapTable]
    let blockLabels: [CatalogMapBlockLabel]
    /// Rotation encoded by circle.ms for placing the authored floor image.
    /// A value of π means the image and all of its table coordinates are reversed.
    let layoutRotation: CGFloat
    let artwork: CatalogMapArtwork?

    struct ID: Hashable, Sendable {
        let day: Int
        let mapID: Int
    }

    init(
        id: ID,
        name: String,
        size: CGSize,
        tableSize: CGSize,
        tables: [CatalogMapTable],
        layoutRotation: CGFloat = 0,
        artwork: CatalogMapArtwork? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.tableSize = tableSize
        self.tables = tables
        self.layoutRotation = layoutRotation
        self.artwork = artwork
        tableByID = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0) })
        blockLabels = Dictionary(grouping: tables, by: { $0.id.blockID })
            .values
            .compactMap { blockTables -> CatalogMapBlockLabel? in
                guard let first = blockTables.first else { return nil }
                let bounds = blockTables.dropFirst().reduce(
                    CGRect(origin: first.origin, size: tableSize)
                ) { partial, table in
                    partial.union(CGRect(origin: table.origin, size: tableSize))
                }
                return CatalogMapBlockLabel(
                    blockID: first.id.blockID,
                    name: first.blockName,
                    position: CGPoint(x: bounds.midX, y: bounds.midY)
                )
            }
    }
}

struct CatalogMapBlockLabel: Identifiable, Equatable, Sendable {
    var id: Int { blockID }

    let blockID: Int
    let name: String
    let position: CGPoint
}

struct CatalogMapTable: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let blockID: Int
        let spaceNumber: Int
    }

    enum Orientation: Int, Sendable {
        case aLeft = 1
        case aBottom = 2
        case aRight = 3
        case aTop = 4
    }

    let id: ID
    let blockName: String
    let origin: CGPoint
    let orientation: Orientation
    let hallName: String?

    init(
        id: ID,
        blockName: String,
        origin: CGPoint,
        orientation: Orientation,
        hallName: String? = nil
    ) {
        self.id = id
        self.blockName = blockName
        self.origin = origin
        self.orientation = orientation
        self.hallName = hallName
    }
}

struct CatalogMapCircle: Identifiable, Equatable, Sendable {
    let id: Int
    let publicCircleID: Int?
    let updateID: Int?
    let subspace: Int
    let circleName: String
    let penName: String
    let description: String
    let genreName: String?
    let circlemsURL: URL?
    let circlemsPortalURL: URL?

    init(
        id: Int,
        publicCircleID: Int?,
        updateID: Int?,
        subspace: Int,
        circleName: String,
        penName: String,
        description: String,
        genreName: String?,
        circlemsURL: URL?,
        circlemsPortalURL: URL? = nil
    ) {
        self.id = id
        self.publicCircleID = publicCircleID
        self.updateID = updateID
        self.subspace = subspace
        self.circleName = circleName
        self.penName = penName
        self.description = description
        self.genreName = genreName
        self.circlemsURL = circlemsURL
        self.circlemsPortalURL = circlemsPortalURL
    }
}

struct CatalogMapCirclePlacement: Identifiable, Equatable, Sendable {
    var id: Int { circleID }

    let circleID: Int
    let tableID: CatalogMapTable.ID
    let subspace: Int
}

/// Geometry for displaying a catalog cut over one half of a map table.
///
/// Circle cuts are portrait images, while vertically arranged tables provide a
/// landscape subspace. The database's table orientation identifies how the cut
/// must turn with the table; fitting in the cut's unrotated coordinate space
/// preserves its decoded pixel aspect ratio in every orientation.
struct CatalogCircleArtworkGeometry: Equatable, Sendable {
    let imageSize: CGSize
    let rotation: CGFloat

    var displayedBoundsSize: CGSize {
        switch normalizedQuarterTurn {
        case 1, 3:
            CGSize(width: imageSize.height, height: imageSize.width)
        default:
            imageSize
        }
    }

    static func fitting(
        pixelSize: CGSize,
        in containerSize: CGSize,
        orientation: CatalogMapTable.Orientation,
        occupancy: CGFloat = 0.9
    ) -> Self {
        guard pixelSize.width > 0,
              pixelSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0
        else {
            return Self(imageSize: .zero, rotation: rotation(for: orientation))
        }

        let rotation = rotation(for: orientation)
        let swapsAxes = orientation == .aBottom || orientation == .aTop
        let unrotatedContainer = swapsAxes
            ? CGSize(width: containerSize.height, height: containerSize.width)
            : containerSize
        let boundedOccupancy = max(0, min(occupancy, 1))
        let scale = min(
            unrotatedContainer.width / pixelSize.width,
            unrotatedContainer.height / pixelSize.height
        ) * boundedOccupancy

        return Self(
            imageSize: CGSize(
                width: pixelSize.width * scale,
                height: pixelSize.height * scale
            ),
            rotation: rotation
        )
    }

    private var normalizedQuarterTurn: Int {
        Int((rotation / (.pi / 2)).rounded()).modulo(4)
    }

    private static func rotation(for orientation: CatalogMapTable.Orientation) -> CGFloat {
        switch orientation {
        case .aLeft: 0
        case .aBottom: -.pi / 2
        case .aRight: .pi
        case .aTop: .pi / 2
        }
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct CatalogMapSearchMatch: Identifiable, Equatable, Sendable {
    let id: Int
    let tableID: CatalogMapTable.ID
    let subspace: Int
    let circleName: String
    let penName: String
}

struct CatalogMapGenrePlacement: Identifiable, Equatable, Sendable {
    var id: String { "\(tableID.blockID):\(tableID.spaceNumber):\(subspace)" }

    let tableID: CatalogMapTable.ID
    let subspace: Int
    let genreID: Int
    let genreName: String
}

struct CatalogBookmarkLocation: Equatable, Sendable {
    let publicCircleID: Int
    let catalogCircleID: Int
    let updateID: Int
    let day: Int
    let mapID: Int
    let tableID: CatalogMapTable.ID
    let subspace: Int
}

struct CatalogMapViewport: Equatable, Sendable {
    /// About seven 40-point tables fit the usable height of a modern iPhone at this scale.
    static let circleArtworkThreshold: CGFloat = 2.5

    let sceneID: CatalogMapScene.ID
    let mapRect: CGRect
    let renderedScale: CGFloat

    var wantsCircleArtwork: Bool {
        renderedScale >= Self.circleArtworkThreshold
    }
}

protocol MapCatalog: Sendable {
    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene
    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle]
    func circlePlacements(in viewport: CatalogMapViewport) async throws -> [CatalogMapCirclePlacement]
    func circleImages(circleIDs: [Int]) async throws -> [Int: Data]
    func search(day: Int, mapID: Int, query: String) async throws -> [CatalogMapSearchMatch]
    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement]
    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation]
    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation]
}

struct SQLiteMapCatalog: MapCatalog {
    let mainDatabase: any DatabaseReader
    let imageDatabase: any DatabaseReader
    private let index: MapCatalogIndex?

    init(
        mainDatabase: any DatabaseReader,
        imageDatabase: any DatabaseReader,
        index: MapCatalogIndex? = nil
    ) {
        self.mainDatabase = mainDatabase
        self.imageDatabase = imageDatabase
        self.index = index
    }

    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene {
        let (scene, mapFilename) = try await mainDatabase.read { database in
            guard let metadata = try Row.fetchOne(
                database,
                sql: """
                    SELECT map.name AS mapName,
                           map.filename AS mapFilename,
                           map.w2 AS mapWidth,
                           map.h2 AS mapHeight,
                           map.rotate AS mapRotation,
                           info.map2SizeW AS tableWidth,
                           info.map2SizeH AS tableHeight
                    FROM ComiketMapWC map
                    CROSS JOIN ComiketInfoWC info
                    WHERE map.id = ?
                    LIMIT 1
                    """,
                arguments: [mapID]
            ) else {
                throw MapCatalogError.missingMap(mapID)
            }

            let tables = try Row.fetchAll(
                database,
                sql: """
                    SELECT layout.blockId,
                           layout.spaceNo,
                           layout.xpos2,
                           layout.ypos2,
                           layout.layout,
                           block.name AS blockName,
                           area.name AS hallName
                    FROM ComiketLayoutWC layout
                    JOIN ComiketBlockWC block ON block.id = layout.blockId
                    LEFT JOIN ComiketAreaWC area ON area.id = layout.hallId
                    WHERE layout.mapId = ?
                    ORDER BY layout.ypos2, layout.xpos2
                    """,
                arguments: [mapID]
            ).compactMap { row -> CatalogMapTable? in
                guard let blockID: Int = row["blockId"],
                      let spaceNumber: Int = row["spaceNo"],
                      let x: Int = row["xpos2"],
                      let y: Int = row["ypos2"],
                      let orientationValue: Int = row["layout"],
                      let orientation = CatalogMapTable.Orientation(rawValue: orientationValue)
                else {
                    return nil
                }

                return CatalogMapTable(
                    id: .init(blockID: blockID, spaceNumber: spaceNumber),
                    blockName: row["blockName"] ?? "",
                    origin: CGPoint(x: x, y: y),
                    orientation: orientation,
                    hallName: row["hallName"]
                )
            }

            let mapWidth: Int = metadata["mapWidth"] ?? 0
            let mapHeight: Int = metadata["mapHeight"] ?? 0
            let tableWidth: Int = metadata["tableWidth"] ?? 40
            let tableHeight: Int = metadata["tableHeight"] ?? 40
            let mapRotation: Int = metadata["mapRotation"] ?? 0

            guard mapWidth > 0, mapHeight > 0 else {
                throw MapCatalogError.invalidMapDimensions(mapID)
            }

            let scene = CatalogMapScene(
                id: .init(day: day, mapID: mapID),
                name: metadata["mapName"] ?? "",
                size: CGSize(width: mapWidth, height: mapHeight),
                tableSize: CGSize(width: tableWidth, height: tableHeight),
                tables: tables,
                layoutRotation: mapRotation == 1 ? .pi : 0
            )
            let mapFilename: String = metadata["mapFilename"] ?? ""
            return (scene, mapFilename)
        }

        guard !mapFilename.isEmpty else { return scene }
        let artworkName = "LWMP\(day)\(mapFilename)"
        let artwork = try await imageDatabase.read { database -> CatalogMapArtwork? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT width, height, image
                    FROM ComiketCommonImage
                    WHERE name = ?
                    LIMIT 1
                    """,
                arguments: [artworkName]
            ),
                let width: Int = row["width"],
                let height: Int = row["height"],
                let data: Data = row["image"],
                CGSize(width: width, height: height) == scene.size,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                image.width == width,
                image.height == height
            else {
                return nil
            }
            return CatalogMapArtwork(
                name: artworkName,
                pixelSize: CGSize(width: width, height: height),
                image: image
            )
        }

        return CatalogMapScene(
            id: scene.id,
            name: scene.name,
            size: scene.size,
            tableSize: scene.tableSize,
            tables: scene.tables,
            layoutRotation: scene.layoutRotation,
            artwork: artwork
        )
    }

    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle] {
        try await mainDatabase.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT circle.id,
                           circleExtension.WCId AS publicCircleId,
                           circle.updateId,
                           circle.spaceNoSub,
                           circle.circleName,
                           circle.penName,
                           circle.description,
                           circle.circlems,
                           circleExtension.CirclemsPortalURL,
                           genre.name AS genreName
                    FROM ComiketCircleWC circle
                    LEFT JOIN ComiketCircleExtend circleExtension ON circleExtension.id = circle.id
                    LEFT JOIN ComiketGenreWC genre ON genre.id = circle.genreId
                    WHERE circle.day = ?
                      AND circle.blockId = ?
                      AND circle.spaceNo = ?
                    ORDER BY circle.spaceNoSub
                    """,
                arguments: [day, tableID.blockID, tableID.spaceNumber]
            ).compactMap { row -> CatalogMapCircle? in
                guard let id: Int = row["id"] else { return nil }
                let urlString: String? = row["circlems"]
                let portalURLString: String? = row["CirclemsPortalURL"]
                return CatalogMapCircle(
                    id: id,
                    publicCircleID: row["publicCircleId"],
                    updateID: row["updateId"],
                    subspace: row["spaceNoSub"] ?? 0,
                    circleName: row["circleName"] ?? "",
                    penName: row["penName"] ?? "",
                    description: row["description"] ?? "",
                    genreName: row["genreName"],
                    circlemsURL: urlString.flatMap(URL.init(string:)),
                    circlemsPortalURL: portalURLString.flatMap(URL.init(string:))
                )
            }
        }
    }

    func circlePlacements(in viewport: CatalogMapViewport) async throws -> [CatalogMapCirclePlacement] {
        guard viewport.wantsCircleArtwork else { return [] }
        if let index {
            return try await index.placements(in: viewport)
        }
        let queryRect = viewport.mapRect.insetBy(dx: -40, dy: -40)

        return try await mainDatabase.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT circle.id,
                           circle.spaceNoSub,
                           circle.blockId,
                           circle.spaceNo
                    FROM ComiketCircleWC circle
                    JOIN ComiketLayoutWC layout
                      ON layout.blockId = circle.blockId
                     AND layout.spaceNo = circle.spaceNo
                    WHERE circle.day = ?
                      AND layout.mapId = ?
                      AND layout.xpos2 BETWEEN ? AND ?
                      AND layout.ypos2 BETWEEN ? AND ?
                    """,
                arguments: [
                    viewport.sceneID.day,
                    viewport.sceneID.mapID,
                    Int(queryRect.minX.rounded(.down)),
                    Int(queryRect.maxX.rounded(.up)),
                    Int(queryRect.minY.rounded(.down)),
                    Int(queryRect.maxY.rounded(.up)),
                ]
            ).compactMap { row -> CatalogMapCirclePlacement? in
                guard let circleID: Int = row["id"],
                      let blockID: Int = row["blockId"],
                      let spaceNumber: Int = row["spaceNo"]
                else {
                    return nil
                }
                return CatalogMapCirclePlacement(
                    circleID: circleID,
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
                    subspace: row["spaceNoSub"] ?? 0
                )
            }
        }
    }

    func circleImages(circleIDs: [Int]) async throws -> [Int: Data] {
        let uniqueIDs = Array(Set(circleIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")

        return try await imageDatabase.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT id, cutImage FROM ComiketCircleImage WHERE id IN (\(placeholders))",
                arguments: StatementArguments(uniqueIDs)
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id: Int = row["id"], let data: Data = row["cutImage"] else { return nil }
                return (id, data)
            })
        }
    }

    func search(day: Int, mapID: Int, query: String) async throws -> [CatalogMapSearchMatch] {
        let terms = JapaneseSearchNormalizer.normalizedTerms(in: query)
        guard !terms.isEmpty else { return [] }
        if let index, terms.allSatisfy({ $0.unicodeScalars.count >= 3 }) {
            return try await index.search(
                day: day,
                mapID: mapID,
                normalizedTerms: terms
            )
        }

        return try await mainDatabase.read { database in
            let rows = try Row.fetchCursor(
                database,
                sql: """
                    SELECT circle.id,
                           circle.blockId,
                           circle.spaceNo,
                           circle.spaceNoSub,
                           circle.circleName,
                           circle.circleKana,
                           circle.penName,
                           circle.description
                    FROM ComiketCircleWC circle
                    JOIN ComiketLayoutWC layout
                      ON layout.blockId = circle.blockId
                     AND layout.spaceNo = circle.spaceNo
                    WHERE circle.day = ?
                      AND layout.mapId = ?
                    ORDER BY circle.blockId, circle.spaceNo, circle.spaceNoSub
                    """,
                arguments: [day, mapID]
            )
            var matches: [CatalogMapSearchMatch] = []
            matches.reserveCapacity(1000)

            while let row = try rows.next() {
                guard let id: Int = row["id"],
                      let blockID: Int = row["blockId"],
                      let spaceNumber: Int = row["spaceNo"]
                else {
                    continue
                }
                let circleName: String = row["circleName"] ?? ""
                let penName: String = row["penName"] ?? ""
                guard JapaneseSearchNormalizer.containsAll(
                    terms,
                    in: [
                        circleName,
                        row["circleKana"] ?? "",
                        penName,
                        row["description"] ?? "",
                    ]
                ) else {
                    continue
                }

                matches.append(CatalogMapSearchMatch(
                    id: id,
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
                    subspace: row["spaceNoSub"] ?? 0,
                    circleName: circleName,
                    penName: penName
                ))
                if matches.count == 1000 { break }
            }
            return matches
        }
    }

    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement] {
        try await mainDatabase.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT circle.blockId,
                           circle.spaceNo,
                           circle.spaceNoSub,
                           genre.id AS genreId,
                           genre.name AS genreName
                    FROM ComiketCircleWC circle
                    JOIN ComiketLayoutWC layout
                      ON layout.blockId = circle.blockId
                     AND layout.spaceNo = circle.spaceNo
                    JOIN ComiketGenreWC genre ON genre.id = circle.genreId
                    WHERE circle.day = ?
                      AND layout.mapId = ?
                    """,
                arguments: [day, mapID]
            ).compactMap { row -> CatalogMapGenrePlacement? in
                guard let blockID: Int = row["blockId"],
                      let spaceNumber: Int = row["spaceNo"],
                      let genreID: Int = row["genreId"]
                else {
                    return nil
                }
                return CatalogMapGenrePlacement(
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
                    subspace: row["spaceNoSub"] ?? 0,
                    genreID: genreID,
                    genreName: row["genreName"] ?? ""
                )
            }
        }
    }

    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        let uniqueIDs = Array(Set(updateIDs))
        guard !uniqueIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
        let arguments = StatementArguments(uniqueIDs)

        return try await mainDatabase.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT circleExtension.WCId AS publicCircleId,
                           circle.id AS catalogCircleId,
                           circle.updateId,
                           circle.day,
                           circle.blockId,
                           circle.spaceNo,
                           circle.spaceNoSub,
                           layout.mapId
                    FROM ComiketCircleWC circle
                    JOIN ComiketCircleExtend circleExtension ON circleExtension.id = circle.id
                    JOIN ComiketLayoutWC layout
                      ON layout.blockId = circle.blockId
                     AND layout.spaceNo = circle.spaceNo
                    WHERE circle.updateId IN (\(placeholders))
                    """,
                arguments: arguments
            ).compactMap { row -> CatalogBookmarkLocation? in
                guard let publicCircleID: Int = row["publicCircleId"],
                      let catalogCircleID: Int = row["catalogCircleId"],
                      let updateID: Int = row["updateId"],
                      let day: Int = row["day"],
                      let mapID: Int = row["mapId"],
                      let blockID: Int = row["blockId"],
                      let spaceNumber: Int = row["spaceNo"]
                else {
                    return nil
                }
                return CatalogBookmarkLocation(
                    publicCircleID: publicCircleID,
                    catalogCircleID: catalogCircleID,
                    updateID: updateID,
                    day: day,
                    mapID: mapID,
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
                    subspace: row["spaceNoSub"] ?? 0
                )
            }
        }
    }

    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        let uniqueIDs = Array(Set(publicCircleIDs))
        guard !uniqueIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
        let arguments = StatementArguments(uniqueIDs)

        return try await mainDatabase.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT circleExtension.WCId AS publicCircleId,
                           circle.id AS catalogCircleId,
                           circle.updateId,
                           circle.day,
                           circle.blockId,
                           circle.spaceNo,
                           circle.spaceNoSub,
                           layout.mapId
                    FROM ComiketCircleWC circle
                    JOIN ComiketCircleExtend circleExtension ON circleExtension.id = circle.id
                    JOIN ComiketLayoutWC layout
                      ON layout.blockId = circle.blockId
                     AND layout.spaceNo = circle.spaceNo
                    WHERE circleExtension.WCId IN (\(placeholders))
                    """,
                arguments: arguments
            ).compactMap(Self.bookmarkLocation)
        }
    }

    private static func bookmarkLocation(_ row: Row) -> CatalogBookmarkLocation? {
        guard let publicCircleID: Int = row["publicCircleId"],
              let catalogCircleID: Int = row["catalogCircleId"],
              let updateID: Int = row["updateId"],
              let day: Int = row["day"],
              let mapID: Int = row["mapId"],
              let blockID: Int = row["blockId"],
              let spaceNumber: Int = row["spaceNo"]
        else { return nil }
        return CatalogBookmarkLocation(
            publicCircleID: publicCircleID,
            catalogCircleID: catalogCircleID,
            updateID: updateID,
            day: day,
            mapID: mapID,
            tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
            subspace: row["spaceNoSub"] ?? 0
        )
    }

}

enum MapCatalogError: LocalizedError {
    case missingMap(Int)
    case invalidMapDimensions(Int)

    var errorDescription: String? {
        switch self {
        case .missingMap(let mapID):
            String(localized: "The catalog does not contain map \(mapID).")
        case .invalidMapDimensions(let mapID):
            String(localized: "Map \(mapID) has invalid dimensions.")
        }
    }
}

#if DEBUG
struct FixtureMapCatalog: MapCatalog {
    private let fixtureScene: CatalogMapScene

    init() {
        let tableSize = CGSize(width: 40, height: 40)
        var tables: [CatalogMapTable] = [
            CatalogMapTable(
                id: .init(blockID: 99, spaceNumber: 1),
                blockName: "Test",
                origin: CGPoint(x: 340, y: 320),
                orientation: .aLeft
            ),
        ]
        for column in 0 ..< 6 {
            for row in 0 ..< 10 {
                tables.append(CatalogMapTable(
                    id: .init(blockID: column + 1, spaceNumber: row + 1),
                    blockName: String(UnicodeScalar(65 + column)!),
                    origin: CGPoint(x: 80 + column * 100, y: 80 + row * 52),
                    orientation: column.isMultiple(of: 2) ? .aLeft : .aTop
                ))
            }
        }
        fixtureScene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "Fixture Hall",
            size: CGSize(width: 720, height: 680),
            tableSize: tableSize,
            tables: tables
        )
    }

    func scene(day: Int, mapID: Int) async throws -> CatalogMapScene {
        guard mapID != 1 else { return fixtureScene }
        let campusSize: CGSize
        let name: String
        switch mapID {
        case 101:
            (campusSize, name) = (CGSize(width: 4_680, height: 1_760), "E123")
        case 102:
            (campusSize, name) = (CGSize(width: 2_440, height: 2_640), "E7")
        case 103:
            (campusSize, name) = (CGSize(width: 3_600, height: 2_680), "W12")
        case 104:
            (campusSize, name) = (CGSize(width: 2_480, height: 1_360), "S12")
        default:
            throw MapCatalogError.missingMap(mapID)
        }
        let scaleX = campusSize.width / fixtureScene.size.width
        let scaleY = campusSize.height / fixtureScene.size.height
        return CatalogMapScene(
            id: .init(day: day, mapID: mapID),
            name: name,
            size: campusSize,
            tableSize: fixtureScene.tableSize,
            tables: fixtureScene.tables.map { table in
                CatalogMapTable(
                    id: table.id,
                    blockName: table.blockName,
                    origin: CGPoint(x: table.origin.x * scaleX, y: table.origin.y * scaleY),
                    orientation: table.orientation,
                    hallName: table.hallName
                )
            }
        )
    }

    func circles(day: Int, tableID: CatalogMapTable.ID) async throws -> [CatalogMapCircle] {
        [
            CatalogMapCircle(
                id: tableID.blockID * 100 + tableID.spaceNumber * 2,
                publicCircleID: tableID.blockID * 100 + tableID.spaceNumber * 2,
                updateID: nil,
                subspace: 0,
                circleName: "Fixture Circle A",
                penName: "Map Tester",
                description: "Deterministic map fixture",
                genreName: "Testing",
                circlemsURL: nil
            ),
            CatalogMapCircle(
                id: tableID.blockID * 100 + tableID.spaceNumber * 2 + 1,
                publicCircleID: tableID.blockID * 100 + tableID.spaceNumber * 2 + 1,
                updateID: nil,
                subspace: 1,
                circleName: "Fixture Circle B",
                penName: "Map Tester",
                description: "Deterministic map fixture",
                genreName: "Testing",
                circlemsURL: nil
            ),
        ]
    }

    func circlePlacements(in viewport: CatalogMapViewport) async throws -> [CatalogMapCirclePlacement] {
        guard viewport.wantsCircleArtwork else { return [] }
        return fixtureScene.tables.filter { table in
            CGRect(origin: table.origin, size: fixtureScene.tableSize)
                .intersects(viewport.mapRect.insetBy(dx: -40, dy: -40))
        }.flatMap { table in
            [
                CatalogMapCirclePlacement(
                    circleID: table.id.blockID * 100 + table.id.spaceNumber * 2,
                    tableID: table.id,
                    subspace: 0
                ),
                CatalogMapCirclePlacement(
                    circleID: table.id.blockID * 100 + table.id.spaceNumber * 2 + 1,
                    tableID: table.id,
                    subspace: 1
                ),
            ]
        }
    }

    func circleImages(circleIDs: [Int]) async throws -> [Int: Data] {
        guard let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: Set(circleIDs).map { ($0, image) })
    }

    func search(day: Int, mapID: Int, query: String) async throws -> [CatalogMapSearchMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let table = fixtureScene.tables[0]
        return [
            CatalogMapSearchMatch(
                id: table.id.blockID * 100 + 2,
                tableID: table.id,
                subspace: 0,
                circleName: "Fixture Circle A",
                penName: "Map Tester"
            ),
        ]
    }

    func genrePlacements(day: Int, mapID: Int) async throws -> [CatalogMapGenrePlacement] {
        fixtureScene.tables.enumerated().flatMap { index, table in
            [0, 1].map { subspace in
                CatalogMapGenrePlacement(
                    tableID: table.id,
                    subspace: subspace,
                    genreID: (index % 6) + 1,
                    genreName: "Fixture Genre \((index % 6) + 1)"
                )
            }
        }
    }

    func bookmarkLocations(updateIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        fixtureScene.tables.flatMap { table in
            [0, 1].map { subspace in
                let circleID = table.id.blockID * 100 + table.id.spaceNumber * 2 + subspace
                return CatalogBookmarkLocation(
                    publicCircleID: circleID,
                    catalogCircleID: circleID,
                    updateID: circleID,
                    day: 1,
                    mapID: 1,
                    tableID: table.id,
                    subspace: subspace
                )
            }
        }.filter { updateIDs.contains($0.updateID) }
    }

    func bookmarkLocations(publicCircleIDs: [Int]) async throws -> [CatalogBookmarkLocation] {
        fixtureScene.tables.flatMap { table in
            [0, 1].map { subspace in
                let circleID = table.id.blockID * 100 + table.id.spaceNumber * 2 + subspace
                return CatalogBookmarkLocation(
                    publicCircleID: circleID,
                    catalogCircleID: circleID,
                    updateID: circleID,
                    day: 1,
                    mapID: 1,
                    tableID: table.id,
                    subspace: subspace
                )
            }
        }.filter { publicCircleIDs.contains($0.publicCircleID) }
    }
}
#endif
