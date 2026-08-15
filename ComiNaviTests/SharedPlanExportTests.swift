import Foundation
import XCTest
@testable import ComiNavi

final class SharedPlanExportTests: XCTestCase {
    func testCSVUsesRequestedColumnsEscapesTextAndExcludesRemovedCircles() throws {
        let activeKey = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 101))
        let removedKey = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 102))
        let need = SharedPlanPurchaseNeed(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            requesterUserID: "requester",
            itemName: "New, \"Book\"",
            unitPrice: 1_500,
            wantedQuantity: 2
        )
        let snapshot = makeSnapshot(circles: [
            SharedPlanCircleContent(
                key: activeKey,
                presence: .present,
                memo: "",
                needs: [need],
                communicationState: [:]
            ),
            SharedPlanCircleContent(
                key: removedKey,
                presence: .removed,
                memo: "",
                needs: [],
                communicationState: [:]
            ),
        ])
        let document = SharedPlanExportDocument(
            snapshot: snapshot,
            catalogCircles: [
                101: catalogCircle(
                    publicCircleID: 101,
                    circleName: "Chericot＊Rozel, Atelier",
                    penName: "茉宮\"祈芹"
                ),
                102: catalogCircle(
                    publicCircleID: 102,
                    circleName: "Removed circle",
                    penName: nil
                ),
            ]
        )

        XCTAssertTrue(document.csvData.starts(with: [0xEF, 0xBB, 0xBF]))
        let csv = String(decoding: document.csvData.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(
            csv,
            "Circle Name,Pen Name,Day,Venue,Location code,Item Name,Item Amount,Item Quantity\r\n"
                + "\"Chericot＊Rozel, Atelier\",\"茉宮\"\"祈芹\",日,東1,ア12ab,\"New, \"\"Book\"\"\",1500,2\r\n"
        )
        XCTAssertFalse(csv.contains("Removed circle"))
        XCTAssertEqual(document.purchaseItemCount, 1)
    }

    func testCircleWithoutPurchaseProducesBlankItemColumns() throws {
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 101))
        let document = SharedPlanExportDocument(
            snapshot: makeSnapshot(circles: [SharedPlanCircleContent(
                key: key,
                presence: .present,
                memo: "",
                needs: [],
                communicationState: [:]
            )]),
            catalogCircles: [101: catalogCircle(
                publicCircleID: 101,
                circleName: "Chericot＊Rozel",
                penName: "茉宮祈芹"
            )]
        )

        let csv = String(decoding: document.csvData.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(csv.hasSuffix("Chericot＊Rozel,茉宮祈芹,日,東1,ア12ab,,,\r\n"))
        XCTAssertEqual(document.purchaseItemCount, 0)
    }

    func testArchiveContainsCSVAndExactOfficialImageFilename() throws {
        let key = try XCTUnwrap(SharedPlanCircleKey(comiketNo: 108, wcID: 101))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let document = SharedPlanExportDocument(
            snapshot: makeSnapshot(circles: [SharedPlanCircleContent(
                key: key,
                presence: .present,
                memo: "",
                needs: [],
                communicationState: [:]
            )]),
            catalogCircles: [101: catalogCircle(
                publicCircleID: 101,
                circleName: "Chericot＊Rozel",
                penName: "茉宮祈芹",
                image: try XCTUnwrap(SharedPlanExportImage(data: png))
            )]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedPlanExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = try SharedPlanExportArchive.write(document, to: directory)
        let entries = try localEntries(in: Data(contentsOf: archiveURL))

        XCTAssertEqual(
            Set(entries.keys),
            [
                "sharing-plan.csv",
                "日東1ア12ab [Chericot＊Rozel (茉宮祈芹)].png",
            ]
        )
        XCTAssertEqual(entries["日東1ア12ab [Chericot＊Rozel (茉宮祈芹)].png"], png)
        XCTAssertEqual(document.imageCount, 1)
        XCTAssertEqual(document.missingImageCount, 0)
    }

    func testImageDetectionAndZIPChecksum() throws {
        XCTAssertEqual(
            SharedPlanExportImage(data: Data([0xFF, 0xD8, 0xFF, 0x01]))?.fileExtension,
            .jpg
        )
        XCTAssertEqual(
            SharedPlanExportImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            )?.fileExtension,
            .png
        )
        XCTAssertNil(SharedPlanExportImage(data: Data("GIF89a".utf8)))
        XCTAssertEqual(
            StoredZIPArchive.crc32(Data("123456789".utf8)),
            0xCBF4_3926
        )
    }

    private func makeSnapshot(
        circles: [SharedPlanCircleContent]
    ) -> SharedPlanEditorSnapshot {
        let now = Date(timeIntervalSince1970: 1_786_276_800)
        return SharedPlanEditorSnapshot(
            plan: SharedPlan(
                id: "plan",
                name: "共同購入",
                comiketNo: 108,
                ownership: .owned,
                role: .owner,
                lifecycle: .active,
                revision: 1,
                circleKeys: circles.map(\.key),
                createdAt: now,
                updatedAt: now
            ),
            circles: circles,
            conflicts: [],
            syncStatus: .synchronized(mutationsEnabled: true, pendingOperationCount: 0),
            pendingOperationCount: 0,
            localEditLimit: nil,
            syncIssue: nil,
            recoveryDocument: nil,
            recoveryRebaseAvailable: false,
            permitsContentMutations: true
        )
    }

    private func catalogCircle(
        publicCircleID: Int,
        circleName: String,
        penName: String?,
        image: SharedPlanExportImage? = nil
    ) -> SharedPlanExportCatalogCircle {
        SharedPlanExportCatalogCircle(
            publicCircleID: publicCircleID,
            circleName: circleName,
            penName: penName,
            dayIndex: 2,
            daySymbol: "日",
            venue: "東1",
            blockName: "ア",
            spaceNumber: 12,
            spaceSide: "ab",
            image: image
        )
    }

    private func localEntries(in archive: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        while offset + 4 <= archive.count, uint32(in: archive, at: offset) == 0x0403_4B50 {
            let compressedSize = Int(uint32(in: archive, at: offset + 18))
            let filenameLength = Int(uint16(in: archive, at: offset + 26))
            let extraLength = Int(uint16(in: archive, at: offset + 28))
            let filenameStart = offset + 30
            let filenameEnd = filenameStart + filenameLength
            let dataStart = filenameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= archive.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = String(decoding: archive[filenameStart ..< filenameEnd], as: UTF8.self)
            result[name] = Data(archive[dataStart ..< dataEnd])
            offset = dataEnd
        }
        return result
    }

    private func uint16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
