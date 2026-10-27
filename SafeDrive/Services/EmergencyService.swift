/*
PURPOSE:
Provides emergency services for SafeDrive:
GPS tracking, street-address lookup, calling, and text-message preparation.

IMPORTS:
CoreLocation reads GPS data. MapKit converts coordinates into a street address.
SwiftUI and Combine publish location updates to the screen.
Foundation provides dates and formatting. MessageUI and UIKit support texting.

*/

import Foundation
import CoreLocation
import MapKit
import SwiftUI
import Combine
import MessageUI
import UIKit

@MainActor
final class EmergencyService: NSObject, ObservableObject,
    CLLocationManagerDelegate {

    // Configure the emergency number here - calls/text to this #
    static let emergencyPhoneNumber = "" // upadte to 911 when not testing
    static let driverName = "Jane Doe"

    private let locationManager = CLLocationManager()
    private var isActive = false

    // Retain the current address request so it can be cancelled.
    private var activeGeocodingRequest: MKReverseGeocodingRequest?
    private var geocodingTask: Task<Void, Never>?

    // Avoid repeatedly looking up an address while the car is moving.
    private var lastAddressRequestDate = Date.distantPast

    @Published private(set) var address = "Waiting for location..."
    @Published private(set) var coordinates = "Not available yet"
    @Published private(set) var direction = "Direction not available yet"
    @Published private(set) var statusMessage = "Waiting for GPS..."
    @Published private(set) var hasLocation = false
    @Published private(set) var addressLocationTimestamp: Date?
    
    // The view uses this URL to open the iPhone calling interface.
    var callURL: URL? {
        URL(string: "tel:\(Self.emergencyPhoneNumber)")
    }

    // Combines the latest available location details into a text draft.

    var locationDetails: String {
        let addressFixTime = addressLocationTimestamp?
            .formatted(date: .abbreviated, time: .shortened)
            ?? "Not available"

        if hasLocation {
            return """
            I am: \(Self.driverName)
            GPS Coordinates: \(coordinates)
            Driving: \(direction)
            Address: \(address)
            Address based on GPS fix at: \(addressFixTime)
            """
        }
        
        return """
        I am: \(Self.driverName)
        CURRENT GPS LOCATION UNAVAILABLE.
        Last Known address: \(address)
        Address based on GPS fix at: \(addressFixTime)
        """
    }

  
    var emergencyMessage: String {
        """
        EMERGENCY. Need assistance. 

        \(locationDetails)
        """
    }

    override init() {
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 10
        locationManager.activityType = .automotiveNavigation
    }

    // Start GPS updates when the emergency screen appears.

    func start() {
        guard !isActive else { return }

        isActive = true
        lastAddressRequestDate = .distantPast

        // Start a new session without presenting the previous session's
        // location as current. A valid location update will populate these.
        hasLocation = false
        address = "Address lookup pending..."
        coordinates = "Waiting for GPS..."
        direction = "Direction not available yet"
        statusMessage = "Waiting for GPS..."
        addressLocationTimestamp = nil

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()

            if let location = locationManager.location {
                updateLocation(location)
            }

        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()

        case .denied, .restricted:
            statusMessage =
                "Location access is off. Tell the dispatcher your nearest road, exit, or landmark."

        @unknown default:
            statusMessage = "Unable to check location permission."
        }
    }

    // Stop GPS and cancel any unfinished address lookup.
    func stop() {
        isActive = false
        locationManager.stopUpdatingLocation()

        geocodingTask?.cancel()
        activeGeocodingRequest?.cancel()

        geocodingTask = nil
        activeGeocodingRequest = nil
        lastAddressRequestDate = .distantPast
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        guard isActive else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()

            if let location = manager.location {
                updateLocation(location)
            }

        case .denied, .restricted:
            statusMessage =
                "Location access is off. Use the nearest road, exit, or landmark."

        case .notDetermined:
            break

        @unknown default:
            statusMessage = "Unable to check location permission."
        }
    }

    // CoreLocation calls this whenever new GPS locations arrive.
    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard isActive, let location = locations.last else {
            return
        }

        updateLocation(location)
    }

    private func updateLocation(_ location: CLLocation) {
        guard isActive else { return }

        // Ignore invalid GPS accuracy and locations older than 60 seconds.
        let age = Date().timeIntervalSince(location.timestamp)

        guard location.horizontalAccuracy >= 0,
              age >= 0,
              age < 60
        else {
            return
        }

        hasLocation = true

        coordinates = String(
            format: " %.5f, %.5f",
            locale: Locale(identifier: "en_US_POSIX"),
            location.coordinate.latitude,
            location.coordinate.longitude
        )

        // GPS course estimates direction of travel while the vehicle moves.
        if location.speed > 1.5, location.course >= 0 {
            direction =
                "\(compassDirection(location.course))"
        //} else if location.speed >= 0 && location.speed <= 1.5 {
        //    direction = "Vehicle stopped"
        } else {
            direction = "Vehicle stopped" // "Direction not available"
        }

        if location.horizontalAccuracy <= 35 {
            statusMessage =
                "GPS accuracy: Good"
        } else if location.horizontalAccuracy <= 100 {
            statusMessage =
                "GPS accuracy: Approximate"
        } else {
            statusMessage =
                "GPS accuracy: Low"
        }

        updateAddressIfNeeded(for: location)
    }

    // Reverse geocoding converts GPS coordinates into a readable address.
    // This request is attempted at most once per minute.
    private func updateAddressIfNeeded(for location: CLLocation) {
        guard Date().timeIntervalSince(lastAddressRequestDate) >= 60 else {
            return
        }

        lastAddressRequestDate = Date()

        geocodingTask?.cancel()
        activeGeocodingRequest?.cancel()

        guard let request = MKReverseGeocodingRequest(location: location) else {
            if addressLocationTimestamp == nil {
                address = "Street address unavailable"
            }
            return
        }

        activeGeocodingRequest = request

        geocodingTask = Task { [weak self] in
            do {
                let mapItems = try await request.mapItems

                // Ignore results if the request was cancelled or replaced.
                guard !Task.isCancelled,
                      let self,
                      self.isActive,
                      self.activeGeocodingRequest === request
                else {
                    return
                }

                if let formattedAddress = mapItems.first?
                    .addressRepresentations?
                    .fullAddress(
                        includingRegion: false,
                        singleLine: true
                    ),
                   !formattedAddress.isEmpty {
                    self.address = formattedAddress
                    self.addressLocationTimestamp = location.timestamp

                } else if self.addressLocationTimestamp == nil {
                    self.address =
                        "Street address unavailable. Use GPS coordinates."
                }

                self.activeGeocodingRequest = nil
                self.geocodingTask = nil

            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.isActive,
                      self.activeGeocodingRequest === request
                else {
                    return
                }

                if self.addressLocationTimestamp == nil {
                    self.address = "Street address unavailable. Use GPS coordinates."
                }

                self.activeGeocodingRequest = nil
                self.geocodingTask = nil
            }
        }
    }

    // Converts a GPS course in degrees into a compass direction.
    private func compassDirection(_ course: CLLocationDirection) -> String {
        let directions = [
            "north", "northeast", "east", "southeast",
            "south", "southwest", "west", "northwest"
        ]

        let heading = course.truncatingRemainder(dividingBy: 360)
        let index = Int((heading + 22.5) / 45) % directions.count

        return directions[index]
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard isActive else { return }

        statusMessage =
            "GPS update failed. Tell the dispatcher your nearest road, exit, or landmark."
    }
}

// Displays Apple's message editor. The user must press Send.
struct EmergencyTextComposer: UIViewControllerRepresentable {

    @Binding var isPresented: Bool

    let recipient: String
    let message: String

    func makeUIViewController(
        context: Context
    ) -> MFMessageComposeViewController {

        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = [recipient]
        controller.body = message

        return controller
    }

    func updateUIViewController(
        _ controller: MFMessageComposeViewController,
        context: Context
    ) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator:
        NSObject, MFMessageComposeViewControllerDelegate {

        private var parent: EmergencyTextComposer

        init(parent: EmergencyTextComposer) {
            self.parent = parent
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true) {
                self.parent.isPresented = false
            }
        }
    }
}
