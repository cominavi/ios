import Foundation
import XCTest
@testable import ComiNavi

@MainActor
final class DownloadProgressTrackerTests: XCTestCase {
    func testCoalescesProgressAndCalculatesSmoothedSpeed() throws {
        let tracker = makeTracker()

        let first = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 100,
            totalBytes: 1_000,
            now: 0
        ))
        XCTAssertEqual(first[0].completedBytes, 100)
        XCTAssertNil(first[0].bytesPerSecond)

        XCTAssertNil(tracker.record(
            type: .image,
            completedBytes: 200,
            totalBytes: 1_000,
            now: 0.25
        ))

        let firstSample = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 300,
            totalBytes: 1_000,
            now: 0.5
        ))
        XCTAssertEqual(
            try XCTUnwrap(firstSample[0].bytesPerSecond),
            400,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(firstSample.estimatedRemainingTime),
            1.75,
            accuracy: 0.001
        )

        let smoothedSample = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 400,
            totalBytes: 1_000,
            now: 1
        ))
        XCTAssertEqual(
            try XCTUnwrap(smoothedSample[0].bytesPerSecond),
            350,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(smoothedSample.estimatedRemainingTime),
            Double(600) / 350,
            accuracy: 0.001
        )
    }

    func testPublishesCompletionWithoutWaitingForCadence() throws {
        let tracker = makeTracker()
        _ = tracker.record(
            type: .image,
            completedBytes: 100,
            totalBytes: 1_000,
            now: 0
        )

        let completion = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 1_000,
            totalBytes: 1_000,
            now: 0.1
        ))

        XCTAssertEqual(completion[0].fractionCompleted, 1)
        XCTAssertNil(completion[0].bytesPerSecond)
        XCTAssertNil(completion.estimatedRemainingTime)
    }

    func testRestartPublishesImmediatelyAndResetsSpeed() throws {
        let tracker = makeTracker()
        _ = tracker.record(
            type: .image,
            completedBytes: 100,
            totalBytes: 1_000,
            now: 0
        )
        _ = tracker.record(
            type: .image,
            completedBytes: 300,
            totalBytes: 1_000,
            now: 0.5
        )

        let restarted = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 50,
            totalBytes: 1_000,
            now: 0.6
        ))

        XCTAssertEqual(restarted[0].completedBytes, 50)
        XCTAssertNil(restarted[0].bytesPerSecond)
    }

    func testWaitsForEveryActiveDownloadBeforeEstimatingAggregateTransfer() throws {
        let tracker = DownloadProgressTracker(
            progresses: [
                .init(type: .main, totalBytes: 1_000, completedBytes: 0),
                .init(type: .image, totalBytes: 2_000, completedBytes: 0)
            ],
            configuration: .init(updateInterval: 0.5, smoothingFactor: 0.25)
        )

        _ = tracker.record(type: .main, completedBytes: 100, totalBytes: 1_000, now: 0)
        let partial = try XCTUnwrap(tracker.record(
            type: .main,
            completedBytes: 300,
            totalBytes: 1_000,
            now: 0.5
        ))
        XCTAssertNil(partial.bytesPerSecond)
        XCTAssertNil(partial.estimatedRemainingTime)

        _ = tracker.record(type: .image, completedBytes: 100, totalBytes: 2_000, now: 0.5)
        let aggregate = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 300,
            totalBytes: 2_000,
            now: 1
        ))

        XCTAssertEqual(
            try XCTUnwrap(aggregate.bytesPerSecond),
            700,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(aggregate.estimatedRemainingTime),
            Double(2_400) / 700,
            accuracy: 0.001
        )
    }

    func testKeepsEstimatedTotalWhenServerDoesNotReportOne() throws {
        let tracker = makeTracker()

        let progress = try XCTUnwrap(tracker.record(
            type: .image,
            completedBytes: 100,
            totalBytes: NSURLSessionTransferSizeUnknown,
            now: 0
        ))

        XCTAssertEqual(progress[0].totalBytes, 1_000)
        XCTAssertEqual(progress[0].fractionCompleted, 0.1, accuracy: 0.001)
    }

    private func makeTracker() -> DownloadProgressTracker {
        DownloadProgressTracker(
            progresses: [
                .init(type: .image, totalBytes: 1_000, completedBytes: 0)
            ],
            configuration: .init(updateInterval: 0.5, smoothingFactor: 0.25)
        )
    }
}
