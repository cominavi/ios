import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class FavoriteColorLabelStore {
    static let defaultsKey = "cominavi.favorite-color-labels.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var customLabels: [BookmarkColor: String]
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        customLabels = stored.reduce(into: [:]) { result, entry in
            guard let rawValue = Int(entry.key),
                  let color = BookmarkColor(rawValue: rawValue),
                  color.isFavorite,
                  let label = Self.normalized(entry.value)
            else { return }
            result[color] = label
        }
    }

    func label(for color: BookmarkColor) -> String {
        customLabels[color] ?? String(localized: color.displayName)
    }

    func replace(with labels: [BookmarkColor: String]) {
        customLabels = labels.reduce(into: [:]) { result, entry in
            guard entry.key.isFavorite,
                  let label = Self.normalized(entry.value)
            else { return }
            result[entry.key] = label
        }
        persist()
        revision &+= 1
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: customLabels.map {
            (String($0.key.rawValue), $0.value)
        })
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }
}

struct FavoriteColorLabelsScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: FavoriteColorLabelStore
    @State private var labels: [BookmarkColor: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(BookmarkColor.selectableColors) { color in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(color.swiftUIColor)
                            .overlay {
                                Circle().stroke(.black.opacity(0.12), lineWidth: 0.5)
                            }
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: color.displayName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(
                                "Label",
                                text: binding(for: color),
                                prompt: Text(String(localized: color.displayName))
                            )
                            .textInputAutocapitalization(.sentences)
                            .accessibilityIdentifier("favorite-color-label-\(color.rawValue)")
                        }
                    }
                }
            } footer: {
                Text("Labels are shown in the PDF legend and circle list.")
            }
        }
        .navigationTitle("Color labels")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            labels = store.customLabels
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.replace(with: labels)
                    dismiss()
                }
            }
        }
    }

    private func binding(for color: BookmarkColor) -> Binding<String> {
        Binding(
            get: { labels[color] ?? "" },
            set: { labels[color] = String($0.prefix(40)) }
        )
    }
}

struct FavoriteMapPDFCircle: Identifiable, Sendable {
    let id: Int
    var number: Int
    let color: BookmarkColor
    let colorLabel: String
    let day: Int
    let mapID: Int
    let tableID: CatalogMapTable.ID
    let subspace: Int
    let hallName: String
    let blockName: String
    let spaceNumber: Int
    let isCombinedAB: Bool
    let circleName: String
    let penName: String?
    let memo: String?

    var spaceCode: String {
        ComiketSpaceAddress.spaceCode(
            blockName: blockName,
            spaceNumber: spaceNumber,
            subspace: subspace,
            isCombinedAB: isCombinedAB
        )
    }

    var locationLabel: String {
        "\(ComiketSpaceAddress.canonicalHallName(hallName)) \(spaceCode)"
    }

    var dayAndSpace: String {
        String(localized: "Day \(day) · \(locationLabel)")
    }
}

struct FavoriteMapPDFHall: Identifiable, Sendable {
    var id: CatalogMapScene.ID { scene.id }

    let name: String
    let scene: CatalogMapScene
    let circles: [FavoriteMapPDFCircle]

    var groupedCircles: [(color: BookmarkColor, label: String, circles: [FavoriteMapPDFCircle])] {
        BookmarkColor.selectableColors.compactMap { color in
            let members = circles.filter { $0.color == color }
            guard let first = members.first else { return nil }
            return (color, first.colorLabel, members)
        }
    }
}

struct FavoriteMapPDFDocument: Sendable {
    let eventNumber: Int
    let eventTitle: String
    let halls: [FavoriteMapPDFHall]

    var circleCount: Int { halls.reduce(0) { $0 + $1.circles.count } }
}

