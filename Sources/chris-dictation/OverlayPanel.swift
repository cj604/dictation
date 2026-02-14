import AppKit
import QuartzCore

final class OverlayPanel: NSPanel {
    private let waveformView = WaveformView()
    private let checkmarkView = CheckmarkView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureWindow()
        buildUI()
    }

    private func configureWindow() {
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    private func buildUI() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderColor = NSColor(white: 0.25, alpha: 0.6).cgColor
        container.layer?.borderWidth = 0.5

        // Shadow on the container layer for glow
        container.layer?.shadowColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        container.layer?.shadowOffset = .zero
        container.layer?.shadowRadius = 12
        container.layer?.shadowOpacity = 0.4

        contentView = container

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(waveformView)

        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkView.isHidden = true
        container.addSubview(checkmarkView)

        NSLayoutConstraint.activate([
            waveformView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            waveformView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            waveformView.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            waveformView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            waveformView.heightAnchor.constraint(equalToConstant: 14),

            checkmarkView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            checkmarkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 14),
            checkmarkView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func showRecording(targetApp: NSRunningApplication?) {
        let panelWidth: CGFloat = 64
        let panelHeight: CGFloat = 24
        let origin = Self.overlayOrigin(panelWidth: panelWidth, panelHeight: panelHeight, targetApp: targetApp)
        setFrame(NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight), display: true)

        statusLabel.isHidden = true
        waveformView.isHidden = false

        alphaValue = 0
        contentView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.contentView?.layer?.transform = CATransform3DIdentity
        }

        waveformView.startAnimating()
    }

    /// 1. Text caret position (editors, browsers). 2. Top-left of window (terminals). 3. Mouse.
    private static func overlayOrigin(panelWidth: CGFloat, panelHeight: CGFloat, targetApp: NSRunningApplication?) -> NSPoint {
        guard AXIsProcessTrusted() else {
            return mouseOrigin(panelWidth: panelWidth, panelHeight: panelHeight)
        }

        // 1. Try caret position via the target app's focused UI element
        if let app = targetApp {
            if let point = caretPositionFromApp(app, panelWidth: panelWidth, panelHeight: panelHeight) {
                return point
            }
        }

        // 2. Bottom-left of target app's focused window
        if let app = targetApp {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
               let window = windowRef {
                let winElement = window as! AXUIElement
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(winElement, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(winElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let posVal = posRef, let sizeVal = sizeRef {
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
                    if size.width > 0, size.height > 0, let screen = NSScreen.main {
                        let screenH = screen.frame.height
                        // Bottom-left: window bottom edge + small margin
                        let cocoaY = screenH - (pos.y + size.height) + 12
                        let x = pos.x + 12
                        return clampToScreen(x: x, y: cocoaY, width: panelWidth, height: panelHeight)
                    }
                }
            }
        }

        // 3. Mouse
        return mouseOrigin(panelWidth: panelWidth, panelHeight: panelHeight)
    }

    /// Try multiple strategies to find the text caret position.
    private static func caretPositionFromApp(_ app: NSRunningApplication, panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return nil
        }
        let element = focused as! AXUIElement

        // Strategy A: bounds for selected text range (native text fields)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeVal = rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeVal, &boundsRef) == .success,
               let boundsVal = boundsRef {
                var rect = CGRect.zero
                if AXValueGetValue(boundsVal as! AXValue, .cgRect, &rect),
                   rect.height > 0 {
                    if let screen = NSScreen.main {
                        let screenH = screen.frame.height
                        let cocoaY = screenH - rect.origin.y + 8
                        return clampToScreen(x: rect.origin.x, y: cocoaY, width: panelWidth, height: panelHeight)
                    }
                }
            }
        }

        // Strategy B: focused element's own position (Electron apps, web views)
        // The focused element might be the text area itself — position above it
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let posVal = posRef, let sizeVal = sizeRef {
            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            // Only use if the element is reasonably sized (not the whole window)
            if size.width > 0, size.width < 800, size.height > 0, size.height < 200 {
                if let screen = NSScreen.main {
                    let screenH = screen.frame.height
                    let cocoaY = screenH - pos.y + 8
                    return clampToScreen(x: pos.x, y: cocoaY, width: panelWidth, height: panelHeight)
                }
            }
        }

        return nil
    }

    private static func mouseOrigin(panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let x = mouse.x - panelWidth / 2
        let y = mouse.y + 20
        return clampToScreen(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private static func clampToScreen(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: x, y: y) }
        let frame = screen.visibleFrame
        let cx = max(frame.minX + 4, min(x, frame.maxX - width - 4))
        let cy = max(frame.minY + 4, min(y, frame.maxY - height - 4))
        return NSPoint(x: cx, y: cy)
    }

    func updateLevel(_ normalizedLevel: CGFloat) {
        waveformView.updateLevel(normalizedLevel)
    }

    func showProcessing() {
        waveformView.setMode(.processing)
    }

    func showCopiedToClipboard() {
        waveformView.stopAnimating()
        waveformView.isHidden = true
        checkmarkView.isHidden = false
        checkmarkView.animate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        waveformView.stopAnimating()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.waveformView.isHidden = false
            self.checkmarkView.isHidden = true
            self.checkmarkView.reset()
        })
    }
}

// MARK: - Waveform bars

