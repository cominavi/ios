import Foundation
import Observation

@MainActor
protocol AppPowerStateProviding: AnyObject {
    var isLowPowerModeEnabled: Bool { get }
}

@MainActor
final class ProcessInfoPowerStateSource: AppPowerStateProviding {
    static let shared = ProcessInfoPowerStateSource()

    private init() {}

    var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

@MainActor
@Observable
final class AppPowerPolicy: NSObject {
    static let lowPowerMapFramesPerSecond = 30

    private(set) var isLowPowerModeEnabled: Bool

    @ObservationIgnored private let source: any AppPowerStateProviding
    @ObservationIgnored private let notificationCenter: NotificationCenter

    init(
        source: any AppPowerStateProviding = ProcessInfoPowerStateSource.shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.source = source
        self.notificationCenter = notificationCenter
        isLowPowerModeEnabled = source.isLowPowerModeEnabled
        super.init()

        notificationCenter.addObserver(
            self,
            selector: #selector(powerStateDidChange),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func preferredMapFramesPerSecond(maximum: Int) -> Int {
        guard isLowPowerModeEnabled else { return maximum }
        return min(Self.lowPowerMapFramesPerSecond, max(1, maximum))
    }

    var suppressesNonessentialAnimation: Bool {
        isLowPowerModeEnabled
    }

    var pausesNonessentialBackdrop: Bool {
        isLowPowerModeEnabled
    }

    @objc private func powerStateDidChange() {
        isLowPowerModeEnabled = source.isLowPowerModeEnabled
    }
}
