import CoreGraphics
import UIKit
import XCTest
@testable import ComiNavi

@MainActor
final class FavoriteMapPDFTests: XCTestCase {
    func testColorLabelsPersistOnlyTrimmedFavoriteColors() throws {
        let suiteName = "FavoriteMapPDFTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FavoriteColorLabelStore(defaults: defaults)
        store.replace(with: [
            .orange: "  Must visit  ",
            .blue: "   ",
            .memoOnly: "Ignored",
        ])

        XCTAssertEqual(store.customLabels, [.orange: "Must visit"])
        XCTAssertEqual(store.label(for: .orange), "Must visit")

        let restored = FavoriteColorLabelStore(defaults: defaults)
        XCTAssertEqual(restored.customLabels, [.orange: "Must visit"])
    }

    func testRendererCreatesLandscapeMapAndPaginatedColorList() throws {
        let document = fixtureDocument(circleCount: 48)
        let pages = FavoriteMapPDFRenderer.pages(for: document)

        XCTAssertGreaterThan(pages.count, 2)
        guard case .map = pages[0] else {
            return XCTFail("The first page must be the hall map")
        }
        guard case .list = pages[1] else {
            return XCTFail("A keyed circle list must follow the map")
        }

        let data = FavoriteMapPDFRenderer.render(document)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages, pages.count)

        let firstPage = try XCTUnwrap(pdf.page(at: 1))
        let mediaBox = firstPage.getBoxRect(.mediaBox)
        XCTAssertEqual(mediaBox.width, FavoriteMapPDFRenderer.pageSize.width, accuracy: 0.5)
        XCTAssertEqual(mediaBox.height, FavoriteMapPDFRenderer.pageSize.height, accuracy: 0.5)
        XCTAssertGreaterThan(mediaBox.width, mediaBox.height)

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "cominavi-favorite-map-qa.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)

        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cominavi-favorite-map-qa.pdf")
        try data.write(to: previewURL, options: .atomic)
        print("FAVORITE_MAP_PDF_QA=\(previewURL.path)")
    }

    func testMemoOnlyAndPendingDeletionNeverEnterExport() async throws {
        let store = InMemoryUserPlanStore()
        try await store.upsert([
            bookmark(id: 1, color: .orange, syncState: .synced),
            bookmark(id: 2, color: .memoOnly, syncState: .synced),
            bookmark(id: 3, color: .green, syncState: .pendingDelete),
        ])

        let favorites = try await store.allBookmarks(eventNumber: 108).filter(\.isFavorite)

        XCTAssertEqual(favorites.map(\.publicCircleID), [1])
    }

    private func fixtureDocument(circleCount: Int) -> FavoriteMapPDFDocument {
        let tableSize = CGSize(width: 34, height: 28)
        let columns = 12
        let tables = (0 ..< circleCount).map { index in
            CatalogMapTable(
                id: .init(blockID: index / 12 + 1, spaceNumber: index % 12 + 1),
                blockName: String(UnicodeScalar(65 + index / 12)!),
                origin: CGPoint(
                    x: 40 + (index % columns) * 48,
                    y: 55 + (index / columns) * 72
                ),
                orientation: index.isMultiple(of: 2) ? .aLeft : .aTop
            )
        }
        let scene = CatalogMapScene(
            id: .init(day: 1, mapID: 1),
            name: "East Hall",
            size: CGSize(width: 660, height: 400),
            tableSize: tableSize,
            tables: tables
        )
        let colors: [BookmarkColor] = [.orange, .green, .blue]
        let labels: [BookmarkColor: String] = [
            .orange: "Must visit",
            .green: "Friends",
            .blue: "If time allows",
        ]
        let circles = tables.enumerated().map { index, table in
            let color = colors[index % colors.count]
            return FavoriteMapPDFCircle(
                id: index + 1,
                number: index + 1,
                color: color,
                colorLabel: labels[color]!,
                day: 1,
                mapID: 1,
                tableID: table.id,
                subspace: index % 2,
                blockName: table.blockName,
                spaceNumber: table.id.spaceNumber,
                circleName: "Circle \(index + 1)",
                penName: "Creator \(index + 1)",
                memo: index.isMultiple(of: 4) ? "Bring the new release and say hello." : nil
            )
        }
        return FavoriteMapPDFDocument(
            eventNumber: 108,
            eventTitle: "Comic Market 108",
            halls: [FavoriteMapPDFHall(name: "East Hall", scene: scene, circles: circles)]
        )
    }

    private func bookmark(
        id: Int,
        color: BookmarkColor,
        syncState: BookmarkSyncState
    ) -> MapBookmark {
        MapBookmark(
            eventNumber: 108,
            publicCircleID: id,
            catalogCircleID: id,
            updateID: id,
            day: 1,
            mapID: 1,
            tableID: .init(blockID: 1, spaceNumber: id),
            subspace: 0,
            color: color,
            memo: "",
            modifiedAt: .now,
            syncState: syncState
        )
    }
}