enum WaveformMode {
    case recording
    case processing
}

final class WaveformView: NSView {
    private let barCount = 5
    private var barLayers: [CALayer] = []
    private var currentLevel: CGFloat = 0
    private var barHeights: [CGFloat] = []
    private var barVelocities: [CGFloat] = []
    private var barLevels: [CGFloat] = []
    private var tickCount: UInt64 = 0
    private var mode: WaveformMode = .recording

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        barHeights = Array(repeating: 0.1, count: barCount)
        barVelocities = Array(repeating: 0, count: barCount)
        barLevels = Array(repeating: 0, count: barCount)
        setupBars()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor(white: 0.8, alpha: 0.95).cgColor
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    override func layout() {
        super.layout()
        layoutBars()
    }

    private func layoutBars() {
        let totalWidth = bounds.width
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2.5
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (totalWidth - totalBarsWidth) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + gap)
            let heightFraction = barHeights[i]
            let barHeight = max(2, bounds.height * heightFraction)
            let y = (bounds.height - barHeight) / 2
            bar.frame = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        }
        CATransaction.commit()
    }

    func updateLevel(_ level: CGFloat) {
        currentLevel = level
    }

    func setMode(_ newMode: WaveformMode) {
        mode = newMode
        if newMode == .processing {
            currentLevel = 0
        }
    }

    func startAnimating() {
        stopAnimating()
        tickCount = 0
        mode = .recording

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        objc_setAssociatedObject(self, "animTimer", timer, .OBJC_ASSOCIATION_RETAIN)
    }

    func stopAnimating() {
        if let timer = objc_getAssociatedObject(self, "animTimer") as? Timer {
            timer.invalidate()
        }
        objc_setAssociatedObject(self, "animTimer", nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private func tick() {
        tickCount += 1
        let t = CGFloat(tickCount) / 60.0

        switch mode {
        case .recording:
            tickRecording(t: t)
        case .processing:
            tickProcessing(t: t)
        }

        layoutBars()
    }

    private func tickRecording(t: CGFloat) {
        let boosted = min(1.0, pow(currentLevel, 0.5) * 3.0)

        // Smooth the input level
        let attackSpeed: CGFloat = 0.25
        let decaySpeed: CGFloat = 0.06
        if boosted > barLevels[0] {
            barLevels[0] += (boosted - barLevels[0]) * attackSpeed
        } else {
            barLevels[0] += (boosted - barLevels[0]) * decaySpeed
        }
        let smoothLevel = barLevels[0]

        // Traveling wave: scrolls left-to-right, audio level controls amplitude
        // Two layered waves at different speeds for organic feel
        let waveSpeed1: CGFloat = 2.5
        let waveSpeed2: CGFloat = 1.6
        let barSpacing: CGFloat = 1.2  // phase offset between bars

        for i in 0..<barCount {
            let pos = CGFloat(i) * barSpacing
            let wave1 = sin(t * waveSpeed1 + pos) * 0.5 + 0.5
            let wave2 = sin(t * waveSpeed2 + pos * 0.7 + 0.5) * 0.5 + 0.5
            let combined = wave1 * 0.65 + wave2 * 0.35

            // Always some gentle motion even at low levels, bigger motion with voice
            let baseMotion: CGFloat = 0.12 + combined * 0.15
            let voiceMotion = smoothLevel * combined * 0.75
            let target = min(1.0, baseMotion + voiceMotion)

            // Soft spring for fluid motion
            let spring: CGFloat = 0.18
            let damping: CGFloat = 0.72
            barVelocities[i] += (target - barHeights[i]) * spring
            barVelocities[i] *= damping
            barHeights[i] += barVelocities[i]
            barHeights[i] = max(0.08, min(1.0, barHeights[i]))
        }
    }

    private func tickProcessing(t: CGFloat) {
        // Gentle slow pulse — all bars breathe together with slight offsets
        for i in 0..<barCount {
            let phase: CGFloat = CGFloat(i) * 0.4
            let pulse = sin(t * 1.5 + phase) * 0.5 + 0.5 // slow ~1.5 Hz
            let target = 0.15 + pulse * 0.3

            let spring: CGFloat = 0.2
            let damping: CGFloat = 0.7
            barVelocities[i] += (target - barHeights[i]) * spring
            barVelocities[i] *= damping
            barHeights[i] += barVelocities[i]
            barHeights[i] = max(0.08, min(1.0, barHeights[i]))
        }
    }
}

// MARK: - Animated checkmark

final class CheckmarkView: NSView {
    private var checkLayer: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func animate() {
        checkLayer?.removeFromSuperlayer()

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let path = CGMutablePath()
        // Checkmark proportions relative to view size
        path.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.50))
        path.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.25))
        path.addLine(to: CGPoint(x: size.width * 0.82, y: size.height * 0.75))

        let shape = CAShapeLayer()
        shape.path = path
        shape.strokeColor = NSColor(white: 0.85, alpha: 1.0).cgColor
        shape.fillColor = nil
        shape.lineWidth = 1.5
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.strokeEnd = 0

        layer?.addSublayer(shape)
        checkLayer = shape

        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.25
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        shape.add(anim, forKey: "draw")
    }

    func reset() {
        checkLayer?.removeFromSuperlayer()
        checkLayer = nil
    }
}
