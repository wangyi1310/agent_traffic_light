import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemController?
    private var panelController: TrafficLightPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        let panel = TrafficLightPanelController { [weak state] in
            state?.acknowledgeError()
        }
        let statusItem = StatusItemController { [weak panel] in
            panel?.toggle()
        }

        state.onStateChanged = { [weak panel, weak statusItem] trafficLightState in
            panel?.update(state: trafficLightState)
            statusItem?.update(state: trafficLightState)
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
