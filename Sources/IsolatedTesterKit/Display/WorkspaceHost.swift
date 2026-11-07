import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Persistent display owner. No applications are launched and no keyboard
/// events are observed. The pointer guard only prevents the physical pointer
/// from entering this workspace; AI events still go directly to their PID.
@MainActor
public final class WorkspaceHost {
    private let manager = VirtualDisplayManager()
    private var displayID: CGDirectDisplayID = 0
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lease: WorkspaceLease?
    private var timer: Timer?
    private var lastHostPoint = CGPoint.zero
    private var hostBounds: [CGRect] = []

    public init() {}

    public func start() throws {
        lease = try WorkspaceLease(name: "monitor-owner")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if !AXIsProcessTrusted() {
            let marker = WorkspaceMonitor.directory.appendingPathComponent("accessibility-requested")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data().write(to: marker)
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            FileHandle.standardError.write(Data("AI workspace waiting for isolated-mcp Accessibility permission; no monitor or host input active.\n".utf8))
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.timer?.invalidate(); self.timer = nil
                    do {
                        try self.activateWorkspace()
                    } catch {
                        FileHandle.standardError.write(Data("Workspace activation failed: \(error)\n".utf8))
                        self.stop()
                        exit(1)
                    }
                }
            }
            return
        }
        try activateWorkspace()
    }

    private func activateWorkspace() throws {
        // Install the guard before publishing any display. Failure cannot leave
        // an invisible monitor that the physical pointer can enter.
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let host = Unmanaged<WorkspaceHost>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { host.filter(type: type, event: event) }
            }, userInfo: context) else {
            throw DisplayError.creationFailed("Workspace pointer guard requires Accessibility permission for isolated-mcp.")
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastHostPoint = CGEvent(source: nil)?.location ?? .zero
        do {
            let display = try manager.createDisplay(config: .init(width: 1440, height: 900, ppi: 72, name: "AI Workspace"))
            displayID = display.displayID
            try manager.placeWorkspaceOnLeft(displayID: displayID)
            refreshHostBounds()
            try publish()
        } catch {
            stop()
            throw error
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    if let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    try self.manager.placeWorkspaceOnLeft(displayID: self.displayID)
                    self.refreshHostBounds()
                    try self.publish()
                } catch {
                    FileHandle.standardError.write(Data("Workspace health failed: \(error)\n".utf8))
                    self.stop()
                    exit(1) // launchd restarts the owner, never another test.
                }
            }
        }
    }

    private func publish() throws {
        try WorkspaceMonitor.save(.init(displayID: displayID,
                                       pointerGuard: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false))
    }

    private func refreshHostBounds() {
        hostBounds = manager.getActiveDisplays().filter { $0 != displayID }.map { CGDisplayBounds($0) }
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard displayID != 0 else { return Unmanaged.passUnretained(event) }
        let point = event.location
        let allowed = hostBounds
        if allowed.contains(where: { $0.contains(point) }) {
            lastHostPoint = point
            return Unmanaged.passUnretained(event)
        }
        guard CGDisplayBounds(displayID).contains(point) else { return Unmanaged.passUnretained(event) }
        let clamped = Self.allowedPoint(lastHostPoint, displays: allowed)
        event.location = clamped
        CGWarpMouseCursorPosition(clamped)
        return Unmanaged.passUnretained(event)
    }

    static func allowedPoint(_ point: CGPoint, displays: [CGRect]) -> CGPoint {
        displays.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1),
                    y: min(max(point.y, rect.minY), rect.maxY - 1))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? .zero
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        if displayID != 0 { manager.destroyDisplay(id: displayID); displayID = 0 }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        if lease != nil { try? FileManager.default.removeItem(at: WorkspaceMonitor.stateURL) }
        lease = nil
    }
}
