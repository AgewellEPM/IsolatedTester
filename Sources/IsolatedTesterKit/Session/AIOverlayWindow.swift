import AppKit
import CoreGraphics
import Foundation

/// Creates a floating border overlay around a target app window to indicate AI control.
/// The overlay is a transparent, click-through window with a colored border and label.
public final class AIOverlayWindow: @unchecked Sendable {

    // MARK: - Configuration

    public struct Style: @unchecked Sendable {
        public let borderColor: NSColor
        public let borderWidth: CGFloat
        public let cornerRadius: CGFloat
        public let labelText: String
        public let labelFontSize: CGFloat
        public let labelColor: NSColor
        public let labelBackgroundColor: NSColor
        public let glowRadius: CGFloat
        public let pulseAnimation: Bool

        public var labelFont: NSFont {
            NSFont.systemFont(ofSize: labelFontSize, weight: .bold)
        }

        public static let `default` = Style(
            borderColor: NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.9),
            borderWidth: 3.0,
            cornerRadius: 10.0,
            labelText: "AI CONTROLLED",
            labelFontSize: 11,
            labelColor: .white,
            labelBackgroundColor: NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.85),
            glowRadius: 8.0,
            pulseAnimation: true
        )

        public init(
            borderColor: NSColor = NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.9),
            borderWidth: CGFloat = 3.0,
            cornerRadius: CGFloat = 10.0,
            labelText: String = "AI CONTROLLED",
            labelFontSize: CGFloat = 11,
            labelColor: NSColor = .white,
            labelBackgroundColor: NSColor = NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.85),
            glowRadius: CGFloat = 8.0,
            pulseAnimation: Bool = true
        ) {
            self.borderColor = borderColor
            self.borderWidth = borderWidth
            self.cornerRadius = cornerRadius
            self.labelText = labelText
            self.labelFontSize = labelFontSize
            self.labelColor = labelColor
            self.labelBackgroundColor = labelBackgroundColor
            self.glowRadius = glowRadius
            self.pulseAnimation = pulseAnimation
        }
    }

    // MARK: - State

    private var overlayWindow: NSWindow?
    private var borderView: BorderOverlayView?
    private var trackingTimer: Timer?
    private let targetPID: pid_t
    private let style: Style
    private let displayID: CGDirectDisplayID

    // MARK: - Init

    public init(targetPID: pid_t, displayID: CGDirectDisplayID, style: Style = .default) {
        self.targetPID = targetPID
        self.displayID = displayID
        self.style = style
    }

    deinit {
        // Capture references before deinit completes
        let window = overlayWindow
        let timer = trackingTimer
        DispatchQueue.main.async {
            timer?.invalidate()
            window?.orderOut(nil)
        }
    }

    // MARK: - Public API

    /// Show the overlay border around the target app's frontmost window.
    @MainActor
    public func show() {
        guard overlayWindow == nil else { return }

        guard let windowFrame = findTargetWindowFrame() else {
            ISTLogger.session.debug("AIOverlay: No window found for PID \(self.targetPID), retrying...")
            // Retry after a short delay — the window may not be on screen yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.show() }
            }
            return
        }

        createOverlayWindow(around: windowFrame)
        startTracking()
    }

    /// Hide and destroy the overlay.
    @MainActor
    public func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        borderView = nil
    }

    /// Update the label text (e.g. to show current step).
    @MainActor
    public func updateLabel(_ text: String) {
        borderView?.labelText = text
        borderView?.needsDisplay = true
    }

    /// Flash the border briefly (e.g. on action execution).
    @MainActor
    public func flash() {
        guard let view = borderView else { return }
        let original = view.layer?.opacity ?? 1.0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            view.animator().alphaValue = 1.0
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                view.animator().alphaValue = CGFloat(original)
            })
        })
    }

    // MARK: - Private: Window Creation

    @MainActor
    private func createOverlayWindow(around frame: CGRect) {
        // Expand frame slightly so border sits outside the app window
        let inset = style.borderWidth + style.glowRadius
        let overlayFrame = frame.insetBy(dx: -inset, dy: -inset)
            .offsetBy(dx: 0, dy: -24) // space for label above

        let expandedFrame = NSRect(
            x: overlayFrame.origin.x,
            y: overlayFrame.origin.y,
            width: overlayFrame.width,
            height: overlayFrame.height + 28 // label height
        )

        let window = NSWindow(
            contentRect: expandedFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true  // Click-through
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false

        let view = BorderOverlayView(frame: window.contentView!.bounds)
        view.style = style
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true

        window.contentView?.addSubview(view)
        window.orderFrontRegardless()

        if style.pulseAnimation {
            startPulseAnimation(on: view)
        }

        self.overlayWindow = window
        self.borderView = view
    }

    // MARK: - Private: Window Tracking

    @MainActor
    private func startTracking() {
        // Poll the target window position every 100ms
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updatePosition()
            }
        }
    }

    @MainActor
    private func updatePosition() {
        guard let windowFrame = findTargetWindowFrame() else {
            // App window disappeared — hide overlay
            hide()
            return
        }

        let inset = style.borderWidth + style.glowRadius
        let overlayFrame = windowFrame.insetBy(dx: -inset, dy: -inset)
            .offsetBy(dx: 0, dy: -24)

        let expandedFrame = NSRect(
            x: overlayFrame.origin.x,
            y: overlayFrame.origin.y,
            width: overlayFrame.width,
            height: overlayFrame.height + 28
        )

        if let window = overlayWindow, window.frame != expandedFrame {
            window.setFrame(expandedFrame, display: true, animate: false)
            borderView?.needsDisplay = true
        }
    }

    // MARK: - Private: Find Target Window

    private func findTargetWindowFrame() -> CGRect? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Find the largest window belonging to our target PID
        var bestFrame: CGRect?
        var bestArea: CGFloat = 0

        for info in windowInfoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == targetPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0, // Normal window layer
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"],
                  w > 50 && h > 50 // Skip tiny windows (toolbars, etc.)
            else { continue }

            let area = w * h
            if area > bestArea {
                bestArea = area
                // Convert from CG screen coords (top-left origin) to NS screen coords (bottom-left origin)
                let screenHeight = NSScreen.main?.frame.height ?? 1080
                bestFrame = CGRect(x: x, y: screenHeight - y - h, width: w, height: h)
            }
        }

        return bestFrame
    }

    // MARK: - Private: Animation

    @MainActor
    private func startPulseAnimation(on view: NSView) {
        guard let layer = view.layer else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.6
        pulse.duration = 1.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}

