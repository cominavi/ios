import Foundation
import SwiftUI

struct FeatureOnboardingID: Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let exploreGalleryZoom = FeatureOnboardingID(
        rawValue: "explore-gallery-zoom-v1"
    )
}

struct FeatureOnboardingStore {
    private static let keyPrefix = "cominavi.onboarding.completed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldPresent(_ onboarding: FeatureOnboardingID) -> Bool {
        !defaults.bool(forKey: storageKey(for: onboarding))
    }

    func markCompleted(_ onboarding: FeatureOnboardingID) {
        defaults.set(true, forKey: storageKey(for: onboarding))
    }

    private func storageKey(for onboarding: FeatureOnboardingID) -> String {
        "\(Self.keyPrefix).\(onboarding.rawValue)"
    }
}

extension View {
    func featureOnboardingDialog<Illustration: View>(
        isPresented: Binding<Bool>,
        accessibilityIdentifier: String,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        dismissButtonTitle: LocalizedStringResource,
        onDismiss: @escaping () -> Void,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        modifier(FeatureOnboardingDialogModifier(
            isPresented: isPresented,
            dialogAccessibilityIdentifier: accessibilityIdentifier,
            title: title,
            message: message,
            dismissButtonTitle: dismissButtonTitle,
            onDismiss: onDismiss,
            illustration: illustration()
        ))
    }
}

private struct FeatureOnboardingDialogModifier<Illustration: View>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var isPresented: Bool
    let dialogAccessibilityIdentifier: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let dismissButtonTitle: LocalizedStringResource
    let onDismiss: () -> Void
    let illustration: Illustration

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)

            if isPresented {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                FeatureOnboardingDialog(
                    accessibilityIdentifier: dialogAccessibilityIdentifier,
                    title: title,
                    message: message,
                    dismissButtonTitle: dismissButtonTitle,
                    onDismiss: dismiss,
                    illustration: illustration
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .transition(
                    accessibilityReduceMotion
                        ? .opacity
                        : .scale(scale: 0.96).combined(with: .opacity)
                )
                .zIndex(1)
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.28),
            value: isPresented
        )
    }

    private func dismiss() {
        onDismiss()
        isPresented = false
    }
}

private struct FeatureOnboardingDialog<Illustration: View>: View {
    let accessibilityIdentifier: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let dismissButtonTitle: LocalizedStringResource
    let onDismiss: () -> Void
    let illustration: Illustration

    var body: some View {
        VStack(spacing: 0) {
            illustration

            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Button(action: onDismiss) {
                Text(dismissButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Color.accentColor)
            .padding(.top, 24)
            .accessibilityIdentifier("\(accessibilityIdentifier)-dismiss")
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color(uiColor: .secondarySystemBackground))
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ExploreGalleryZoomOnboardingIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        PhaseAnimator(phases) { phase in
            ExploreGalleryZoomOnboardingScene(phase: phase)
        } animation: { phase in
            accessibilityReduceMotion ? nil : phase.animation
        }
        .frame(height: 136)
        .accessibilityHidden(true)
    }

    private var phases: [ExploreGalleryZoomOnboardingPhase] {
        accessibilityReduceMotion
            ? [.overview]
            : ExploreGalleryZoomOnboardingPhase.allCases
    }
}

private enum ExploreGalleryZoomOnboardingPhase: CaseIterable {
    case overview
    case touching
    case zoomedIn
    case released

    var galleryScale: CGFloat {
        switch self {
        case .overview, .touching: 0.76
        case .zoomedIn, .released: 1.08
        }
    }

    var touchSeparation: CGFloat {
        switch self {
        case .overview, .touching: 28
        case .zoomedIn, .released: 68
        }
    }

    var touchOpacity: Double {
        switch self {
        case .overview, .released: 0
        case .touching, .zoomedIn: 1
        }
    }

    var animation: Animation {
        switch self {
        case .overview: .easeOut(duration: 0.55)
        case .touching: .easeOut(duration: 0.25)
        case .zoomedIn: .easeInOut(duration: 0.8)
        case .released: .easeOut(duration: 0.3)
        }
    }
}

private struct ExploreGalleryZoomOnboardingScene: View {
    let phase: ExploreGalleryZoomOnboardingPhase

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)

            HStack(spacing: 10) {
                ForEach(0 ..< 5, id: \.self) { index in
                    ExploreGalleryZoomOnboardingTile(index: index)
                }
            }
            .scaleEffect(phase.galleryScale)

            ForEach([-1.0, 1.0], id: \.self) { direction in
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 4)
                    }
                    .offset(
                        x: direction * phase.touchSeparation,
                        y: 28
                    )
                    .opacity(phase.touchOpacity)
            }
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 14))
    }
}

private struct ExploreGalleryZoomOnboardingTile: View {
    let index: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(tileColor)
            .frame(width: 52, height: 78)
            .overlay {
                LucideIcon("photo.stack", size: 22)
                    .foregroundStyle(iconColor)
            }
    }

    private var tileColor: Color {
        switch index {
        case 1, 3: Color.accentColor.opacity(0.2)
        default: Color(uiColor: .tertiarySystemFill)
        }
    }

    private var iconColor: Color {
        switch index {
        case 1, 3: Color.accentColor
        default: Color.secondary.opacity(0.7)
        }
    }
}

#Preview("Explore zoom onboarding") {
    @Previewable @State var isPresented = true

    Color(uiColor: .systemGroupedBackground)
        .featureOnboardingDialog(
            isPresented: $isPresented,
            accessibilityIdentifier: "explore-zoom-onboarding",
            title: "Make Explore yours",
            message: "Pinch the gallery to make circle images larger or fit more on screen.",
            dismissButtonTitle: "Got it",
            onDismiss: {}
        ) {
            ExploreGalleryZoomOnboardingIllustration()
        }
}
