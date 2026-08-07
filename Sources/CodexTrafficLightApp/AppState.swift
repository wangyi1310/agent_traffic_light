import CodexTrafficLightCore
import Foundation

final class AppState {
    private(set) var state: TrafficLightState = .idle
    var onStateChanged: ((TrafficLightState) -> Void)?
    var onMonitoringAvailabilityChanged: ((Bool) -> Void)?

    private var reducer = SessionStateReducer()
    private let codexMonitor: SessionLogMonitor
    private let claudeMonitor: ClaudeSessionLogMonitor
    private var codexMonitorAvailable = false
    private var claudeMonitorAvailable = false
    private var publishedAvailability: Bool?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let codexRootURL: URL
        if let override = environment["CODEX_TRAFFIC_LIGHT_SESSION_ROOT"], !override.isEmpty {
            codexRootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            codexRootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        }
        let claudeRootURL: URL
        if let override = environment["CLAUDE_CODE_SESSION_ROOT"], !override.isEmpty {
            claudeRootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            claudeRootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        }

        codexMonitor = SessionLogMonitor(rootURL: codexRootURL)
        claudeMonitor = ClaudeSessionLogMonitor(rootURL: claudeRootURL)

        codexMonitor.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                self?.receive(events, source: "codex")
            }
        }
        claudeMonitor.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                self?.receive(events, source: "claude")
            }
        }
        codexMonitor.onAvailabilityChanged = { [weak self] available in
            DispatchQueue.main.async {
                self?.updateAvailability(codex: available)
            }
        }
        claudeMonitor.onAvailabilityChanged = { [weak self] available in
            DispatchQueue.main.async {
                self?.updateAvailability(claude: available)
            }
        }
    }

    func start() {
        codexMonitor.start()
        claudeMonitor.start()
    }

    func stop() {
        codexMonitor.stop()
        claudeMonitor.stop()
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

    private func receive(_ events: [MonitoredSessionEvent], source: String) {
        for monitoredEvent in events {
            reducer.apply(
                monitoredEvent.event,
                sessionID: "\(source):\(monitoredEvent.sessionID)"
            )
        }
        publishState()
    }

    private func updateAvailability(codex: Bool? = nil, claude: Bool? = nil) {
        if let codex {
            codexMonitorAvailable = codex
        }
        if let claude {
            claudeMonitorAvailable = claude
        }

        let available = codexMonitorAvailable || claudeMonitorAvailable
        guard available != publishedAvailability else { return }
        publishedAvailability = available
        onMonitoringAvailabilityChanged?(available)
    }
}
