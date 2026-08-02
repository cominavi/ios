import SwiftUI

struct BigSightVenueBadge: View {
    let icon: BigSightMapIcon

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            if let badge = icon.venueBadge {
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill(.white)
                        .overlay {
                            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                                .stroke(.black.opacity(0.16), lineWidth: max(0.5, side * 0.018))
                        }

                    RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                        .fill(color(for: badge))
                        .padding(side * 0.075)

                    VStack(spacing: -side * 0.035) {
                        Text(badge.japanese)
                            .font(.system(size: side * 0.43, weight: .heavy, design: .rounded))

                        Text(badge.english)
                            .font(.system(size: side * 0.14, weight: .black, design: .rounded))
                            .tracking(side * 0.006)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(side * 0.12)
                }
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func color(for badge: BigSightMapIcon.VenueBadge) -> Color {
        Color(
            red: badge.color.red,
            green: badge.color.green,
            blue: badge.color.blue
        )
    }
}