@MainActor
enum FavoriteMapPDFLoader {
    static func load(
        from dataSource: CirclemsDataSource,
        colorLabels: [BookmarkColor: String]
    ) async throws -> FavoriteMapPDFDocument {
        let eventNumber = dataSource.comiket.number
        let bookmarks = try await dataSource.userPlanStore
            .allBookmarks(eventNumber: eventNumber)
            .filter(\.isFavorite)
        let circlesByPublicID = await dataSource.getCircles(
            publicCircleIDs: bookmarks.map(\.publicCircleID)
        )
        let hallMetadata = dataSource.comiket.days.flatMap { day in
            day.halls.map { hall in
                (CatalogMapScene.ID(day: day.dayIndex, mapID: hall.externalMapId), hall)
            }
        }
        let hallsByID = Dictionary(uniqueKeysWithValues: hallMetadata)
        let hallOrder = Dictionary(uniqueKeysWithValues: hallMetadata.enumerated().map {
            ($0.element.0, $0.offset)
        })
        let bookmarkGroups = Dictionary(grouping: bookmarks) {
            CatalogMapScene.ID(day: $0.day, mapID: $0.mapID)
        }
        let orderedIDs = bookmarkGroups.keys.sorted {
            (hallOrder[$0] ?? .max, $0.day, $0.mapID)
                < (hallOrder[$1] ?? .max, $1.day, $1.mapID)
        }

        var halls: [FavoriteMapPDFHall] = []
        for sceneID in orderedIDs {
            guard let bookmarks = bookmarkGroups[sceneID] else { continue }
            let scene = try await dataSource.mapCatalog.scene(
                day: sceneID.day,
                mapID: sceneID.mapID
            )
            var combinedTableIDs: Set<CatalogMapTable.ID> = []
            for tableID in Set(bookmarks.map(\.tableID)) {
                let members = try await dataSource.mapCatalog.circles(
                    day: sceneID.day,
                    tableID: tableID
                )
                if CatalogCirclePairing.isCombinedAB(members) {
                    combinedTableIDs.insert(tableID)
                }
            }
            var items = bookmarks.map { bookmark in
                let circle = circlesByPublicID[bookmark.publicCircleID]
                let table = scene.tableByID[bookmark.tableID]
                let hallName = normalized(table?.hallName)
                    ?? normalized(hallsByID[sceneID]?.name)
                    ?? scene.name
                let blockName = normalized(table?.blockName)
                let circleName = normalized(circle?.circleName)
                let penName = normalized(circle?.penName)
                let memo = normalized(bookmark.memo)

                return FavoriteMapPDFCircle(
                    id: bookmark.publicCircleID,
                    number: 0,
                    color: bookmark.color,
                    colorLabel: colorLabels[bookmark.color]
                        ?? String(localized: bookmark.color.displayName),
                    day: bookmark.day,
                    mapID: bookmark.mapID,
                    tableID: bookmark.tableID,
                    subspace: bookmark.subspace,
                    hallName: hallName,
                    blockName: blockName ?? "?",
                    spaceNumber: bookmark.tableID.spaceNumber,
                    isCombinedAB: combinedTableIDs.contains(bookmark.tableID),
                    circleName: circleName ?? String(localized: "Unnamed circle"),
                    penName: penName,
                    memo: memo
                )
            }
            let hallName = normalized(hallsByID[sceneID]?.name)
            items.sort(by: circleSort)
            for index in items.indices {
                items[index].number = index + 1
            }
            halls.append(FavoriteMapPDFHall(
                name: hallName ?? scene.name,
                scene: scene,
                circles: items
            ))
        }

        return FavoriteMapPDFDocument(
            eventNumber: eventNumber,
            eventTitle: String(localized: "Comic Market \(eventNumber)"),
            halls: halls
        )
    }

