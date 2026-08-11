import AppKit
import CodexTrafficLightCore

final class TrafficLightPanelController: NSObject {
    var onVisibilityChanged: ((Bool) -> Void)?

    private let panel: NSPanel
    private let codexTrafficLightView: TrafficLightView
    private let claudeTrafficLightView: TrafficLightView
    private let cursorTrafficLightView: TrafficLightView
    private let defaultsKey = "trafficLightPanelOrigin"

    var isVisible: Bool { panel.isVisible }

    init(
        onAcknowledgeCodexError: @escaping () -> Void,
        onAcknowledgeClaudeError: @escaping () -> Void,
        onAcknowledgeCursorError: @escaping () -> Void
    ) {
        let groupSize = NSSize(width: 39, height: 94)
        let gap: CGFloat = 4
        let size = NSSize(width: groupSize.width * 3 + gap * 2, height: groupSize.height)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        codexTrafficLightView = TrafficLightView(
            frame: NSRect(origin: .zero, size: groupSize),
            orientation: .vertical,
            sourceLabel: "Codex"
        )
        claudeTrafficLightView = TrafficLightView(
            frame: NSRect(
                origin: NSPoint(x: groupSize.width + gap, y: 0),
                size: groupSize
            ),
            orientation: .vertical,
            sourceLabel: "Claude"
        )
        cursorTrafficLightView = TrafficLightView(
            frame: NSRect(
                origin: NSPoint(x: (groupSize.width + gap) * 2, y: 0),
                size: groupSize
            ),
            orientation: .vertical,
            sourceLabel: "Cursor"
        )
        super.init()

        codexTrafficLightView.onAcknowledgeError = onAcknowledgeCodexError
        claudeTrafficLightView.onAcknowledgeError = onAcknowledgeClaudeError
        cursorTrafficLightView.onAcknowledgeError = onAcknowledgeCursorError
        let contentView = NSView(frame: NSRect(origin: .zero, size: size))
        contentView.addSubview(codexTrafficLightView)
        contentView.addSubview(claudeTrafficLightView)
        contentView.addSubview(cursorTrafficLightView)
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        restorePosition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(
        codexState: TrafficLightState,
        claudeState: TrafficLightState,
        cursorState: TrafficLightState
    ) {
        codexTrafficLightView.state = codexState
        claudeTrafficLightView.state = claudeState
        cursorTrafficLightView.state = cursorState
    }

    func show() {
        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
    }

    func hide() {
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    @objc private func panelDidMove() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: defaultsKey)
    }

    private func restorePosition() {
        let origin: NSPoint
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            origin = NSPointFromString(stored)
        } else if let screen = NSScreen.main {
            origin = NSPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - 24,
                y: screen.visibleFrame.maxY - panel.frame.height - 24
            )
        } else {
            origin = NSPoint(x: 80, y: 80)
        }

        var frame = NSRect(origin: origin, size: panel.frame.size)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
            frame.origin.x = min(
                max(frame.origin.x, screen.visibleFrame.minX),
                screen.visibleFrame.maxX - frame.width
            )
            frame.origin.y = min(
                max(frame.origin.y, screen.visibleFrame.minY),
                screen.visibleFrame.maxY - frame.height
            )
        } else if let screen = NSScreen.main {
            frame.origin = NSPoint(
                x: screen.visibleFrame.maxX - frame.width - 24,
                y: screen.visibleFrame.maxY - frame.height - 24
            )
        }
        panel.setFrame(frame, display: false)
    }
}
