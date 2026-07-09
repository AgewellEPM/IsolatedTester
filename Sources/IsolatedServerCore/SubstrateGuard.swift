import Foundation
import IsolatedTesterKit

/// Self-substrate keystroke guard for the isolated-tester MCP.
///
/// Context: on 2026-07-09 an agent driving a window through this MCP pressed
/// "continue" on a Codex prompt whose pending action was
/// `launchctl kickstart -k com.kist.desktop-vision-console` — restarting the
/// Kist Desktop Vision Console it was running inside. `KeepAlive=true` respawned
/// it in a heavy-model reload loop and froze the machine.
///
/// This guard is intentionally NARROW to keep false positives near zero: it does
/// NOT look at which key is pressed. It refuses an input action ONLY when the
/// target window's own visible text literally shows a self-restart confirmation
/// for the Kist substrate (a `launchctl … com.kist.*` mutator, a kill of the
/// desktop-vision-console/runtime process, or a kill of port 8765). A normal
/// "continue" / Enter on any unrelated prompt is never touched.
///
/// It fails OPEN: if the accessibility text can't be read, no input is blocked
/// (precision over recall — the console's own circuit breaker is the deterministic
/// backstop against an actual restart loop).
public enum SubstrateGuard {

    /// Flatten an accessibility subtree into one lowercased string of its visible
    /// text (label + value + identifier across every node).
    public static func flatten(_ element: AXElement) -> String {
        var parts: [String] = []
        func walk(_ el: AXElement) {
            if let l = el.label { parts.append(l) }
            if let v = el.value { parts.append(v) }
            if let i = el.identifier { parts.append(i) }
            for child in el.children { walk(child) }
        }
        walk(element)
        return parts.joined(separator: " ").lowercased()
    }

    /// Returns a refusal reason if `windowText` shows a self-restart of the Kist
    /// substrate, else nil. `windowText` is expected pre-lowercased by `flatten`,
    /// but we lowercase defensively so callers passing raw text are also correct.
    public static func selfRestartReason(inWindowText windowText: String) -> String? {
        let text = windowText.lowercased()
        let refusal = "self-substrate protection (isolated-tester): refusing to send input to a window whose "
            + "visible text is a self-restart of the Kist runtime this agent lives in "
            + "(launchctl on com.kist.* / kill of the desktop-vision-console / port 8765). This exact shape "
            + "froze the machine on 2026-07-09. A human must do this from a terminal that is NOT this service."

        // launchctl against a com.kist.* service with a MUTATING subcommand. Read-only
        // (list/print/blame/dumpstate) is deliberately not matched.
        if text.contains("launchctl") && text.contains("com.kist.") {
            let mutators = ["kickstart", "bootout", "unload", "load", "bootstrap",
                            "remove", "disable", "enable", "stop", "kill"]
            if mutators.contains(where: { text.contains($0) }) { return refusal }
        }

        // kill / pkill / killall of the console or runtime by name.
        let touchesConsole = text.contains("desktop-vision-console")
            || text.contains("com.kist.desktop-vision-console")
            || text.contains("com.kist.runtime")
        if touchesConsole,
           text.contains("pkill") || text.contains("killall") || text.contains("kill ") || text.hasSuffix(" kill") {
            return refusal
        }

        // Killing whatever holds the console's port (lsof -ti:8765 | xargs kill, fuser -k 8765/tcp).
        if text.contains("8765"), text.contains("kill") || text.contains("fuser") {
            return refusal
        }
        return nil
    }
}
