import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class WhereAmILocationService: NSObject {
    enum LocationState: Equatable {
        case waiting
        case live(WhereAmILocationReading)
        case cached(WhereAmILocationReading)
        case unavailable
    }

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var latestReading: WhereAmILocationReading?
    private(set) var headingDegrees: Double?
    private(set) var headingAccuracy: Double?
    private(set) var errorMessage: String?
    private(set) var isUpdating = false

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private let simulated: Bool

    init(
        simulatedReading: WhereAmILocationReading? = nil,
        simulatedHeading: Double? = nil
    ) {
        manager = CLLocationManager()
        simulated = simulatedReading != nil || simulatedHeading != nil
        authorizationStatus = simulated ? .authorizedWhenInUse : manager.authorizationStatus
        latestReading = simulatedReading
        headingDegrees = simulatedHeading
        headingAccuracy = simulatedHeading == nil ? nil : 4
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 4
        manager.headingFilter = 2
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start() {
        errorMessage = nil
        if simulated {
            isUpdating = true
            return
        }

        if let cached = manager.location, cached.horizontalAccuracy >= 0 {
            latestReading = Self.reading(from: cached)
        }

        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        case .denied, .restricted:
            isUpdating = false
        @unknown default:
            isUpdating = false
        }
    }

    func stop() {
        guard !simulated else {
            isUpdating = false
            return
        }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        isUpdating = false
    }

    func locationState(at date: Date = .now) -> LocationState {
        guard let latestReading else {
            return authorizationStatus == .denied || authorizationStatus == .restricted
                ? .unavailable
                : .waiting
        }
        return isUpdating && latestReading.isLive(at: date)
            ? .live(latestReading)
            : .cached(latestReading)
    }

    private func beginUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            refreshHeadingOrientation()
            manager.startUpdatingHeading()
        }
    }

    private func acceptAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        case .denied, .restricted:
            stop()
        case .notDetermined:
            break
        @unknown default:
            stop()
        }
    }

    private func acceptLocation(_ reading: WhereAmILocationReading) {
        latestReading = reading
        errorMessage = nil
    }

    private func acceptHeading(degrees: Double, accuracy: Double) {
        refreshHeadingOrientation()
        headingDegrees = degrees
        headingAccuracy = accuracy
    }

    private func acceptError(code: CLError.Code) {
        guard code != .locationUnknown else { return }
        errorMessage = String(localized: "Location is temporarily unavailable. Choose your venue manually.")
    }

    private func refreshHeadingOrientation() {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown: manager.headingOrientation = .portraitUpsideDown
        case .landscapeLeft: manager.headingOrientation = .landscapeLeft
        case .landscapeRight: manager.headingOrientation = .landscapeRight
        default: manager.headingOrientation = .portrait
        }
    }

    nonisolated private static func reading(from location: CLLocation) -> WhereAmILocationReading {
        WhereAmILocationReading(
            coordinate: GeographicCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }
}

extension WhereAmILocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.acceptAuthorization(status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        let reading = Self.reading(from: location)
        Task { @MainActor [weak self] in
            self?.acceptLocation(reading)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor [weak self] in
            self?.acceptHeading(degrees: degrees, accuracy: accuracy)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard let locationError = error as? CLError else { return }
        let code = locationError.code
        Task { @MainActor [weak self] in
            self?.acceptError(code: code)
        }
    }
}
