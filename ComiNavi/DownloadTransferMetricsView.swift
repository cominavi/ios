//
//  DownloadTransferMetricsView.swift
//  ComiNavi
//

import SwiftUI

struct DownloadTransferMetricsView: View {
    @Environment(\.locale) private var locale
    let progresses: Readiness.Progresses

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(formattedCompletedBytes) / \(formattedTotalBytes)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transferMetrics
                }

                VStack(spacing: 10) {
                    transferMetrics
                }
            }
        }
    }

    @ViewBuilder
    private var transferMetrics: some View {
        DownloadTransferMetric(
            title: "Speed",
            value: formattedSpeed
        )
        DownloadTransferMetric(
            title: "Remaining",
            value: formattedRemainingTime
        )
    }

    private var formattedCompletedBytes: String {
        progresses.completedBytes.formatted(byteCountFormat)
    }

    private var formattedTotalBytes: String {
        progresses.totalBytes.formatted(byteCountFormat)
    }

    private var formattedSpeed: String {
        guard let bytesPerSecond = progresses.bytesPerSecond else {
            return String(localized: "Calculating…", locale: locale)
        }
        let byteCount = Int64(bytesPerSecond.rounded()).formatted(byteCountFormat)
        return String.localizedStringWithFormat(
            String(localized: "%@/s", locale: locale),
            byteCount
        )
    }

    private var formattedRemainingTime: String {
        guard let estimatedRemainingTime = progresses.estimatedRemainingTime else {
            return String(localized: "Calculating…", locale: locale)
        }
        return Duration.seconds(quantized(estimatedRemainingTime)).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .abbreviated,
                maximumUnitCount: 2
            )
            .locale(locale)
        )
    }

    private var byteCountFormat: ByteCountFormatStyle {
        .byteCount(
            style: .file,
            allowedUnits: [.bytes, .kb, .mb, .gb],
            spellsOutZero: true,
            includesActualByteCount: false
        )
        .locale(locale)
    }

    private func quantized(_ duration: TimeInterval) -> TimeInterval {
        let interval: TimeInterval = switch duration {
        case ..<60: 5
        case ..<600: 10
        case ..<3_600: 30
        default: 60
        }
        return max(interval, (duration / interval).rounded(.up) * interval)
    }
}

private struct DownloadTransferMetric: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
