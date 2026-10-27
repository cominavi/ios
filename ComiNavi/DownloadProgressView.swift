//
//  DownloadProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI

extension Font {
    /// The hero title of a full-screen focused state, such as "Downloading
    /// catalog". A documented exception to the type roles: the rounded
    /// large title is the identity of these one-message screens.
    static var focusedSurfaceTitle: Font {
        .system(.largeTitle, design: .rounded, weight: .bold)
    }
}

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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LucideIcon(symbolName, size: IconSize.hero)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)

                    Spacer(minLength: Spacing.xxxLarge)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Fill the visible height, so the message sits at the bottom.
                .frame(
                    minHeight: max(0, geometry.size.height - Spacing.xxxLarge * 2),
                    alignment: .topLeading
                )
                .readableWidth(ReadableWidth.form)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.vertical, Spacing.xxxLarge)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
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

/// The full-width action of a focused state. It uses the design-system
/// action buttons; a custom tint (red for a destructive action, secondary
/// for cancel) colors the title of a secondary button, or fills a primary
/// one with the system prominent style.
struct FocusedActionButton<Label: View>: View {
    enum Emphasis {
        case primary
        case secondary
    }

    let role: ButtonRole?
    let emphasis: Emphasis
    let tint: Color?
    let action: () -> Void
    @ViewBuilder private let label: () -> Label

    init(
        role: ButtonRole? = nil,
        emphasis: Emphasis = .primary,
        tint: Color? = nil,
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
        switch (emphasis, tint) {
        case (.primary, .none):
            Button(role: role, action: action, label: label)
                .buttonStyle(ActionButtonStyle(role: .primary, size: .large))
        case (.primary, .some(let tint)):
            // A tinted primary action, such as a red destructive button. The
            // system prominent style draws white text on the tint.
            Button(role: role, action: action) {
                label()
                    .font(.largeControl)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: Radius.control))
            .tint(tint)
        case (.secondary, let tint):
            Button(role: role, action: action) {
                if let tint {
                    label().foregroundStyle(tint)
                } else {
                    label()
                }
            }
            .buttonStyle(ActionButtonStyle(role: .secondary, size: .large))
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
                .font(.rowTitle)
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.focusedSurfaceTitle)
                .foregroundStyle(.primary)
                .wrapsFully()
                .padding(.top, Spacing.small)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xxxLarge)
        }
        // Scrolling stays on: at accessibility sizes the progress rows are
        // taller than the screen. FocusedActionSurface stops short content
        // from bouncing.
        .accessibilityIdentifier("catalog-status-surface")
    }
}

struct CatalogActivityIndicator: View {
    private let accessibilityLabel: Text

    /// Literal labels resolve through the string catalog, so call sites can
    /// pass an English source string directly.
    init(accessibilityLabel: LocalizedStringResource) {
        self.accessibilityLabel = Text(accessibilityLabel)
    }

    /// Already-localized runtime text, such as a status message.
    @_disfavoredOverload
    init(accessibilityLabel: String) {
        self.accessibilityLabel = Text(verbatim: accessibilityLabel)
    }

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(Color.accentColor)
            .frame(width: 44, height: 44)
            .accessibilityLabel(accessibilityLabel)
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: Spacing.xxLarge) {
                        LucideIcon(symbolName, size: IconSize.hero)
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)

                        Text(message)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .wrapsFully()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Spacing.large)
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.red.opacity(0.28))
                                    .frame(height: 0.5)
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.red.opacity(0.16))
                                    .frame(height: 0.5)
                            }
                    }
                    .accessibilityElement(children: .combine)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: Spacing.xxxLarge)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.focusedSurfaceTitle)
                            .foregroundStyle(.primary)
                            .wrapsFully()

                        Text(advice)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .wrapsFully()
                            .padding(.top, Spacing.medium)

                        VStack(alignment: .leading, spacing: Spacing.medium) {
                            actions()
                        }
                        .padding(.top, Spacing.xxxLarge)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Fill the visible height, so the title and actions sit at the bottom.
                .frame(
                    minHeight: max(0, geometry.size.height - Spacing.xLarge - Spacing.xxxLarge),
                    alignment: .topLeading
                )
                .readableWidth(ReadableWidth.form)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.xLarge)
                .padding(.bottom, Spacing.xxxLarge)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            CatalogAmbientBackdrop(
                symbolName: symbolName,
                tint: .red,
                animates: false
            )
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
        VStack(alignment: .leading, spacing: Spacing.xxLarge) {
            VStack(alignment: .leading, spacing: Spacing.large) {
                Text(
                    progresses.fractionCompleted,
                    format: .percent.precision(.fractionLength(1))
                )
                    .font(.focusedSurfaceTitle)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .singleLineToken()

                CapsuleProgressBar(segments: [
                    .init(fraction: progresses.fractionCompleted, color: .accentColor),
                ])
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: 0.22),
                        value: progresses.fractionCompleted
                    )

                DownloadTransferMetricsView(progresses: progresses)
            }

            VStack(alignment: .leading, spacing: Spacing.large) {
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
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                LucideLabel(verbatim: progress.type.localizedName, icon: iconName)
                    .font(.control)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)

                Spacer(minLength: Spacing.small)

                if isComplete {
                    LucideIcon("checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Complete"))
                } else {
                    Text(
                        progress.fractionCompleted,
                        format: .percent.precision(.fractionLength(1))
                    )
                        .font(.meta)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .singleLineToken()
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

/// A stacked capsule progress bar. Every progress bar in the app that is not a
/// plain system `ProgressView` uses this one track, at one height.
///
/// Segments are drawn in order from the back, so list the largest fraction
/// first: `CapsuleProgressBar(segments: [.init(fraction: 0.6, color: .orange),
/// .init(fraction: 0.3, color: .green)])`.
struct CapsuleProgressBar: View {
    struct Segment {
        var fraction: Double
        var color: Color
    }

    let segments: [Segment]
    @ScaledMetric(relativeTo: .body) private var height = 8.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                ForEach(segments.indices, id: \.self) { index in
                    let fraction = min(max(segments[index].fraction, 0), 1)
                    Capsule()
                        .fill(segments[index].color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview {
    CatalogStatusSurface(
        symbolName: "arrow.down.circle.fill",
        eyebrow: "C108",
        title: String(localized: "Downloading\ncatalog"),
        subtitle: String(localized: "Downloading the catalog, this may take a while…")
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
