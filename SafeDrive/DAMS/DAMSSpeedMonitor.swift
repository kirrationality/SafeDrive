
import Foundation
import CoreLocation

// Estimates vehicle speed using iPhone location updates.
// It does not know the posted speed limit for the current road.
final class DAMSSpeedMonitor: NSObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()

    var onAlert: ((SafetyAlert) -> Void)?
    var onStatus: ((String) -> Void)?

    private let thresholdMilesPerHour: Double = 70 // update to desired threshold

    // Reject readings whose reported speed accuracy is poor.
    private let maximumSpeedAccuracyMetersPerSecond: Double = 3.0

    // Avoid repeating the same high-speed alert continuously.
    private let alertCooldown: TimeInterval = 30
    private var lastAlertDate: Date?
    private var isMonitoring = false
    

    override init() {
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
    }

    func start() {
        isMonitoring = true
        
        switch locationManager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.startUpdatingLocation()
                reportStatus("GPS speed monitoring started")

            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()

            case .denied, .restricted:
                reportStatus("ERROR: Allow location access in iPhone Settings")

            @unknown default:
                reportStatus("ERROR: Unknown location permission status")
        }
    }

    func stop() {
        isMonitoring = false
        locationManager.stopUpdatingLocation()
        reportStatus("GPS monitoring stopped")
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        guard isMonitoring else { return }
        
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            reportStatus("GPS speed monitoring started")

        case .denied, .restricted:
            reportStatus("ERROR: Location permission denied")

        case .notDetermined:
            break

        @unknown default:
            reportStatus("ERROR: Unknown location permission status")
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }

        // A negative speed means Core Location has no valid speed estimate.
        // Reject readings with poor reported speed accuracy as well.
        guard location.speed >= 0,
              location.speedAccuracy >= 0,
              location.speedAccuracy <= maximumSpeedAccuracyMetersPerSecond
        else {
            return
        }

        let speedMilesPerHour = location.speed * 2.236936

        guard speedMilesPerHour > thresholdMilesPerHour else {
            return
        }

        if let lastAlertDate,
           Date().timeIntervalSince(lastAlertDate) < alertCooldown {
            return
        }

        self.lastAlertDate = Date()

        DispatchQueue.main.async { [weak self] in
            self?.onAlert?(.speeding)
        }
    }

    // Report GPS failures so ContentView can recognize and display them as errors.
    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        reportStatus("Error: GPS update failed: \(error.localizedDescription)")
    }

    private func reportStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }
}
