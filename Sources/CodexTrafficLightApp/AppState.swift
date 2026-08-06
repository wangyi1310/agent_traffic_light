import CodexTrafficLightCore
import Foundation

final class AppState {
    private(set) var state: TrafficLightState = .idle
    var onStateChanged: ((TrafficLightState) -> Void)?
    var onMonitoringAvailabilityChanged: ((Bool) -> Void)?

    private var reducer = SessionStateReducer()
    private let monitor: SessionLogMonitor

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let rootURL: URL
        if let override = environment["CODEX_TRAFFIC_LIGHT_SESSION_ROOT"], !override.isEmpty {
            rootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            rootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        }
        monitor = SessionLogMonitor(rootURL: rootURL)

        monitor.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                guard let self else { return }
                for monitoredEvent in events {
                    self.reducer.apply(
                        monitoredEvent.event,
                        sessionID: monitoredEvent.sessionID
                    )
                }
                self.publishState()
            }
        }
        monitor.onAvailabilityChanged = { [weak self] available in
            DispatchQueue.main.async {
                self?.onMonitoringAvailabilityChanged?(available)
            }
        }
    }

    func start() {
        monitor.start()
    }

    func stop() {
        monitor.stop()
    }

    func acknowledgeError() {
        reducer.acknowledgeError()
        publishState()
    }

    private func publishState() {
        let newState = reducer.state
        guard newState != state else { return }
        state = newState
        onStateChanged?(newState)
    }
}