// MARK: - Border Overlay View

private class BorderOverlayView: NSView {

    var style: AIOverlayWindow.Style = .default
    var labelText: String?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let labelHeight: CGFloat = 24
        let borderArea = NSRect(
            x: 0,
            y: labelHeight + 4,
            width: bounds.width,
            height: bounds.height - labelHeight - 4
        )

        // Draw glow (shadow behind border)
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: style.glowRadius,
            color: style.borderColor.withAlphaComponent(0.5).cgColor
        )
        drawBorderRect(in: ctx, rect: borderArea)
        ctx.restoreGState()

        // Draw border (no glow)
        drawBorderRect(in: ctx, rect: borderArea)

        // Draw label pill
        drawLabel(in: ctx, bounds: bounds)
    }

    private func drawBorderRect(in ctx: CGContext, rect: NSRect) {
        let inset = style.borderWidth / 2
        let borderRect = rect.insetBy(dx: inset + style.glowRadius, dy: inset + style.glowRadius)
        let path = CGPath(
            roundedRect: borderRect,
            cornerWidth: style.cornerRadius,
            cornerHeight: style.cornerRadius,
            transform: nil
        )

        ctx.setStrokeColor(style.borderColor.cgColor)
        ctx.setLineWidth(style.borderWidth)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawLabel(in ctx: CGContext, bounds: NSRect) {
        let text = labelText ?? style.labelText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.labelFont,
            .foregroundColor: style.labelColor,
        ]

        let textSize = (text as NSString).size(withAttributes: attributes)
        let pillWidth = textSize.width + 16
        let pillHeight: CGFloat = 20
        let pillX = (bounds.width - pillWidth) / 2
        let pillY: CGFloat = 2

        // Pill background
        let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: pillHeight / 2,
            cornerHeight: pillHeight / 2,
            transform: nil
        )

        ctx.setFillColor(style.labelBackgroundColor.cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()

        // Text
        let textX = pillX + 8
        let textY = pillY + (pillHeight - textSize.height) / 2
        let textRect = NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
