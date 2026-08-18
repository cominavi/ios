import Foundation
import SwiftUI

enum SharedPlanExportError: LocalizedError {
    case catalogUnavailable
    case eventMismatch
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            String(localized: "The official catalog is not ready.")
        case .eventMismatch:
            String(localized: "This catalog belongs to a different event.")
        case .archiveTooLarge:
            String(localized: "The ZIP export is too large.")
        }
    }
}

struct SharedPlanExportImage: Equatable, Sendable {
    enum FileExtension: String, Equatable, Sendable {
        case jpg
        case png
    }

    let data: Data
    let fileExtension: FileExtension

    init?(data: Data) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            fileExtension = .png
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            fileExtension = .jpg
        } else {
            return nil
        }
        self.data = data
    }
}

struct SharedPlanExportCatalogCircle: Equatable, Sendable {
    let publicCircleID: Int
    let circleName: String
    let penName: String?
    let dayIndex: Int?
    let daySymbol: String
    let venue: String
    let blockName: String
    let spaceNumber: Int?
    let spaceSide: String
    let image: SharedPlanExportImage?

    var locationCode: String {
        guard let spaceNumber else { return blockName }
        return "\(blockName)\(String(format: "%02d", spaceNumber))\(spaceSide)"
    }

    var imageFilename: String {
        let resolvedCircleName = circleName.isEmpty ? "Circle \(publicCircleID)" : circleName
        let identity = if let penName {
            "\(resolvedCircleName) (\(penName))"
        } else {
            resolvedCircleName
        }
        return SharedPlanExportFilename.sanitize(
            "\(daySymbol)\(venue)\(locationCode) [\(identity)]"
        )
    }

    static func unavailable(publicCircleID: Int) -> Self {
        Self(
            publicCircleID: publicCircleID,
            circleName: "",
            penName: nil,
            dayIndex: nil,
            daySymbol: "",
            venue: "",
            blockName: "",
            spaceNumber: nil,
            spaceSide: "",
            image: nil
        )
    }
}

struct SharedPlanExportCircle: Equatable, Sendable {
    let catalog: SharedPlanExportCatalogCircle
    let needs: [SharedPlanPurchaseNeed]
}

struct SharedPlanExportDocument: Equatable, Sendable {
    let planName: String
    let eventNumber: Int
    let updatedAt: Date
    let circles: [SharedPlanExportCircle]

    init(
        snapshot: SharedPlanEditorSnapshot,
        catalogCircles: [Int: SharedPlanExportCatalogCircle]
    ) {
        planName = snapshot.plan.name
        eventNumber = snapshot.plan.comiketNo
        updatedAt = snapshot.plan.updatedAt
        circles = snapshot.circles
            .filter { $0.presence != .removed }
            .map { content in
                SharedPlanExportCircle(
                    catalog: catalogCircles[content.key.wcID]
                        ?? .unavailable(publicCircleID: content.key.wcID),
                    needs: content.needs
                )
            }
            .sorted(by: Self.circleSort)
    }

    var purchaseItemCount: Int {
        circles.reduce(0) { $0 + $1.needs.count }
    }

    var imageCount: Int {
        circles.count { $0.catalog.image != nil }
    }

    var missingImageCount: Int {
        circles.count - imageCount
    }

    var csvData: Data {
        let headers = [
            "Circle Name",
            "Pen Name",
            "Day",
            "Venue",
            "Location code",
            "Item Name",
            "Item Amount",
            "Item Quantity",
        ]
        var lines = [headers.joined(separator: ",")]

        for circle in circles {
            if circle.needs.isEmpty {
                lines.append(Self.csvRow(circle: circle.catalog, need: nil))
            } else {
                lines.append(contentsOf: circle.needs.map {
                    Self.csvRow(circle: circle.catalog, need: $0)
                })
            }
        }

        var result = Data([0xEF, 0xBB, 0xBF])
        result.append(Data(lines.joined(separator: "\r\n").utf8))
        result.append(Data("\r\n".utf8))
        return result
    }

