//
//  DownloadProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI

/// A focused full-screen state with one persistent orientation cue and a
/// bottom-anchored message. The scroll view keeps the layout usable at large
/// Dynamic Type sizes without giving short content an arbitrary vertical center.
struct FocusedActionSurface<Content: View>: View {
    let symbolName: String
    let tint: Color
    let animatesBackdrop: Bool
    @ViewBuilder private let content: () -> Content

    init(
        symbolName: String,
        tint: Color = .accentColor,
        animatesBackdrop: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.symbolName = symbolName
        self.tint = tint
        self.animatesBackdrop = animatesBackdrop
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(640, max(0, geometry.size.width - 56))
            let contentHeight = max(0, geometry.size.height - 88)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LucideIcon(symbolName, size: 34)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)

                    Spacer(minLength: 48)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: contentWidth, alignment: .leading)
                .frame(minHeight: contentHeight, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 44)
                .frame(width: geometry.size.width, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            CatalogAmbientBackdrop(
                symbolName: symbolName,
                tint: tint,
                animates: animatesBackdrop
            )
        }
    }
}

struct FocusedActionButton<Label: View>: View {
    enum Emphasis {
        case primary
        case secondary
    }

    let role: ButtonRole?
    let emphasis: Emphasis
    let tint: Color
    let action: () -> Void
    @ViewBuilder private let label: () -> Label

    init(
        role: ButtonRole? = nil,
        emphasis: Emphasis = .primary,
        tint: Color = .accentColor,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.role = role
        self.emphasis = emphasis
        self.tint = tint
        self.action = action
        self.label = label
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                switch emphasis {
                case .primary:
                    button.buttonStyle(.glassProminent)
                case .secondary:
                    button.buttonStyle(.glass)
                }
            } else {
                switch emphasis {
                case .primary:
                    button.buttonStyle(.borderedProminent)
                case .secondary:
                    button.buttonStyle(.bordered)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(tint)
    }

    private var button: some View {
        Button(role: role, action: action) {
            label()
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A shared shell for catalog discovery, download, and initialization.
struct CatalogStatusSurface<Content: View>: View {
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
        FocusedActionSurface(
            symbolName: symbolName,
            animatesBackdrop: true
        ) {
            Text(eyebrow)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 34)
        }
        .accessibilityIdentifier("catalog-status-surface")
    }
}

struct CatalogActivityIndicator: View {
    let accessibilityLabel: String

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(Color.accentColor)
            .frame(width: 44, height: 44)
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

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
        FocusedActionSurface(symbolName: symbolName, tint: .red) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(advice)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(alignment: .top, spacing: 12) {
                LucideIcon("exclamationmark.circle.fill", size: 22)
                    .foregroundStyle(.red)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .overlay(alignment: .top) {
                Divider().overlay(Color.red.opacity(0.28))
            }
            .overlay(alignment: .bottom) {
                Divider().overlay(Color.red.opacity(0.16))
            }
            .padding(.top, 30)

            VStack(alignment: .leading, spacing: 12) {
                actions()
            }
            .padding(.top, 26)
        }
        .accessibilityIdentifier("catalog-error-surface")
    }
}

private struct CatalogAmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let symbolName: String
    let tint: Color
    let animates: Bool
    @State private var isFloating = false

    var body: some View {
        Image(LucideIcon.assetName(for: symbolName))
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint.opacity(0.045))
            .containerRelativeFrame(.horizontal) { width, _ in
                width * 1.5
            }
            .rotationEffect(.degrees(isFloating ? -5 : -9))
            .scaleEffect(isFloating ? 1.035 : 0.97)
            .offset(x: isFloating ? 18 : -14, y: isFloating ? -12 : 18)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                guard animates, !accessibilityReduceMotion else { return }
                withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                    isFloating = true
                }
            }
            .ignoresSafeArea()
    }
}

struct DownloadProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    var progresses: Readiness.Progresses

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    progresses.fractionCompleted,
                    format: .percent.precision(.fractionLength(1))
                )
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)

                ProgressView(value: progresses.fractionCompleted, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .scaleEffect(y: 2, anchor: .center)
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: 0.22),
                        value: progresses.fractionCompleted
                    )

                DownloadTransferMetricsView(progresses: progresses)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(progresses, id: \.type) { progress in
                    DatabaseProgressRow(progress: progress)

                    if progress.type != progresses.last?.type {
                        Divider()
                    }
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
        subtitle: String(localized: "Downloading databases, this may take a while...")
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
