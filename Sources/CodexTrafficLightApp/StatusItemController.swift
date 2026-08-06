import AppKit
import CodexTrafficLightCore

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 42)
    private let trafficLightView = TrafficLightView(orientation: .horizontal)
    private let menu = NSMenu()
    private let toggleItem = NSMenuItem()
    private let unavailableItem = NSMenuItem(title: "监控不可用", action: nil, keyEquivalent: "")
    private let onTogglePanel: () -> Void

    init(onTogglePanel: @escaping () -> Void) {
        self.onTogglePanel = onTogglePanel
        super.init()

        if let button = statusItem.button {
            trafficLightView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(trafficLightView)
            NSLayoutConstraint.activate([
                trafficLightView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                trafficLightView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                trafficLightView.topAnchor.constraint(equalTo: button.topAnchor),
                trafficLightView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.toolTip = "Codex：空闲"
        }

        toggleItem.target = self
        toggleItem.action = #selector(togglePanel)
        menu.addItem(toggleItem)
        unavailableItem.isEnabled = false
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updatePanelVisibility(true)
    }

    func update(state: TrafficLightState) {
        trafficLightView.state = state
        statusItem.button?.toolTip = "Codex：\(stateTitle(state))"
    }

    func updatePanelVisibility(_ visible: Bool) {
        toggleItem.title = visible ? "隐藏交通灯" : "显示交通灯"
    }

    func updateMonitoringAvailability(_ available: Bool) {
        if available {
            if menu.items.contains(unavailableItem) {
                menu.removeItem(unavailableItem)
            }
        } else if !menu.items.contains(unavailableItem) {
            menu.insertItem(unavailableItem, at: 1)
        }
    }

    @objc private func togglePanel() {
        onTogglePanel()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func stateTitle(_ state: TrafficLightState) -> String {
        switch state {
        case .idle: return "空闲"
        case .thinking: return "思考中"
        case .executing: return "执行中"
        case .completed: return "已完成"
        case .error: return "出错"
        }
    }
}
