import ApplicationServices
import CoreGraphics
import Foundation

/// Checks required macOS permissions before running tests.
/// IsolatedTester needs: Screen Recording + Accessibility.
public struct PermissionChecker {

    public struct PermissionStatus: Sendable {
        public let screenRecording: Bool
        public let accessibility: Bool

        public var allGranted: Bool { screenRecording && accessibility }
    }

    public static func check() -> PermissionStatus {
        let screenRecording = checkScreenRecording()
        let accessibility = checkAccessibility()
        ISTLogger.permissions.info("Screen recording: \(screenRecording ? "granted" : "denied")")
        ISTLogger.permissions.info("Accessibility: \(accessibility ? "granted" : "denied")")
        return PermissionStatus(
            screenRecording: screenRecording,
            accessibility: accessibility
        )
    }

    /// Print permission status and instructions for any missing permissions.
    /// Returns true if all permissions are granted.
    ///
    /// All output goes to stderr so that JSON/MCP consumers reading stdout are
    /// not corrupted by human-readable diagnostic text.
    @discardableResult
    public static func checkAndPrint() -> Bool {
        let status = check()

        if status.allGranted {
            return true
        }

        // Write every line to stderr, not stdout, to avoid corrupting JSON/MCP
        // output that callers may be parsing from stdout.
        func err(_ line: String) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        err("Missing required permissions:\n")

        if !status.screenRecording {
            err("  Screen Recording - DENIED")
            err("    -> System Settings -> Privacy & Security -> Screen Recording")
            err("    -> Enable for Terminal (or your terminal app)")
            err("")
        }

        if !status.accessibility {
            err("  Accessibility - DENIED")
            err("    -> System Settings -> Privacy & Security -> Accessibility")
            err("    -> Enable for Terminal (or your terminal app)")
            err("")
        }

        err("After granting permissions, restart your terminal and try again.")
        return false
    }

    // MARK: - Private Checks

    private static func checkScreenRecording() -> Bool {
        // CGPreflightScreenCaptureAccess returns true if permission is already granted
        // without prompting the user
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return false
    }

    private static func checkAccessibility() -> Bool {
        // AXIsProcessTrusted checks if this process has accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
