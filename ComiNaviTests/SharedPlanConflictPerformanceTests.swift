@testable import ComiNavi
import Foundation
import XCTest

final class SharedPlanConflictPerformanceTests: XCTestCase {
    func testNearCapColdLoadAndIncrementalPreflightRemainBounded() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.noConflictAt9999.operationCount, 9_999)

        let noConflictLoad = try timed {
            try SharedPlanAutomergeDocument(
                data: try decode(fixture.noConflictAt9999.document),
                replicaID: Self.replicaID
            )
        }
        let operationID = UUID(uuidString: "00000000-0000-4000-8000-000000002710")!
        let circle = try XCTUnwrap(
            SharedPlanCircleKey(comiketNo: fixture.comiketNo, wcID: 9_001)
        )
        let legalTenthousandthEdit = try await timedAsync {
            try await noConflictLoad.value.performDurableMutation(
                .setCirclePresence(circle, .removed),
                operationID: operationID,
                actorUserID: fixture.actorUserID,
                authoredAt: Date(timeIntervalSince1970: 1_720_010_000),
                pendingOperationIDs: [operationID]
            ) { _, _ in }
        }
        XCTAssertNotNil(legalTenthousandthEdit.value)
        let operationCount = await noConflictLoad.value.semanticOperationIDs().count
        XCTAssertEqual(operationCount, 10_000)

        let timings = ColdLoadTimings(
            noConflictColdLoadMS: milliseconds(noConflictLoad.elapsed),
            legalTenthousandthEditMS: milliseconds(legalTenthousandthEdit.elapsed)
        )
        try attach(timings, named: "shared-plan-cold-load-performance.json")
        XCTAssertLessThan(timings.noConflictColdLoadMS, 5_000)
        XCTAssertLessThan(timings.legalTenthousandthEditMS, 5_000)
    }

    func testNearCapNoConflictInventoryAndHeadsCacheRemainBounded() async throws {
        let fixture = try loadFixture()
        let document = try SharedPlanAutomergeDocument(
            data: try decode(fixture.noConflictAt9999.document),
            replicaID: Self.replicaID
        )
        let inventory = try await timedAsync {
            try await document.conflictInventory()
        }
        XCTAssertTrue(inventory.value.isEmpty)
        let cachedInventory = try await timedAsync {
            try await document.conflictInventory()
        }
        XCTAssertTrue(cachedInventory.value.isEmpty)

        let timings = InventoryTimings(
            firstInventoryMS: milliseconds(inventory.elapsed),
            cachedInventoryMS: milliseconds(cachedInventory.elapsed)
        )
        try attach(timings, named: "shared-plan-no-conflict-inventory-performance.json")
        XCTAssertLessThan(timings.firstInventoryMS, 10_000)
        XCTAssertLessThan(timings.cachedInventoryMS, 50)
    }

    func testEarlyParentConflictWithLongTailInventoryRemainsBounded() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.earlyParentConflictAt10000.operationCount, 10_000)

        let parentConflictLoad = try timed {
            try SharedPlanAutomergeDocument(
                data: try decode(fixture.earlyParentConflictAt10000.document),
                replicaID: Self.replicaID
            )
        }
        let parentConflictInventory = try await timedAsync {
            try await parentConflictLoad.value.conflictInventory()
        }
        let parentConflicts = parentConflictInventory.value.filter {
            $0.kind == .parent && $0.path == ["circles", "9100"]
        }
        XCTAssertEqual(parentConflicts.count, 1)
        XCTAssertEqual(parentConflicts[0].candidates.count, 2)

        let cachedParentInventory = try await timedAsync {
            try await parentConflictLoad.value.conflictInventory()
        }
        XCTAssertEqual(cachedParentInventory.value, parentConflictInventory.value)

        let timings = ParentConflictTimings(
            coldLoadMS: milliseconds(parentConflictLoad.elapsed),
            firstInventoryMS: milliseconds(parentConflictInventory.elapsed),
            cachedInventoryMS: milliseconds(cachedParentInventory.elapsed)
        )
        try attach(timings, named: "shared-plan-parent-conflict-performance.json")
        XCTAssertLessThan(timings.coldLoadMS, 5_000)
        XCTAssertLessThan(timings.firstInventoryMS, 10_000)
        XCTAssertLessThan(timings.cachedInventoryMS, 50)
    }

    func testExactAlternatingRemovalReactivationAndCommunicationHistoryIsLinear() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.alternatingAt10000.operationCount, 10_000)
        XCTAssertEqual(fixture.alternatingAt10000.historyCount, 10_001)
        let document = try SharedPlanAutomergeDocument(
            data: try decode(fixture.alternatingAt10000.document),
            replicaID: Self.replicaID
        )

        let inventory = try await timedAsync {
            try await document.conflictInventory()
        }
        XCTAssertTrue(inventory.value.isEmpty)
        let cachedInventory = try await timedAsync {
            try await document.conflictInventory()
        }
        XCTAssertTrue(cachedInventory.value.isEmpty)

        let timings = AlternatingConflictTimings(
            firstInventoryMS: milliseconds(inventory.elapsed),
            cachedInventoryMS: milliseconds(cachedInventory.elapsed)
        )
        try attach(
            timings,
            named: "shared-plan-alternating-conflict-performance.json"
        )
        XCTAssertLessThan(timings.firstInventoryMS, 10_000)
        XCTAssertLessThan(timings.cachedInventoryMS, 50)
    }

    private func loadFixture() throws -> PerformanceFixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "automerge-conflict-performance-v1",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            PerformanceFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private func decode(_ base64URL: String) throws -> Data {
        try XCTUnwrap(Data(base64URLString: base64URL))
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> Timed<T> {
        let clock = ContinuousClock()
        let started = clock.now
        let value = try body()
        return Timed(value: value, elapsed: started.duration(to: clock.now))
    }

    private func timedAsync<T>(
        _ body: () async throws -> T
    ) async rethrows -> Timed<T> {
        let clock = ContinuousClock()
        let started = clock.now
        let value = try await body()
        return Timed(value: value, elapsed: started.duration(to: clock.now))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func attach<T: Encodable>(_ value: T, named name: String) throws {
        let diagnostic = String(
            data: try JSONEncoder.sorted.encode(value),
            encoding: .utf8
        ) ?? ""
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let replicaID = UUID(
        uuidString: "77777777-7777-4777-8777-777777777777"
    )!
}

private struct Timed<Value> {
    let value: Value
    let elapsed: Duration
}

private struct PerformanceFixture: Decodable {
    let fixtureVersion: Int
    let producer: String
    let planID: String
    let comiketNo: Int
    let actorUserID: String
    let noConflictAt9999: PerformanceDocument
    let earlyParentConflictAt10000: PerformanceDocument
    let alternatingAt10000: PerformanceDocument
}

private struct PerformanceDocument: Decodable {
    let document: String
    let heads: [String]
    let operationCount: Int
    let historyCount: Int
    let retainedOperationPayloadUTF8Bytes: Int
}

private struct ColdLoadTimings: Codable {
    let noConflictColdLoadMS: Double
    let legalTenthousandthEditMS: Double
}

private struct InventoryTimings: Codable {
    let firstInventoryMS: Double
    let cachedInventoryMS: Double
}

private struct ParentConflictTimings: Codable {
    let coldLoadMS: Double
    let firstInventoryMS: Double
    let cachedInventoryMS: Double
}

private struct AlternatingConflictTimings: Codable {
    let firstInventoryMS: Double
    let cachedInventoryMS: Double
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
