import Foundation
import Observation

/*
PURPOSE:
Reads safety alerts from the Raspberry Pi's existing Flask web server.

IMPORTS:
Foundation handles HTTP requests and JSON data.
Observation lets SwiftUI display the connection status.

*/

@Observable @MainActor
final class PiAlertMonitor {

    var status = "Pi: Stopped"
    @ObservationIgnored var onAlert: ((SafetyAlert) -> Void)?
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?

    // REPLACE this example IP with your Raspberry Pi's Wi-Fi IP address.
    private let apiURL = URL(string: "http://192.168.68.75:5050/api/recent")!

    // These match the JSON returned by Flask's GET /api/recent endpoint.
    private struct APIResponse: Decodable {
        let data: [PiEvent]
    }

    private struct PiEvent: Decodable {
        let ts: Int
        let type: String
        let detail: String?
        let event: String?

        // Helps distinguish a newly received event from an older one.
        var key: String { "\(ts)|\(type)|\(detail ?? "")|\(event ?? "")" }
    }

    func start() {
        guard monitoringTask == nil else { return }
        status = "Pi: Connecting..."

        monitoringTask = Task {
            var seenEvents = Set<String>()
            var firstRead = true
            var lastAlertTime: [SafetyAlert: Date] = [:]

            while !Task.isCancelled {
                do {
                    // Request the recent alerts, without changing the Pi server.
                    let (data, response) = try await URLSession.shared.data(from: apiURL)
                    guard !Task.isCancelled else { break }

                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        status = "Pi: Server error"
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }

                    let events = try JSONDecoder().decode(APIResponse.self, from: data).data
                    status = "Pi: Connected and monitoring"

                    if firstRead {
                        // Don't replay alerts from before monitoring started.
                        seenEvents = Set(events.map(\.key))
                        firstRead = false
                    } else {
                        for event in events {
                            guard !Task.isCancelled else { break }
                            guard seenEvents.insert(event.key).inserted else { continue }

                            // Map the Raspberry Pi's alert names to iPhone alerts.
                            let alert: SafetyAlert
                            switch event.type.lowercased() {
                            case "drowsy": alert = .drowsy
                            case "distraction", "hypnosis": alert = .distracted
                            case "speeding": alert = .speeding
                            default: continue // Ignore anything else.
                            }

                            // Avoid restarting the conversation for repeat alerts.
                            if let previous = lastAlertTime[alert],
                               Date().timeIntervalSince(previous) < 30 {
                                continue
                            }
                            lastAlertTime[alert] = Date()

                            onAlert?(alert) // ContentView handles AI and speech.
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    status = "Pi: Connection failed"
                    print("Raspberry Pi API error:", error)
                }

                // Poll roughly once per second while Raspberry Pi mode is on.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        status = "Pi: Stopped"
    }
}
