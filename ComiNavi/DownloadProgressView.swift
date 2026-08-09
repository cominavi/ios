//
//  DownloadProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI

/// A shared, intentionally left-aligned shell for catalog work in progress.
///
/// Keeping discovery, download, and database initialization in the same shell
/// makes the app feel like one coherent operation instead of a collection of
/// unrelated loading screens.
struct CatalogStatusSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let symbolName: String
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder private let content: () -> Content

    init(
        symbolName: String,
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.symbolName = symbolName
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusMark
                    .padding(.bottom, 28)

                Text(eyebrow)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                    .tracking(1.1)

                Text(title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 6)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("catalog-status-surface")
    }

    private var statusMark: some View {
        HStack(spacing: 14) {
            LucideIcon(symbolName)
                .font(.system(size: 32, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )

            Rectangle()
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 1, height: 48)

            if accessibilityReduceMotion {
                LucideIcon("ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("Loading"))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentColor)
                    .accessibilityLabel(Text("Loading"))
            }
        }
    }
}

/// A left-aligned recovery surface for errors that block catalog access.
struct CatalogErrorSurface<Actions: View>: View {
    let symbolName: String
    let title: String
    let message: String
    let advice: String
    @ViewBuilder private let actions: () -> Actions

    init(
        symbolName: String,
        title: String,
        message: String,
        advice: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.symbolName = symbolName
        self.title = title
        self.message = message
        self.advice = advice
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LucideIcon(symbolName)
                    .font(.system(size: 44, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                    .frame(width: 72, height: 72)
                    .background(
                        Color.red.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .padding(.bottom, 28)

                Text(title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(advice)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                VStack(alignment: .leading, spacing: 10) {
                    LucideLabel("Error", icon: "exclamationmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)

                    Text(message)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    Color.red.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                }
                .padding(.top, 26)

                VStack(alignment: .leading, spacing: 12) {
                    actions()
                }
                .padding(.top, 26)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("catalog-error-surface")
    }
}

struct DownloadProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    var progresses: Readiness.Progresses

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Downloading databases, this may take a while...")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Text(
                        progresses.fractionCompleted,
                        format: .percent.precision(.fractionLength(1))
                    )
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }

                ProgressView(value: progresses.fractionCompleted, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .scaleEffect(y: 1.6, anchor: .center)
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: 0.22),
                        value: progresses.fractionCompleted
                    )

                DownloadTransferMetricsView(progresses: progresses)
            }
            .padding(20)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 14) {
                ForEach(progresses, id: \.type) { progress in
                    DatabaseProgressRow(progress: progress)
                }
            }
        }
    }

}

private struct DatabaseProgressRow: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let progress: Readiness.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LucideLabel(verbatim: progress.type.localizedName, icon: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if isComplete {
                    LucideIcon("checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Complete"))
                } else {
                    Text(
                        progress.fractionCompleted,
                        format: .percent.precision(.fractionLength(1))
                    )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)
                .tint(isComplete ? .green : Color.accentColor.opacity(0.75))
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.22),
                    value: progress.fractionCompleted
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            isComplete
                ? Text("Complete")
                : Text(
                    progress.fractionCompleted,
                    format: .percent.precision(.fractionLength(1))
                )
        )
    }

    private var isComplete: Bool {
        progress.totalBytes > 0 && progress.completedBytes >= progress.totalBytes
    }

    private var iconName: String {
        switch progress.type {
        case .main:
            "map"
        case .image:
            "photo.stack"
        }
    }
}

#Preview {
    CatalogStatusSurface(
        symbolName: "arrow.down.circle.fill",
        eyebrow: "C108",
        title: String(localized: "Downloading\ndatabases"),
        subtitle: String.localizedStringWithFormat(
            String(localized: "Downloading %@ databases…"),
            "C108"
        )
    ) {
        DownloadProgressView(progresses: [
            .init(
                type: .main,
                totalBytes: 4_880_130,
                completedBytes: 2_600_000,
                bytesPerSecond: 840_000
            ),
            .init(
                type: .image,
                totalBytes: 341_840_565,
                completedBytes: 94_000_000,
                bytesPerSecond: 7_650_000
            )
        ])
    }
}