    private static func csvRow(
        circle: SharedPlanExportCatalogCircle,
        need: SharedPlanPurchaseNeed?
    ) -> String {
        [
            circle.circleName,
            circle.penName ?? "",
            circle.daySymbol,
            circle.venue,
            circle.locationCode,
            need?.itemName ?? "",
            need.flatMap { $0.unitPrice }.map(String.init) ?? "",
            need.map { String($0.wantedQuantity) } ?? "",
        ]
        .map(csvField)
        .joined(separator: ",")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func circleSort(
        _ lhs: SharedPlanExportCircle,
        _ rhs: SharedPlanExportCircle
    ) -> Bool {
        let left = lhs.catalog
        let right = rhs.catalog
        if left.dayIndex != right.dayIndex {
            return (left.dayIndex ?? .max) < (right.dayIndex ?? .max)
        }
        let venueComparison = left.venue.localizedStandardCompare(right.venue)
        if venueComparison != .orderedSame { return venueComparison == .orderedAscending }
        let blockComparison = left.blockName.localizedStandardCompare(right.blockName)
        if blockComparison != .orderedSame { return blockComparison == .orderedAscending }
        if left.spaceNumber != right.spaceNumber {
            return (left.spaceNumber ?? .max) < (right.spaceNumber ?? .max)
        }
        if left.spaceSide != right.spaceSide { return left.spaceSide < right.spaceSide }
        return left.circleName.localizedStandardCompare(right.circleName) == .orderedAscending
    }
}

@MainActor
enum SharedPlanExportLoader {
    private struct TableKey: Hashable, Sendable {
        let day: Int
        let tableID: CatalogMapTable.ID
    }

    static func load(
        snapshot: SharedPlanEditorSnapshot,
        from dataSource: CirclemsDataSource
    ) async throws -> SharedPlanExportDocument {
        guard dataSource.readiness == .ready, let event = dataSource.comiket else {
            throw SharedPlanExportError.catalogUnavailable
        }
        guard event.number == snapshot.plan.comiketNo else {
            throw SharedPlanExportError.eventMismatch
        }

        let publicCircleIDs = snapshot.circles
            .filter { $0.presence != .removed }
            .map(\.key.wcID)
        let catalogCircles = await dataSource.getCircles(publicCircleIDs: publicCircleIDs)
        let locations = try await dataSource.mapCatalog.bookmarkLocations(
            publicCircleIDs: publicCircleIDs
        )
        let locationsByPublicID = locations.reduce(
            into: [Int: CatalogBookmarkLocation]()
        ) { result, location in
            result[location.publicCircleID] = location
        }
        let imagesByCatalogID = try await dataSource.mapCatalog.circleImages(
            circleIDs: catalogCircles.values.map(\.id)
        )
        let combinedTables = await combinedTables(
            for: catalogCircles.values,
            using: dataSource.mapCatalog
        )

        let blockNames = Dictionary(
            uniqueKeysWithValues: event.blocks.map { ($0.externalBlockId, Self.normalized($0.name)) }
        )
        var exportCircles: [Int: SharedPlanExportCatalogCircle] = [:]
        for publicCircleID in publicCircleIDs {
            guard let circle = catalogCircles[publicCircleID] else { continue }
            let location = locationsByPublicID[publicCircleID]
            let day = circle.day ?? location?.day
            let blockID = circle.blockId ?? location?.tableID.blockID
            let spaceNumber = circle.spaceNo ?? location?.tableID.spaceNumber
            let subspace = circle.spaceNoSub ?? location?.subspace ?? 0
            let tableKey: TableKey? = if let day, let blockID, let spaceNumber {
                TableKey(
                    day: day,
                    tableID: .init(blockID: blockID, spaceNumber: spaceNumber)
                )
            } else {
                nil
            }
            let dayMetadata = day.flatMap { day in
                event.days.first { $0.dayIndex == day }
            }
            exportCircles[publicCircleID] = SharedPlanExportCatalogCircle(
                publicCircleID: publicCircleID,
                circleName: normalized(circle.circleName),
                penName: optionalNormalized(circle.penName),
                dayIndex: day,
                daySymbol: dayMetadata.map(weekdaySymbol) ?? day.map(String.init) ?? "",
                venue: ComiketSpaceAddress.compactHallName(
                    location?.resolvedHallName(in: event) ?? ""
                ),
                blockName: blockID.flatMap { blockNames[$0] } ?? "",
                spaceNumber: spaceNumber,
                spaceSide: tableKey.map { combinedTables.contains($0) }
                    == true ? "ab" : (subspace == 1 ? "b" : "a"),
                image: imagesByCatalogID[circle.id].flatMap {
                    SharedPlanExportImage(data: $0)
                }
            )
        }

        return SharedPlanExportDocument(
            snapshot: snapshot,
            catalogCircles: exportCircles
        )
    }

