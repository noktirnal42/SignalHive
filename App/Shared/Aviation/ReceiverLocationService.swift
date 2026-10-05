import CoreLocation
import Foundation
import SignalHiveCore

@MainActor
final class ReceiverLocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onLocation: (GeoCoordinate) -> Void
    private let onError: (String) -> Void

    init(onLocation: @escaping (GeoCoordinate) -> Void, onError: @escaping (String) -> Void) {
        self.onLocation = onLocation
        self.onError = onError
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            onError("Location permission is off. Enable it in System Settings, or enter the antenna position manually.")
        @unknown default:
            onError("Location Services returned an unknown authorization state.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.requestLocation()
            case .denied, .restricted:
                onError("Location permission is off. Enable it in System Settings, or enter the antenna position manually.")
            case .notDetermined:
                break
            @unknown default:
                onError("Location Services returned an unknown authorization state.")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        Task { @MainActor in
            let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
            if coordinate.isValid {
                onLocation(coordinate)
            } else {
                onError("Location Services returned an invalid coordinate.")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            onError(message)
        }
    }
}
