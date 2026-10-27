import SwiftUI
import UIKit

struct CurrentLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appHapticFeedback) private var hapticFeedback

    let location: LocatedMapUser
    let eventNumber: Int
    let onUpdateLocation: () -> Void

    @State private var copied = false

    var body: some View {
        NavigationStack {
            // The sheet opens at the medium detent; at large text sizes the
            // content scrolls instead of being cut off.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    locationHeader
                    canonicalLocation
                    sensorDetails
                    actions
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.small)
                .padding(.bottom, Spacing.xLarge)
                .readableWidth(ReadableWidth.form)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Your location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MapSheetCloseButton {
                        dismiss()
                    }
                    .accessibilityIdentifier("current-location-close")
                }
            }
        }
        .accessibilityIdentifier("current-location-sheet")
    }

    private var locationHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // The same short address as map search and the circle sheet.
            Text(verbatim: location.address.displayText(.short))
                .font(.largeTitle.monospacedDigit().bold())
                .foregroundStyle(.primary)
                .accessibilityLabel(Text(verbatim: location.address.formatted(.short)))
                .accessibilityIdentifier("current-location-space-code")

            Text(verbatim: dayAndVenue)
                .font(.sectionTitle)
                .foregroundStyle(.secondary)

            LucideLabel(
                resource: sourcePresentation.title,
                icon: sourcePresentation.icon
            )
            .font(.control)
            .foregroundStyle(.secondary)
        }
        .wrapsFully()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Day 1 · West 1", in which neither unit can break across lines.
    private var dayAndVenue: String {
        String(localized: "Day \(location.sceneID.day) · \(location.venueDisplayName)")
            .components(separatedBy: " · ")
            .map(NonBreaking.spaces)
            .joined(separator: " · ")
    }

    private var sourcePresentation: (title: LocalizedStringResource, icon: String) {
        switch location.source {
        case .guidedLocator:
            ("Positioned with Where am I?", "location.viewfinder")
        case .mapLongPress:
            ("Positioned from your map press", "hand.tap.fill")
        case .gps:
            ("Updated automatically with GPS", "location.fill")
        }
    }

    /// The Japanese address is what venue staff and printed signs use, so it
    /// stays in Japanese in every locale; the caption explains why.
    private var canonicalLocation: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Japanese address (for staff and signs)")
                .font(.meta.weight(.semibold))
                .foregroundStyle(.secondary)
                .wrapsFully()

            // A card, not an inset tile: it is not inside another card.
            Text(verbatim: location.canonicalLocationText)
                .font(.sectionTitle)
                .textSelection(.enabled)
                .wrapsFully()
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.card)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("current-location-canonical-text")
    }

    @ViewBuilder
    private var sensorDetails: some View {
        if location.locationReading != nil || location.headingDegrees != nil {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let reading = location.locationReading {
                    LucideLabel(
                        "GPS reference · about \(Int(reading.horizontalAccuracy.rounded())) m accuracy",
                        icon: "location"
                    )
                }
                if let heading = location.headingDegrees {
                    LucideLabel(
                        "Compass heading · \(Int(heading.rounded()))° \(cardinalDirection(heading))",
                        icon: "location.north.line.fill"
                    )
                }
            }
            .font(.rowSubtitle)
            .foregroundStyle(.secondary)
            .wrapsFully()
            .accessibilityElement(children: .combine)
        }
    }

    /// Copy is the one primary action. Update reopens Where am I? and sits
    /// beside it, or below it when a title would wrap.
    private var actions: some View {
        AdaptiveButtonRow {
            copyButton

            Button {
                dismiss()
                onUpdateLocation()
            } label: {
                LucideLabel("Update location", icon: "location.viewfinder")
            }
            .buttonStyle(ActionButtonStyle(role: .secondary, size: .large))
            .accessibilityIdentifier("current-location-update")
        }
    }

    private var copyButton: some View {
        Button {
            let sharedLocation = SharedComiketLocation(
                location: location,
                eventNumber: eventNumber
            )
            UIPasteboard.general.string = sharedLocation?.clipboardText(
                locationText: location.canonicalLocationText
            ) ?? location.canonicalLocationText
            copied = true
            hapticFeedback?.play(.copyConfirmation)
        } label: {
            LucideLabel(
                resource:
                copied
                    ? LocalizedStringResource("Copied")
                    : LocalizedStringResource("Copy location"),
                icon: copied ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(ActionButtonStyle(role: .primary, size: .large))
        .accessibilityHint("Copies the venue location and a link that opens it in ComiNavi")
        .accessibilityIdentifier("current-location-copy")
        .animation(.default, value: copied)
    }

    private func cardinalDirection(_ degrees: Double) -> String {
        let directions = [
            String(localized: "N"),
            String(localized: "NE"),
            String(localized: "E"),
            String(localized: "SE"),
            String(localized: "S"),
            String(localized: "SW"),
            String(localized: "W"),
            String(localized: "NW"),
        ]
        let normalized = degrees.truncatingRemainder(dividingBy: 360) + (degrees < 0 ? 360 : 0)
        let index = Int((normalized / 45).rounded()) % directions.count
        return directions[index]
    }
}
