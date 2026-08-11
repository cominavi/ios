import Foundation
import Network

enum SharedPlanNetworkReachability {
    /// Emits the current state and subsequent path changes. The stream owns
    /// and cancels its monitor with the SwiftUI task lifecycle.
    static func updates() -> AsyncStream<Bool> {
        let box = MonitorBox()
        return AsyncStream { continuation in
            box.monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            box.monitor.start(queue: box.queue)
            continuation.onTermination = { @Sendable _ in
                box.monitor.cancel()
            }
        }
    }

    private final class MonitorBox: @unchecked Sendable {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "net.cominavi.shared-plans.reachability")
    }
}
