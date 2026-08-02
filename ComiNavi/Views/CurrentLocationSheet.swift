import SwiftUI
import UIKit

struct CurrentLocationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let location: LocatedMapUser
    let onUpdateLocation: () -> Void

    @State private var copied = false
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                locationHeader
                canonicalLocation
                sensorDetails
                copyAction
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

            Label(
                location.source == .mapLongPress
                    ? "Positioned from your map press"
                    : "Positioned with Where Am I",
                systemImage: location.source == .mapLongPress ? "hand.tap.fill" : "location.fill"
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
                    Label(
                        "GPS reference · about \(Int(reading.horizontalAccuracy.rounded())) m accuracy",
                        systemImage: "location"
                    )
                }
                if let heading = location.headingDegrees {
                    Label(
                        "Compass heading · \(Int(heading.rounded()))° \(cardinalDirection(heading))",
                        systemImage: "location.north.line.fill"
                    )
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var copyAction: some View {
        Button {
            UIPasteboard.general.string = location.canonicalLocationText
            copied = true
            copyFeedback += 1
        } label: {
            Label(copied ? "Copied" : "Copy location", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 58)
                .contentShape(.rect)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Copies the Comiket-formatted location")
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
