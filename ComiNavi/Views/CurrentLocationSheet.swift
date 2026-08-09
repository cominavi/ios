import SwiftUI
import UIKit

struct CurrentLocationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let location: LocatedMapUser
    let eventNumber: Int
    let onUpdateLocation: () -> Void

    @State private var copied = false
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                locationHeader
                canonicalLocation
                sensorDetails
                shareActions
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Your location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Update") {
                        dismiss()
                        onUpdateLocation()
                    }
                    .accessibilityLabel("Update location")
                    .accessibilityIdentifier("current-location-update")
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyFeedback)
        .accessibilityIdentifier("current-location-sheet")
    }

    private var locationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location.spaceCode)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospaced()
                .foregroundStyle(.primary)
                .accessibilityIdentifier("current-location-space-code")

            Text("Day \(location.sceneID.day) · \(location.venueDisplayName)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            LucideLabel(
                resource:
                location.source == .mapLongPress
                    ? LocalizedStringResource("Positioned from your map press")
                    : LocalizedStringResource("Positioned with Where Am I"),
                icon: location.source == .mapLongPress ? "hand.tap.fill" : "location.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canonicalLocation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(location.canonicalLocationText)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("current-location-canonical-text")
    }

    @ViewBuilder
    private var sensorDetails: some View {
        if location.locationReading != nil || location.headingDegrees != nil {
            VStack(alignment: .leading, spacing: 12) {
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
            .font(.body)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var shareActions: some View {
        Button {
            let sharedLocation = SharedComiketLocation(
                location: location,
                eventNumber: eventNumber
            )
            UIPasteboard.general.string = sharedLocation?.clipboardText(
                locationText: location.canonicalLocationText
            ) ?? location.canonicalLocationText
            copied = true
            copyFeedback += 1
        } label: {
            LucideLabel(
                resource:
                copied
                    ? LocalizedStringResource("Copied")
                    : LocalizedStringResource("Copy location"),
                icon: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(.rect)
        }
        .buttonStyle(.borderedProminent)
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
