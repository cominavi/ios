import SwiftUI

struct CircleListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color(uiColor: .tertiarySystemFill)
                    : Color.clear,
                in: .rect
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
