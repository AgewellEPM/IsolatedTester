import AppKit
import IsolatedTesterKit

/// Opened only by Luke's desktop icon. This is a read-only view of the virtual
/// monitor, never an input bridge or a requirement for agent work.
@MainActor
final class WorkspaceViewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let imageView = NSImageView()
    private let status = NSTextField(labelWithString: "Connecting to AI workspace…")
    private let capture = ScreenCapture()
    private var task: Task<Void, Never>?

    static func run() {
        let app = NSApplication.shared
        let viewer = WorkspaceViewer()
        app.setActivationPolicy(.regular)
        app.delegate = viewer
        withExtendedLifetime(viewer) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        self.window = window
        window.title = "AI Workspace — View Only"
        window.delegate = self
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(imageView); content.addSubview(status)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let workspace = try WorkspaceMonitor.current()
                    let frame = try await capture.capture(displayID: workspace.displayID)
                    imageView.image = NSImage(data: frame.imageData)
                    status.stringValue = "AI workspace • view only • \(workspace.width) × \(workspace.height) • mouse and keyboard stay on your desktop"
                } catch {
                    status.stringValue = "Workspace view unavailable: \(error.localizedDescription)"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        NSApp.terminate(nil) // The monitor belongs to its separate host.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
