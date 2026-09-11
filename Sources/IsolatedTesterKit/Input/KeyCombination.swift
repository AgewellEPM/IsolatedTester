import CoreGraphics
import Foundation

/// A validated host key and modifier set. Parsing never creates or posts events.
/// Guest interpretation still depends on the VM's keyboard configuration.
public struct KeyCombination: Sendable {
    public let keyCode: CGKeyCode
    public let modifiers: CGEventFlags

    public static func parse(key: String?, modifiers: [String]? = nil) throws -> KeyCombination {
        guard let key, !key.isEmpty else {
            throw KeyCombinationError.invalid("keyPress requires a non-empty key parameter")
        }
        guard key.utf8.count <= 128, (modifiers?.count ?? 0) <= 16 else {
            throw KeyCombinationError.invalid("keyPress exceeds key or modifier limits")
        }

        // Keep every pre-existing single-key spelling, including literal space.
        // '+' is a separator, not an existing key name: use shift+= for plus.
        let tokens = key == " " ? [key] : key.components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard tokens.count <= 17, tokens.allSatisfy({ !$0.isEmpty }) else {
            throw KeyCombinationError.invalid("keyPress contains an empty or excessive combination component")
        }

        var flags: CGEventFlags = []
        for modifier in Array(tokens.dropLast()) + (modifiers ?? []) {
            let flag: CGEventFlags
            switch modifier.trimmingCharacters(in: .whitespaces).lowercased() {
            case "command", "cmd": flag = .maskCommand
            case "shift": flag = .maskShift
            case "option", "alt": flag = .maskAlternate
            case "control", "ctrl": flag = .maskControl
            default:
                throw KeyCombinationError.invalid("keyPress has an unknown modifier; use cmd, shift, alt, or ctrl")
            }
            // Aliases and repeated modifiers merge; no duplicate physical downs.
            flags.formUnion(flag)
        }
        guard let base = tokens.last, let code = InputController.KeyCode.fromString(base) else {
            throw KeyCombinationError.invalid("keyPress has an unknown key or lacks a base key")
        }
        return KeyCombination(keyCode: code, modifiers: flags)
    }
}

public enum KeyCombinationError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}
