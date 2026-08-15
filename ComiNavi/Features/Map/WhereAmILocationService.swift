import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class WhereAmILocationService: NSObject {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var latestReading: WhereAmILocationReading?
    private(set) var headingDegrees: Double?
    private(set) var isUpdatingLocation = false
    private(set) var isUpdatingHeading = false

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private let simulated: Bool
    @ObservationIgnored private var wantsLocationUpdates = false
    @ObservationIgnored private var wantsHeadingUpdates = false

    init(
        simulatedReading: WhereAmILocationReading? = nil,
        simulatedHeading: Double? = nil,
        simulatedAuthorizationStatus: CLAuthorizationStatus? = nil
    ) {
        manager = CLLocationManager()
        simulated =
            simulatedReading != nil || simulatedHeading != nil
            || simulatedAuthorizationStatus != nil
        authorizationStatus =
            simulatedAuthorizationStatus
            ?? (simulated ? .authorizedWhenInUse : manager.authorizationStatus)
        latestReading = simulatedReading
        headingDegrees = simulatedHeading
        super.init()

        if !simulated {
            manager.delegate = self
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 4
        manager.headingFilter = 2
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start(
        locationUpdates: Bool,
        headingUpdates: Bool
    ) {
        wantsLocationUpdates = locationUpdates
        wantsHeadingUpdates = headingUpdates

        if simulated {
            isUpdatingLocation =
                locationUpdates
                && (authorizationStatus == .authorizedAlways
                    || authorizationStatus == .authorizedWhenInUse)
            isUpdatingHeading = headingUpdates
            return
        }

        authorizationStatus = manager.authorizationStatus

        if !locationUpdates {
            stopLocationUpdates()
        } else if let cached = manager.location, cached.horizontalAccuracy >= 0 {
            latestReading = Self.reading(from: cached)
        }

        if headingUpdates {
            beginHeadingUpdates()
        } else {
            stopHeadingUpdates()
        }

        if locationUpdates {
            switch authorizationStatus {
            case .notDetermined:
                stopLocationUpdates()
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                beginLocationUpdates()
            case .denied, .restricted:
                stopLocationUpdates()
            @unknown default:
                stopLocationUpdates()
            }
        }
    }

    func stop() {
        wantsLocationUpdates = false
        wantsHeadingUpdates = false
        guard !simulated else {
            isUpdatingLocation = false
            isUpdatingHeading = false
            return
        }
        stopLocationUpdates()
        stopHeadingUpdates()
    }

    private func beginLocationUpdates() {
        guard wantsLocationUpdates, !isUpdatingLocation else { return }
        isUpdatingLocation = true
        manager.startUpdatingLocation()
    }

    private func stopLocationUpdates() {
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
    }

    private func beginHeadingUpdates() {
        guard wantsHeadingUpdates, CLLocationManager.headingAvailable() else {
            isUpdatingHeading = false
            return
        }
        refreshHeadingOrientation()
        guard !isUpdatingHeading else { return }
        isUpdatingHeading = true
        manager.startUpdatingHeading()
    }

    private func stopHeadingUpdates() {
        manager.stopUpdatingHeading()
        isUpdatingHeading = false
    }

    private func acceptAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        case .denied, .restricted:
            stopLocationUpdates()
        case .notDetermined:
            stopLocationUpdates()
        @unknown default:
            stopLocationUpdates()
        }
    }

    private func acceptLocation(_ reading: WhereAmILocationReading) {
        guard wantsLocationUpdates, isUpdatingLocation else { return }
        latestReading = reading
    }

    private func acceptHeading(degrees: Double) {
        guard wantsHeadingUpdates, isUpdatingHeading else { return }
        guard !refreshHeadingOrientation() else { return }
        headingDegrees = degrees
    }

    @discardableResult
    private func refreshHeadingOrientation() -> Bool {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let interfaceOrientation =
            windowScenes.first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
            ?? windowScenes.first(where: { $0.activationState == .foregroundInactive })?
            .interfaceOrientation

        let resolvedOrientation: CLDeviceOrientation?
        if let interfaceOrientation {
            resolvedOrientation = switch interfaceOrientation {
            case .portrait: .portrait
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            case .unknown: nil
            @unknown default: nil
            }
        } else {
            resolvedOrientation = nil
        }

        let fallbackOrientation: CLDeviceOrientation? = switch UIDevice.current.orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown, .faceUp, .faceDown: nil
        @unknown default: nil
        }
        guard let orientation = resolvedOrientation ?? fallbackOrientation,
            manager.headingOrientation != orientation
        else { return false }
        manager.headingOrientation = orientation
        return true
    }

    #if DEBUG
        func updateSimulation(
            reading: WhereAmILocationReading? = nil,
            headingDegrees: Double? = nil
        ) {
            guard simulated else { return }
            if let reading, wantsLocationUpdates, isUpdatingLocation {
                latestReading = reading
            }
            if let headingDegrees, wantsHeadingUpdates, isUpdatingHeading {
                self.headingDegrees = headingDegrees
            }
        }
    #endif

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
        Task { @MainActor [weak self] in
            self?.acceptHeading(degrees: degrees)
        }
    }
}