    private static func combinedTables(
        for circles: Dictionary<Int, CirclemsDataSchema.ComiketCircleWC>.Values,
        using mapCatalog: any MapCatalog
    ) async -> Set<TableKey> {
        let tableKeys = Set(circles.compactMap { circle -> TableKey? in
            guard let day = circle.day,
                  let blockID = circle.blockId,
                  let spaceNumber = circle.spaceNo
            else { return nil }
            return TableKey(
                day: day,
                tableID: .init(blockID: blockID, spaceNumber: spaceNumber)
            )
        })
        var result: Set<TableKey> = []
        for key in tableKeys {
            guard let members = try? await mapCatalog.circles(
                day: key.day,
                tableID: key.tableID
            ), isCombinedCircle(members)
            else { continue }
            result.insert(key)
        }
        return result
    }

    private static func isCombinedCircle(_ circles: [CatalogMapCircle]) -> Bool {
        guard circles.count == 2,
              let first = circles.first,
              !normalized(first.circleName).isEmpty
        else { return false }
        return circles.dropFirst().allSatisfy {
            normalized($0.circleName) == normalized(first.circleName)
                && normalized($0.penName) == normalized(first.penName)
        }
    }

    private static func weekdaySymbol(_ day: UFDSchema.Day) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        var components = day.date
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        guard let date = components.date else { return String(day.dayIndex) }
        let symbols = ["日", "月", "火", "水", "木", "金", "土"]
        return symbols[calendar.component(.weekday, from: date) - 1]
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func optionalNormalized(_ value: String?) -> String? {
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }
}

enum SharedPlanExportArchive {
    static func entries(for document: SharedPlanExportDocument) -> [StoredZIPArchive.Entry] {
        var result = [StoredZIPArchive.Entry(
            name: "sharing-plan.csv",
            data: document.csvData
        )]
        var usedNames = Set(result.map(\.name))

        for circle in document.circles {
            guard let image = circle.catalog.image else { continue }
            let preferredName = "\(circle.catalog.imageFilename).\(image.fileExtension.rawValue)"
            let name = SharedPlanExportFilename.unique(preferredName, usedNames: &usedNames)
            result.append(StoredZIPArchive.Entry(name: name, data: image.data))
        }
        return result
    }

    static func write(
        _ document: SharedPlanExportDocument,
        to parentDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let exportDirectory = parentDirectory
            .appendingPathComponent("cominavi-sharing-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        let planName = SharedPlanExportFilename.sanitize(document.planName, maximumLength: 80)
        let filename = "ComiNavi-C\(document.eventNumber)-\(planName)-Sharing-Plan.zip"
        let url = exportDirectory.appendingPathComponent(filename, isDirectory: false)
        try StoredZIPArchive.write(entries(for: document), to: url)
        return url
    }
}

enum SharedPlanExportFilename {
    static func sanitize(_ value: String, maximumLength: Int = 180) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let replaced = value.unicodeScalars.map {
            forbidden.contains($0) ? "_" : String($0)
        }.joined()
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let bounded = String(trimmed.prefix(maximumLength))
        return bounded.isEmpty ? "Sharing Plan" : bounded
    }

    static func unique(_ preferredName: String, usedNames: inout Set<String>) -> String {
        guard !usedNames.contains(preferredName) else {
            let url = URL(fileURLWithPath: preferredName)
            let fileExtension = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            var suffix = 2
            while true {
                let candidate = fileExtension.isEmpty
                    ? "\(stem) (\(suffix))"
                    : "\(stem) (\(suffix)).\(fileExtension)"
                if usedNames.insert(candidate).inserted { return candidate }
                suffix += 1
            }
        }
        usedNames.insert(preferredName)
        return preferredName
    }
}

enum StoredZIPArchive {
    struct Entry: Equatable, Sendable {
        let name: String
        let data: Data
    }

    private struct CentralDirectoryEntry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw SharedPlanExportError.archiveTooLarge
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let file = try FileHandle(forWritingTo: url)
        var offset: UInt64 = 0
        var centralEntries: [CentralDirectoryEntry] = []
        centralEntries.reserveCapacity(entries.count)

