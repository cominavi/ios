import SwiftUI

enum SharedPlanPurchaseItemPreset: String, CaseIterable, Identifiable, Sendable {
    case newReleaseSet
    case newReleaseOnly
    case acrylicKeychain
    case acrylicStand
    case stickerSet

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .newReleaseSet:
            "New-release set"
        case .newReleaseOnly:
            "New release only"
        case .acrylicKeychain:
            "Acrylic keychain"
        case .acrylicStand:
            "Acrylic stand"
        case .stickerSet:
            "Sticker set"
        }
    }

    var itemName: String {
        String(localized: title)
    }
}

struct SharedPlanPurchaseItemPresetRow: View {
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SharedPlanPurchaseItemPreset.allCases) { preset in
                    Button {
                        onSelect(preset.itemName)
                    } label: {
                        Text(preset.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("shared-plan-purchase-preset-\(preset.rawValue)")
                    .accessibilityHint("Fills the item name field.")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Common purchase items")
    }
}
