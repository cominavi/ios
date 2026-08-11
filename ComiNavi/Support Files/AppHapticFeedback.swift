import Observation
import SwiftUI

@MainActor
@Observable
final class AppHapticFeedback {
    enum Cue: Equatable, Sendable {
        case copyConfirmation
        case completion
        case warning
        case error

        var sensoryFeedback: SensoryFeedback {
            switch self {
            case .copyConfirmation:
                .impact(weight: .light, intensity: 0.9)
            case .completion:
                .success
            case .warning:
                .warning
            case .error:
                .error
            }
        }
    }

    struct Event: Equatable, Sendable {
        let sequence: UInt64
        let cue: Cue?
    }

    private(set) var event = Event(sequence: 0, cue: nil)

    func play(_ cue: Cue) {
        event = Event(sequence: event.sequence &+ 1, cue: cue)
    }
}

extension EnvironmentValues {
    @Entry var appHapticFeedback: AppHapticFeedback? = nil
}
