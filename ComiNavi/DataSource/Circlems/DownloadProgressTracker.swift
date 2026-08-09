//
//  DownloadProgressTracker.swift
//  ComiNavi
//

import Foundation

/// Coalesces noisy URLSession callbacks into stable, display-ready snapshots.
///
/// The tracker keeps the latest byte counts internally, but only publishes them
/// at a controlled cadence. Transfer speed uses exponential smoothing so short
/// network bursts do not make the ETA jump on every callback.
@MainActor
final class DownloadProgressTracker {
    struct Configuration: Equatable, Sendable {
        let updateInterval: TimeInterval
        let smoothingFactor: Double

        static let live = Configuration(
            updateInterval: 0.5,
            smoothingFactor: 0.25
        )
    }

    private struct Observation {
        var sampledBytes: Int64
        var sampledAt: TimeInterval
        var smoothedBytesPerSecond: Double?
        var totalBytes: Int64
    }

    private let configuration: Configuration
    private var progresses: Readiness.Progresses
    private var observations: [CirclemsDataSourceDatabaseType: Observation] = [:]
    private var lastPublishedAt: TimeInterval?

    init(
        progresses: Readiness.Progresses,
        configuration: Configuration = .live
    ) {
        self.progresses = progresses
        self.configuration = configuration
    }

    /// Records raw progress and returns a new UI snapshot when one is due.
    ///
    /// The first observation, a resumed-download regression, and completion are
    /// published immediately. Routine updates are limited by `updateInterval`.
    func record(
        type: CirclemsDataSourceDatabaseType,
        completedBytes: Int64,
        totalBytes: Int64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Readiness.Progresses? {
        guard let index = progresses.firstIndex(where: { $0.type == type }) else {
            return nil
        }

        let sanitizedCompletedBytes = max(completedBytes, 0)
        let previousProgress = progresses[index]
        let sanitizedTotalBytes = totalBytes > 0 ? totalBytes : previousProgress.totalBytes
        let previousObservation = observations[type]
        let didRestart = previousObservation.map {
            sanitizedCompletedBytes < $0.sampledBytes ||
                (sanitizedTotalBytes > 0 && sanitizedTotalBytes != $0.totalBytes)
        } ?? false

        progresses[index].completedBytes = sanitizedCompletedBytes
        progresses[index].totalBytes = sanitizedTotalBytes

        if previousObservation == nil || didRestart {
            progresses[index].bytesPerSecond = nil
            observations[type] = Observation(
                sampledBytes: sanitizedCompletedBytes,
                sampledAt: now,
                smoothedBytesPerSecond: nil,
                totalBytes: sanitizedTotalBytes
            )
            lastPublishedAt = now
            return progresses
        }

        let isComplete = sanitizedTotalBytes > 0 && sanitizedCompletedBytes >= sanitizedTotalBytes
        let elapsedSincePublication = now - (lastPublishedAt ?? now)
        guard isComplete || elapsedSincePublication >= configuration.updateInterval else {
            return nil
        }

        refreshTransferSpeeds(now: now)
        lastPublishedAt = now
        return progresses
    }

    private func refreshTransferSpeeds(now: TimeInterval) {
        for index in progresses.indices {
            let type = progresses[index].type
            guard var observation = observations[type] else { continue }

            let completedBytes = progresses[index].completedBytes
            let totalBytes = progresses[index].totalBytes
            let isComplete = totalBytes > 0 && completedBytes >= totalBytes

            if isComplete {
                progresses[index].bytesPerSecond = nil
                observation.sampledBytes = completedBytes
                observation.sampledAt = now
                observation.smoothedBytesPerSecond = nil
                observation.totalBytes = totalBytes
                observations[type] = observation
                continue
            }

            let elapsed = now - observation.sampledAt
            guard elapsed >= configuration.updateInterval else { continue }

            let transferredBytes = completedBytes - observation.sampledBytes
            guard transferredBytes >= 0 else {
                progresses[index].bytesPerSecond = nil
                observations[type] = Observation(
                    sampledBytes: completedBytes,
                    sampledAt: now,
                    smoothedBytesPerSecond: nil,
                    totalBytes: totalBytes
                )
                continue
            }

            let measuredSpeed = Double(transferredBytes) / elapsed
            let smoothedSpeed: Double
            if let previousSpeed = observation.smoothedBytesPerSecond {
                smoothedSpeed = previousSpeed * (1 - configuration.smoothingFactor) +
                    measuredSpeed * configuration.smoothingFactor
            } else {
                smoothedSpeed = measuredSpeed
            }

            progresses[index].bytesPerSecond = smoothedSpeed >= 1 ? smoothedSpeed : nil
            observation.sampledBytes = completedBytes
            observation.sampledAt = now
            observation.smoothedBytesPerSecond = smoothedSpeed >= 1 ? smoothedSpeed : nil
            observation.totalBytes = totalBytes
            observations[type] = observation
        }
    }
}
