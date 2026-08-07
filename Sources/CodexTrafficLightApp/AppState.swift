import CodexTrafficLightCore
import Foundation

final class AppState {
    private(set) var state: TrafficLightState = .idle
    private(set) var codexState: TrafficLightState = .idle
    private(set) var claudeState: TrafficLightState = .idle
    var onStateChanged: ((TrafficLightState) -> Void)?
    var onSourceStatesChanged: ((TrafficLightState, TrafficLightState) -> Void)?
    var onMonitoringAvailabilityChanged: ((Bool) -> Void)?

    private enum Source {
        case codex
        case claude
    }

    private var codexReducer = SessionStateReducer()
    private var claudeReducer = SessionStateReducer()
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
        let claudeRuntimeRootURL: URL
        if let override = environment["CLAUDE_CODE_RUNTIME_SESSION_ROOT"], !override.isEmpty {
            claudeRuntimeRootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            claudeRuntimeRootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions", isDirectory: true)
        }

        codexMonitor = SessionLogMonitor(rootURL: codexRootURL)
        claudeMonitor = ClaudeSessionLogMonitor(
            rootURL: claudeRootURL,
            runtimeSessionsURL: claudeRuntimeRootURL
        )

        codexMonitor.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                self?.receive(events, source: .codex)
            }
        }
        claudeMonitor.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                self?.receive(events, source: .claude)
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

    func acknowledgeCodexError() {
        codexReducer.acknowledgeError()
        publishStates()
    }

    func acknowledgeClaudeError() {
        claudeReducer.acknowledgeError()
        publishStates()
    }

    private func receive(_ events: [MonitoredSessionEvent], source: Source) {
        for monitoredEvent in events {
            switch source {
            case .codex:
                codexReducer.apply(monitoredEvent.event, sessionID: monitoredEvent.sessionID)
            case .claude:
                claudeReducer.apply(monitoredEvent.event, sessionID: monitoredEvent.sessionID)
            }
        }
        publishStates()
    }

    private func publishStates() {
        let newCodexState = codexReducer.state
        let newClaudeState = claudeReducer.state
        if newCodexState != codexState || newClaudeState != claudeState {
            codexState = newCodexState
            claudeState = newClaudeState
            onSourceStatesChanged?(newCodexState, newClaudeState)
        }

        let newState = TrafficLightState.aggregate([newCodexState, newClaudeState])
        if newState != state {
            state = newState
            onStateChanged?(newState)
        }
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