        do {
            for entry in entries {
                let name = Data(entry.name.utf8)
                guard name.count <= Int(UInt16.max),
                      entry.data.count <= Int(UInt32.max),
                      offset <= UInt64(UInt32.max)
                else { throw SharedPlanExportError.archiveTooLarge }

                let size = UInt32(entry.data.count)
                let checksum = crc32(entry.data)
                var header = Data()
                header.appendUInt32LE(0x04034B50)
                header.appendUInt16LE(20)
                header.appendUInt16LE(0x0800)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0x0021)
                header.appendUInt32LE(checksum)
                header.appendUInt32LE(size)
                header.appendUInt32LE(size)
                header.appendUInt16LE(UInt16(name.count))
                header.appendUInt16LE(0)
                header.append(name)

                try file.write(contentsOf: header)
                try file.write(contentsOf: entry.data)
                centralEntries.append(CentralDirectoryEntry(
                    name: name,
                    crc32: checksum,
                    size: size,
                    localHeaderOffset: UInt32(offset)
                ))
                offset += UInt64(header.count + entry.data.count)
            }

            guard offset <= UInt64(UInt32.max) else {
                throw SharedPlanExportError.archiveTooLarge
            }
            let centralDirectoryOffset = UInt32(offset)
            for entry in centralEntries {
                var header = Data()
                header.appendUInt32LE(0x02014B50)
                header.appendUInt16LE(20)
                header.appendUInt16LE(20)
                header.appendUInt16LE(0x0800)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0x0021)
                header.appendUInt32LE(entry.crc32)
                header.appendUInt32LE(entry.size)
                header.appendUInt32LE(entry.size)
                header.appendUInt16LE(UInt16(entry.name.count))
                header.appendUInt16LE(0)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0)
                header.appendUInt16LE(0)
                header.appendUInt32LE(0)
                header.appendUInt32LE(entry.localHeaderOffset)
                header.append(entry.name)
                try file.write(contentsOf: header)
                offset += UInt64(header.count)
            }

            let centralDirectorySize = offset - UInt64(centralDirectoryOffset)
            guard centralDirectorySize <= UInt64(UInt32.max) else {
                throw SharedPlanExportError.archiveTooLarge
            }
            var footer = Data()
            footer.appendUInt32LE(0x06054B50)
            footer.appendUInt16LE(0)
            footer.appendUInt16LE(0)
            footer.appendUInt16LE(UInt16(centralEntries.count))
            footer.appendUInt16LE(UInt16(centralEntries.count))
            footer.appendUInt32LE(UInt32(centralDirectorySize))
            footer.appendUInt32LE(centralDirectoryOffset)
            footer.appendUInt16LE(0)
            try file.write(contentsOf: footer)
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0 ..< 8 {
                value = (value >> 1) ^ (0xEDB88320 & (0 &- (value & 1)))
            }
        }
        return value ^ UInt32.max
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

struct SharedPlanExportScreen: View {
    private enum Phase {
        case loading
        case loaded(Summary, URL)
        case failed(String)
    }

    private struct Summary {
        let planName: String
        let circleCount: Int
        let purchaseItemCount: Int
        let imageCount: Int
        let missingImageCount: Int
    }

    let store: SharedPlanStore
    let planID: String
    let dataSource: CirclemsDataSource

    @State private var phase = Phase.loading
    @State private var reloadID = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Preparing export…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let summary, _):
                summaryView(summary)
            case .failed(let message):
                ContentUnavailableView {
                    Label(
                        "Couldn’t create the plan export",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { reloadID &+= 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Export sharing plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .loaded(let summary, let url) = phase {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: url,
                        preview: SharePreview(
                            summary.planName,
                            image: Image(systemName: "archivebox")
                        )
                    ) {
                        Label("Share ZIP", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shared-plan-export-share")
                }
            }
        }
        .task(id: "\(planID):\(reloadID)") {
            await load()
        }
    }

    private func summaryView(_ summary: Summary) -> some View {
        List {
            Section {
                LabeledContent("Plan", value: summary.planName)
                LabeledContent("Plan circles", value: String(summary.circleCount))
                LabeledContent("Purchase items", value: String(summary.purchaseItemCount))
                LabeledContent("Images", value: String(summary.imageCount))
            }

            Section {
                Text(
                    "The ZIP contains sharing-plan.csv and the available official circle images."
                )
                if summary.missingImageCount > 0 {
                    Label(
                        "Some official circle images were unavailable.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            let snapshot = try await store.editorSnapshot(planID: planID)
            let document = try await SharedPlanExportLoader.load(
                snapshot: snapshot,
                from: dataSource
            )
            let summary = Summary(
                planName: document.planName,
                circleCount: document.circles.count,
                purchaseItemCount: document.purchaseItemCount,
                imageCount: document.imageCount,
                missingImageCount: document.missingImageCount
            )
            let url = try await Task.detached(priority: .userInitiated) {
                try SharedPlanExportArchive.write(document)
            }.value
            try Task.checkCancellation()
            phase = .loaded(summary, url)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
