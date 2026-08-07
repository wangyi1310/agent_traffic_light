import AppKit
import CodexTrafficLightCore

final class TrafficLightView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    var state: TrafficLightState = .idle {
        didSet {
            guard oldValue != state else { return }
            restartAnimation()
        }
    }

    var onAcknowledgeError: (() -> Void)?
    let orientation: Orientation

    private var phase = 0
    private var animationTimer: Timer?

    init(frame frameRect: NSRect = .zero, orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        animationTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if orientation == .vertical {
            drawHousing()
        }

        let litLamps = TrafficLightAnimation.litLamps(for: state, phase: phase)
        for lamp in [TrafficLightLamp.red, .yellow, .green] {
            drawLamp(lamp, in: lampRects()[lamp] ?? .zero, isLit: litLamps.contains(lamp))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        orientation == .horizontal ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if state == .error, lampRects()[.red]?.contains(point) == true {
            onAcknowledgeError?()
            return
        }
        super.mouseDown(with: event)
    }

    private func restartAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        phase = state == .executing || state == .error ? 1 : 0
        needsDisplay = true

        guard state == .thinking || state == .executing || state == .error else { return }
        let timer = Timer(timeInterval: 0.36, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 1
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func drawHousing() {
        let housingRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: housingRect, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.09, alpha: 0.96).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.35, alpha: 0.55).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawLamp(_ lamp: TrafficLightLamp, in rect: NSRect, isLit: Bool) {
        let baseColor: NSColor
        switch lamp {
        case .red: baseColor = .systemRed
        case .yellow: baseColor = .systemYellow
        case .green: baseColor = .systemGreen
        }

        NSGraphicsContext.saveGraphicsState()
        if isLit {
            let shadow = NSShadow()
            shadow.shadowColor = baseColor.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = orientation == .vertical ? 7 : 5
            shadow.shadowOffset = .zero
            shadow.set()
        }

        let path = NSBezierPath(ovalIn: rect)
        (isLit ? baseColor : baseColor.withAlphaComponent(0.18)).setFill()
        path.fill()
        NSColor(calibratedWhite: isLit ? 1 : 0.45, alpha: isLit ? 0.35 : 0.18).setStroke()
        path.lineWidth = orientation == .vertical ? 0.5 : 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func lampRects() -> [TrafficLightLamp: NSRect] {
        switch orientation {
        case .horizontal:
            let diameter = min(10, max(4, bounds.height - 8))
            let gap: CGFloat = 3
            let totalWidth = diameter * 3 + gap * 2
            let startX = (bounds.width - totalWidth) / 2
            let y = (bounds.height - diameter) / 2
            return [
                .red: NSRect(x: startX, y: y, width: diameter, height: diameter),
                .yellow: NSRect(x: startX + diameter + gap, y: y, width: diameter, height: diameter),
                .green: NSRect(x: startX + (diameter + gap) * 2, y: y, width: diameter, height: diameter),
            ]
        case .vertical:
            let gap: CGFloat = 5
            let diameter = min(bounds.width - 12, (bounds.height - 16 - gap * 2) / 3)
            let x = (bounds.width - diameter) / 2
            let totalHeight = diameter * 3 + gap * 2
            let startY = (bounds.height - totalHeight) / 2
            return [
                .red: NSRect(x: x, y: startY, width: diameter, height: diameter),
                .yellow: NSRect(x: x, y: startY + diameter + gap, width: diameter, height: diameter),
                .green: NSRect(x: x, y: startY + (diameter + gap) * 2, width: diameter, height: diameter),
            ]
        }
    }
}
