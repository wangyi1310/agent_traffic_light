import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemController?
    private var panelController: TrafficLightPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        let panel = TrafficLightPanelController(
            onAcknowledgeCodexError: { [weak state] in
                state?.acknowledgeCodexError()
            },
            onAcknowledgeClaudeError: { [weak state] in
                state?.acknowledgeClaudeError()
            },
            onAcknowledgeCursorError: { [weak state] in
                state?.acknowledgeCursorError()
            }
        )
        let statusItem = StatusItemController { [weak panel] in
            panel?.toggle()
        }

        state.onStateChanged = { [weak statusItem] trafficLightState in
            statusItem?.update(state: trafficLightState)
        }
        state.onSourceStatesChanged = { [weak panel] codexState, claudeState, cursorState in
            panel?.update(
                codexState: codexState,
                claudeState: claudeState,
                cursorState: cursorState
            )
        }
        state.onMonitoringAvailabilityChanged = { [weak statusItem] available in
            statusItem?.updateMonitoringAvailability(available)
        }
        panel.onVisibilityChanged = { [weak statusItem] visible in
            statusItem?.updatePanelVisibility(visible)
        }

        appState = state
        panelController = panel
        statusItemController = statusItem

        panel.show()
        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
    }
}