    private static func circleSort(
        _ lhs: FavoriteMapPDFCircle,
        _ rhs: FavoriteMapPDFCircle
    ) -> Bool {
        if lhs.color != rhs.color { return lhs.color.rawValue < rhs.color.rawValue }
        let blockComparison = lhs.blockName.localizedStandardCompare(rhs.blockName)
        if blockComparison != .orderedSame { return blockComparison == .orderedAscending }
        if lhs.spaceNumber != rhs.spaceNumber { return lhs.spaceNumber < rhs.spaceNumber }
        if lhs.subspace != rhs.subspace { return lhs.subspace < rhs.subspace }
        return lhs.circleName.localizedStandardCompare(rhs.circleName) == .orderedAscending
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum FavoriteMapPDFRenderer {
    static let pageSize = CGSize(width: 841.89, height: 595.28)

    private static let pageBounds = CGRect(origin: .zero, size: pageSize)
    private static let horizontalMargin: CGFloat = 28
    private static let headerBottom: CGFloat = 54
    private static let footerTop: CGFloat = pageSize.height - 22
    private static let groupHeight: CGFloat = 22
    private static let rowHeight: CGFloat = 28
    private static let ink = UIColor(white: 0.10, alpha: 1)
    private static let mutedInk = UIColor(white: 0.38, alpha: 1)
    private static let quietInk = UIColor(white: 0.62, alpha: 1)
    private static let hairline = UIColor(white: 0.84, alpha: 1)
    private static let subtleFill = UIColor(white: 0.96, alpha: 1)

    enum ListLine {
        case group(BookmarkColor, String, Int)
        case circle(FavoriteMapPDFCircle)

        var height: CGFloat {
            switch self {
            case .group: 22
            case .circle: 28
            }
        }
    }

    enum Page {
        case map(FavoriteMapPDFHall)
        case list(FavoriteMapPDFHall, [ListLine])
    }

    static func pages(for document: FavoriteMapPDFDocument) -> [Page] {
        document.halls.flatMap { hall in
            [.map(hall)] + listPages(for: hall).map { .list(hall, $0) }
        }
    }

    static func render(_ document: FavoriteMapPDFDocument) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Favorite map"),
            kCGPDFContextCreator as String: "ComiNavi",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        let pages = pages(for: document)

        return renderer.pdfData { context in
            for (index, page) in pages.enumerated() {
                context.beginPage()
                drawPageBackground()
                switch page {
                case .map(let hall):
                    drawHeader(
                        document: document,
                        hall: hall,
                        kind: String(localized: "Map"),
                        pageNumber: index + 1,
                        pageCount: pages.count
                    )
                    drawMapPage(hall)
                case .list(let hall, let lines):
                    drawHeader(
                        document: document,
                        hall: hall,
                        kind: String(localized: "Circle list"),
                        pageNumber: index + 1,
                        pageCount: pages.count
                    )
                    drawListPage(lines)
                }
                drawFooter()
            }
        }
    }

    private static func listPages(for hall: FavoriteMapPDFHall) -> [[ListLine]] {
        let availableHeight = footerTop - headerBottom - 8
        var pages: [[ListLine]] = []
        var current: [ListLine] = []
        var usedHeight: CGFloat = 0

        func finishPage() {
            guard !current.isEmpty else { return }
            pages.append(current)
            current = []
            usedHeight = 0
        }

        for group in hall.groupedCircles {
            if !current.isEmpty,
               usedHeight + groupHeight + rowHeight > availableHeight
            {
                finishPage()
            }
            current.append(.group(group.color, group.label, group.circles.count))
            usedHeight += groupHeight

            for circle in group.circles {
                if !current.isEmpty, usedHeight + rowHeight > availableHeight {
                    finishPage()
                    current.append(.group(group.color, group.label, group.circles.count))
                    usedHeight += groupHeight
                }
                current.append(.circle(circle))
                usedHeight += rowHeight
            }
        }
        finishPage()
        return pages
    }

    private static func drawPageBackground() {
        UIColor.white.setFill()
        UIRectFill(pageBounds)
    }

    private static func drawHeader(
        document: FavoriteMapPDFDocument,
        hall: FavoriteMapPDFHall,
        kind: String,
        pageNumber: Int,
        pageCount: Int
    ) {
        let title = "\(document.eventTitle) · \(String(localized: "Day \(hall.scene.id.day)")) · \(hall.name)"
        drawText(
            title,
            in: CGRect(x: horizontalMargin, y: 17, width: 590, height: 23),
            font: .systemFont(ofSize: 16, weight: .semibold),
            color: ink
        )
        drawText(
            kind,
            in: CGRect(x: 625, y: 19, width: 90, height: 18),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: mutedInk,
            alignment: .right
        )
        drawText(
            String(localized: "Page \(pageNumber) of \(pageCount)"),
            in: CGRect(x: 720, y: 17, width: 94, height: 20),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: mutedInk,
            alignment: .right
        )
        hairline.setFill()
        UIRectFill(CGRect(x: horizontalMargin, y: 45, width: pageSize.width - 56, height: 0.5))
    }

    private static func drawMapPage(_ hall: FavoriteMapPDFHall) {
        let legendBottom = drawLegend(hall.groupedCircles, y: headerBottom)
        let container = CGRect(
            x: horizontalMargin,
            y: legendBottom + 5,
            width: pageSize.width - horizontalMargin * 2,
            height: footerTop - legendBottom - 10
        )
        let mapRect = aspectFit(hall.scene.size, in: container.insetBy(dx: 4, dy: 4))

        subtleFill.setFill()
        UIBezierPath(roundedRect: container, cornerRadius: 4).fill()
        UIColor.white.setFill()
        UIRectFill(mapRect)

        if let artwork = hall.scene.artwork {
            UIImage(cgImage: artwork.image).draw(in: mapRect)
        } else {
            drawFallbackMap(hall.scene, in: mapRect)
        }
        drawFavoriteMarkers(hall, in: mapRect)

        hairline.setStroke()
        let border = UIBezierPath(rect: mapRect)
        border.lineWidth = 0.6
        border.stroke()
    }

    private static func drawLegend(
        _ groups: [(color: BookmarkColor, label: String, circles: [FavoriteMapPDFCircle])],
        y: CGFloat
    ) -> CGFloat {
        var x = horizontalMargin
        var rowY = y
        let maxX = pageSize.width - horizontalMargin

        for group in groups {
            let count = String(localized: "\(group.circles.count) circles")
            let value = "\(group.label) · \(count)"
            let textWidth = min(180, value.size(withAttributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .medium)
            ]).width)
            let itemWidth = textWidth + 25
            if x + itemWidth > maxX {
                x = horizontalMargin
                rowY += 18
            }

            group.color.uiColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: x, y: rowY + 3, width: 10, height: 10)).fill()
            drawText(
                value,
                in: CGRect(x: x + 15, y: rowY, width: textWidth + 4, height: 16),
                font: .systemFont(ofSize: 9, weight: .medium),
                color: ink
            )
            x += itemWidth + 12
        }
        return rowY + 18
    }

    private static func drawFallbackMap(_ scene: CatalogMapScene, in mapRect: CGRect) {
        let scale = min(mapRect.width / scene.size.width, mapRect.height / scene.size.height)
        for table in scene.tables {
            let rect = convert(
                CGRect(origin: table.origin, size: scene.tableSize),
                from: scene.size,
                to: mapRect
            )
            UIColor(white: 0.94, alpha: 1).setFill()
            UIRectFill(rect)
            UIColor(white: 0.72, alpha: 1).setStroke()
            let outline = UIBezierPath(rect: rect)
            outline.lineWidth = max(0.2, min(0.6, scale * 0.6))
            outline.stroke()
        }

        guard scale >= 0.08 else { return }
        for block in scene.blockLabels {
            let point = convert(block.position, from: scene.size, to: mapRect)
            drawText(
                block.name,
                in: CGRect(x: point.x - 14, y: point.y - 7, width: 28, height: 14),
                font: .systemFont(ofSize: min(9, max(5, scale * 40)), weight: .bold),
                color: UIColor(white: 0.26, alpha: 0.72),
                alignment: .center
            )
        }
    }

    private static func drawFavoriteMarkers(_ hall: FavoriteMapPDFHall, in mapRect: CGRect) {
        for circle in hall.circles {
            guard let table = hall.scene.tableByID[circle.tableID] else { continue }
            let localRect = subspaceRect(
                table: table,
                subspace: circle.subspace,
                tableSize: hall.scene.tableSize
            )
            let exactRect = convert(localRect, from: hall.scene.size, to: mapRect)
            let color = circle.color.uiColor

            color.withAlphaComponent(0.52).setFill()
            UIRectFill(exactRect.insetBy(dx: -0.5, dy: -0.5))
            color.setStroke()
            let exactOutline = UIBezierPath(rect: exactRect.insetBy(dx: -0.7, dy: -0.7))
            exactOutline.lineWidth = 1
            exactOutline.stroke()

            let radius: CGFloat = 6
            let markerRect = CGRect(
                x: exactRect.midX - radius,
                y: exactRect.midY - radius,
                width: radius * 2,
                height: radius * 2
            )
            color.setFill()
            UIBezierPath(ovalIn: markerRect).fill()
            UIColor.white.setStroke()
            let markerOutline = UIBezierPath(ovalIn: markerRect)
            markerOutline.lineWidth = 1.2
            markerOutline.stroke()
            drawText(
                String(circle.number),
                in: markerRect.insetBy(dx: 1, dy: 1.5),
                font: .monospacedDigitSystemFont(
                    ofSize: circle.number >= 100 ? 5 : 6.5,
                    weight: .bold
                ),
                color: markerTextColor(for: color),
                alignment: .center
            )
        }
    }

    private static func drawListPage(_ lines: [ListLine]) {
        var y = headerBottom + 4
        for line in lines {
            switch line {
            case .group(let color, let label, let count):
                color.uiColor.withAlphaComponent(0.13).setFill()
                UIRectFill(CGRect(
                    x: horizontalMargin,
                    y: y,
                    width: pageSize.width - horizontalMargin * 2,
                    height: groupHeight
                ))
                color.uiColor.setFill()
                UIBezierPath(
                    ovalIn: CGRect(x: horizontalMargin + 7, y: y + 6, width: 10, height: 10)
                ).fill()
                drawText(
                    "\(label) · \(String(localized: "\(count) circles"))",
                    in: CGRect(
                        x: horizontalMargin + 23,
                        y: y + 2,
                        width: pageSize.width - horizontalMargin * 2 - 30,
                        height: 18
                    ),
                    font: .systemFont(ofSize: 10, weight: .semibold),
                    color: ink
                )
            case .circle(let circle):
                drawCircleRow(circle, y: y)
            }
            y += line.height
        }
    }

    private static func drawCircleRow(_ circle: FavoriteMapPDFCircle, y: CGFloat) {
        let x = horizontalMargin
        let widths: [CGFloat] = [34, 116, 212, 130, 293]
        let values = [
            String(circle.number),
            circle.locationLabel,
            circle.circleName,
            circle.penName ?? "",
            circle.memo ?? "",
        ]
        var columnX = x

        for (index, value) in values.enumerated() {
            if index == 0 {
                let color = circle.color.uiColor
                color.setFill()
                let marker = CGRect(x: columnX + 9, y: y + 8, width: 12, height: 12)
                UIBezierPath(ovalIn: marker).fill()
                drawText(
                    value,
                    in: marker.insetBy(dx: 0.5, dy: 1.5),
                    font: .monospacedDigitSystemFont(
                        ofSize: circle.number >= 100 ? 5 : 6.5,
                        weight: .bold
                    ),
                    color: markerTextColor(for: color),
                    alignment: .center
                )
            } else {
                drawText(
                    value,
                    in: CGRect(
                        x: columnX + 5,
                        y: y + 4,
                        width: widths[index] - 10,
                        height: rowHeight - 7
                    ),
                    font: .systemFont(
                        ofSize: index == 2 ? 9.5 : 9,
                        weight: index == 2 ? .medium : .regular
                    ),
                    color: index == 4 ? mutedInk : ink,
                    maximumLines: 2
                )
            }
            columnX += widths[index]
        }

        hairline.setFill()
        UIRectFill(CGRect(
            x: horizontalMargin,
            y: y + rowHeight - 0.5,
            width: pageSize.width - horizontalMargin * 2,
            height: 0.5
        ))
    }

    private static func drawFooter() {
        drawText(
            "ComiNavi",
            in: CGRect(x: horizontalMargin, y: footerTop + 4, width: 100, height: 12),
            font: .systemFont(ofSize: 7.5, weight: .medium),
            color: quietInk
        )
    }

    private static func drawText(
        _ value: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        maximumLines: Int = 1
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.maximumLineHeight = font.lineHeight
        let options: NSStringDrawingOptions = maximumLines > 1
            ? [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
            : [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        (value as NSString).draw(
            with: rect,
            options: options,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
    }

    private static func aspectFit(_ source: CGSize, in container: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return container }
        let scale = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func convert(_ rect: CGRect, from source: CGSize, to target: CGRect) -> CGRect {
        CGRect(
            x: target.minX + rect.minX / source.width * target.width,
            y: target.minY + rect.minY / source.height * target.height,
            width: rect.width / source.width * target.width,
            height: rect.height / source.height * target.height
        )
    }

    private static func convert(_ point: CGPoint, from source: CGSize, to target: CGRect) -> CGPoint {
        CGPoint(
            x: target.minX + point.x / source.width * target.width,
            y: target.minY + point.y / source.height * target.height
        )
    }

    private static func subspaceRect(
        table: CatalogMapTable,
        subspace: Int,
        tableSize: CGSize
    ) -> CGRect {
        let rect = CGRect(origin: table.origin, size: tableSize)
        return switch table.orientation {
        case .aLeft:
            subspace == 0
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
                : CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .aBottom:
            subspace == 0
                ? CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .aRight:
            subspace == 0
                ? CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .aTop:
            subspace == 0
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
                : CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    private static func markerTextColor(for color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let luminance = red * 0.299 + green * 0.587 + blue * 0.114
        return luminance > 0.66 ? UIColor(white: 0.12, alpha: 1) : .white
    }
}

struct FavoriteMapPDFScreen: View {
    private enum Phase {
        case loading
        case empty
        case loaded(FavoriteMapPDFDocument, URL)
        case failed(String)
    }

    let dataSource: CirclemsDataSource
    let colorLabelStore: FavoriteColorLabelStore

    @State private var phase = Phase.loading
    @State private var reloadID = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Preparing map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No favorite circles",
                    systemImage: "map",
                    description: Text("Add favorites to create a printable map.")
                )
            case .loaded(let document, _):
                documentSummary(document)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t create the favorite map", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { reloadID &+= 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Favorite map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    FavoriteColorLabelsScreen(store: colorLabelStore)
                } label: {
                    Label("Color labels", systemImage: "tag")
                }
            }

            if case .loaded(_, let url) = phase {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: url,
                        preview: SharePreview(
                            String(localized: "Favorite map"),
                            image: Image(systemName: "map")
                        )
                    ) {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("profile-favorite-map-share")
                }
            }
        }
        .task(id: loadTaskID) {
            await load()
        }
    }

    private var loadTaskID: String {
        "\(dataSource.comiket.number)-\(colorLabelStore.revision)-\(reloadID)"
    }

    private func documentSummary(_ document: FavoriteMapPDFDocument) -> some View {
        List {
            Section {
                LabeledContent("Event", value: document.eventTitle)
                LabeledContent(
                    "Favorite circles",
                    value: String(localized: "\(document.circleCount) circles")
                )
                LabeledContent("Map pages", value: String(document.halls.count))
            }

            ForEach(document.halls) { hall in
                Section {
                    ForEach(hall.groupedCircles, id: \.color) { group in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(group.color.swiftUIColor)
                                .overlay {
                                    Circle().stroke(.black.opacity(0.12), lineWidth: 0.5)
                                }
                                .frame(width: 13, height: 13)
                                .accessibilityHidden(true)
                            Text(group.label)
                            Spacer()
                            Text("\(group.circles.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("\(String(localized: "Day \(hall.scene.id.day)")) · \(hall.name)")
                }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            let labels = Dictionary(uniqueKeysWithValues: BookmarkColor.selectableColors.map {
                ($0, colorLabelStore.label(for: $0))
            })
            let document = try await FavoriteMapPDFLoader.load(
                from: dataSource,
                colorLabels: labels
            )
            guard !document.halls.isEmpty else {
                phase = .empty
                return
            }

            let data = FavoriteMapPDFRenderer.render(document)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ComiNavi-C\(document.eventNumber)-Favorite-Map.pdf",
                    isDirectory: false
                )
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            phase = .loaded(document, url)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
