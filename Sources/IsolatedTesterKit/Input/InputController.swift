import CoreGraphics
import Foundation

/// Simulates mouse and keyboard input targeted at a specific display or process.
/// Uses CGEvent API to synthesize input events without affecting the user's physical display.
public final class InputController: @unchecked Sendable {

    public let displayID: CGDirectDisplayID
    public let targetPID: pid_t?
    private let eventSource: CGEventSource?

    public init(displayID: CGDirectDisplayID, targetPID: pid_t? = nil) {
        self.displayID = displayID
        self.targetPID = targetPID
        self.eventSource = CGEventSource(stateID: .combinedSessionState)
    }

    // MARK: - Mouse Actions

    /// Move the mouse cursor to a position on the virtual display.
    public func mouseMove(to point: CGPoint) throws {
        let absolutePoint = toAbsolute(point)

        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: absolutePoint,
            mouseButton: .left
        ) else {
            throw InputError.eventCreationFailed("mouseMove")
        }

        postEvent(event)
    }

    /// Click at a position on the virtual display.
    public func click(at point: CGPoint, button: CGMouseButton = .left, clickCount: Int = 1) throws {
        let absolutePoint = toAbsolute(point)

        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard let downEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: downType,
            mouseCursorPosition: absolutePoint,
            mouseButton: button
        ) else {
            throw InputError.eventCreationFailed("click down")
        }

        guard let upEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: upType,
            mouseCursorPosition: absolutePoint,
            mouseButton: button
        ) else {
            throw InputError.eventCreationFailed("click up")
        }

        downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))

        postEvent(downEvent)
        usleep(50_000) // 50ms between down/up
        postEvent(upEvent)
    }

    /// Double-click at a position.
    public func doubleClick(at point: CGPoint) throws {
        try click(at: point, clickCount: 1)
        usleep(100_000)
        try click(at: point, clickCount: 2)
    }

    /// Scroll at the current cursor position.
    public func scroll(deltaY: Int32, deltaX: Int32 = 0) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw InputError.eventCreationFailed("scroll")
        }

        postEvent(event)
    }

    /// Drag from one point to another.
    public func drag(from start: CGPoint, to end: CGPoint, steps: Int = 20) throws {
        let absStart = toAbsolute(start)
        let absEnd = toAbsolute(end)

        // Mouse down at start
        guard let downEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: absStart,
            mouseButton: .left
        ) else {
            throw InputError.eventCreationFailed("drag down")
        }
        postEvent(downEvent)

        // Interpolate movement
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let point = CGPoint(
                x: absStart.x + (absEnd.x - absStart.x) * t,
                y: absStart.y + (absEnd.y - absStart.y) * t
            )

            guard let dragEvent = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { continue }

            postEvent(dragEvent)
            usleep(10_000) // 10ms per step
        }

        // Mouse up at end
        guard let upEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: absEnd,
            mouseButton: .left
        ) else {
            throw InputError.eventCreationFailed("drag up")
        }
        postEvent(upEvent)
    }

    // MARK: - Keyboard Actions

    /// Type a string character by character.
    public func typeText(_ text: String, delayPerChar: UInt32 = 30_000) throws {
        for char in text {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else {
                throw InputError.eventCreationFailed("keyDown")
            }

            var unicodeChar = Array(String(char).utf16)
            event.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            postEvent(event)

            guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                throw InputError.eventCreationFailed("keyUp")
            }
            upEvent.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            postEvent(upEvent)

            usleep(delayPerChar)
        }
    }

    /// Press a specific key with optional modifiers.
    public func keyPress(_ keyCode: CGKeyCode, modifiers: CGEventFlags = []) throws {
        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true) else {
            throw InputError.eventCreationFailed("keyPress down")
        }
        downEvent.flags = modifiers
        postEvent(downEvent)

        usleep(50_000)

        guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
            throw InputError.eventCreationFailed("keyPress up")
        }
        upEvent.flags = modifiers
        postEvent(upEvent)
    }

    /// Common key shortcuts.
    public func commandKey(_ keyCode: CGKeyCode) throws {
        try keyPress(keyCode, modifiers: .maskCommand)
    }

    // MARK: - Coordinate Translation

    private func toAbsolute(_ point: CGPoint) -> CGPoint {
        let displayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: displayBounds.origin.x + point.x,
            y: displayBounds.origin.y + point.y
        )
    }

    // MARK: - Event Posting

    private func postEvent(_ event: CGEvent) {
        if let pid = targetPID {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Key Codes (full macOS virtual key code table from Carbon Events.h / HIToolbox)

public extension InputController {
    enum KeyCode {
        // Letters
        public static let a: CGKeyCode = 0x00
        public static let s: CGKeyCode = 0x01
        public static let d: CGKeyCode = 0x02
        public static let f: CGKeyCode = 0x03
        public static let h: CGKeyCode = 0x04
        public static let g: CGKeyCode = 0x05
        public static let z: CGKeyCode = 0x06
        public static let x: CGKeyCode = 0x07
        public static let c: CGKeyCode = 0x08
        public static let v: CGKeyCode = 0x09
        public static let b: CGKeyCode = 0x0B
        public static let q: CGKeyCode = 0x0C
        public static let w: CGKeyCode = 0x0D
        public static let e: CGKeyCode = 0x0E
        public static let r: CGKeyCode = 0x0F
        public static let y: CGKeyCode = 0x10
        public static let t: CGKeyCode = 0x11
        public static let one: CGKeyCode = 0x12
        public static let two: CGKeyCode = 0x13
        public static let three: CGKeyCode = 0x14
        public static let four: CGKeyCode = 0x15
        public static let six: CGKeyCode = 0x16
        public static let five: CGKeyCode = 0x17
        public static let equal: CGKeyCode = 0x18
        public static let nine: CGKeyCode = 0x19
        public static let seven: CGKeyCode = 0x1A
        public static let minus: CGKeyCode = 0x1B
        public static let eight: CGKeyCode = 0x1C
        public static let zero: CGKeyCode = 0x1D
        public static let rightBracket: CGKeyCode = 0x1E
        public static let o: CGKeyCode = 0x1F
        public static let u: CGKeyCode = 0x20
        public static let leftBracket: CGKeyCode = 0x21
        public static let i: CGKeyCode = 0x22
        public static let p: CGKeyCode = 0x23
        public static let l: CGKeyCode = 0x25
        public static let j: CGKeyCode = 0x26
        public static let quote: CGKeyCode = 0x27
        public static let k: CGKeyCode = 0x28
        public static let semicolon: CGKeyCode = 0x29
        public static let backslash: CGKeyCode = 0x2A
        public static let comma: CGKeyCode = 0x2B
        public static let slash: CGKeyCode = 0x2C
        public static let n: CGKeyCode = 0x2D
        public static let m: CGKeyCode = 0x2E
        public static let period: CGKeyCode = 0x2F
        public static let grave: CGKeyCode = 0x32  // backtick/tilde

        // Special keys
        public static let returnKey: CGKeyCode = 0x24
        public static let tab: CGKeyCode = 0x30
        public static let space: CGKeyCode = 0x31
        public static let delete: CGKeyCode = 0x33  // backspace
        public static let escape: CGKeyCode = 0x35
        public static let forwardDelete: CGKeyCode = 0x75
        public static let home: CGKeyCode = 0x73
        public static let end: CGKeyCode = 0x77
        public static let pageUp: CGKeyCode = 0x74
        public static let pageDown: CGKeyCode = 0x79

        // Arrow keys
        public static let leftArrow: CGKeyCode = 0x7B
        public static let rightArrow: CGKeyCode = 0x7C
        public static let downArrow: CGKeyCode = 0x7D
        public static let upArrow: CGKeyCode = 0x7E

        // Function keys
        public static let f1: CGKeyCode = 0x7A
        public static let f2: CGKeyCode = 0x78
        public static let f3: CGKeyCode = 0x63
        public static let f4: CGKeyCode = 0x76
        public static let f5: CGKeyCode = 0x60
        public static let f6: CGKeyCode = 0x61
        public static let f7: CGKeyCode = 0x62
        public static let f8: CGKeyCode = 0x64
        public static let f9: CGKeyCode = 0x65
        public static let f10: CGKeyCode = 0x6D
        public static let f11: CGKeyCode = 0x67
        public static let f12: CGKeyCode = 0x6F

        // Keypad
        public static let keypadDecimal: CGKeyCode = 0x41
        public static let keypadMultiply: CGKeyCode = 0x43
        public static let keypadPlus: CGKeyCode = 0x45
        public static let keypadDivide: CGKeyCode = 0x4B
        public static let keypadEnter: CGKeyCode = 0x4C
        public static let keypadMinus: CGKeyCode = 0x4E
        public static let keypadEquals: CGKeyCode = 0x51
        public static let keypad0: CGKeyCode = 0x52
        public static let keypad1: CGKeyCode = 0x53
        public static let keypad2: CGKeyCode = 0x54
        public static let keypad3: CGKeyCode = 0x55
        public static let keypad4: CGKeyCode = 0x56
        public static let keypad5: CGKeyCode = 0x57
        public static let keypad6: CGKeyCode = 0x58
        public static let keypad7: CGKeyCode = 0x59
        public static let keypad8: CGKeyCode = 0x5B
        public static let keypad9: CGKeyCode = 0x5C

        /// Look up a key code from a string name. Returns nil for unknown keys.
        public static func fromString(_ name: String) -> CGKeyCode? {
            let lower = name.lowercased()

            // Single character lookup
            if lower.count == 1, let char = lower.first {
                return characterMap[char]
            }

            // Named key lookup
            return namedKeyMap[lower]
        }

        private static let characterMap: [Character: CGKeyCode] = [
            "a": a, "b": b, "c": c, "d": d, "e": e, "f": f, "g": g,
            "h": h, "i": i, "j": j, "k": k, "l": l, "m": m, "n": n,
            "o": o, "p": p, "q": q, "r": r, "s": s, "t": t, "u": u,
            "v": v, "w": w, "x": x, "y": y, "z": z,
            "0": zero, "1": one, "2": two, "3": three, "4": four,
            "5": five, "6": six, "7": seven, "8": eight, "9": nine,
            "-": minus, "=": equal, "[": leftBracket, "]": rightBracket,
            ";": semicolon, "'": quote, "\\": backslash, ",": comma,
            ".": period, "/": slash, "`": grave, " ": space,
        ]

        private static let namedKeyMap: [String: CGKeyCode] = [
            "return": returnKey, "enter": returnKey,
            "tab": tab, "space": space,
            "delete": delete, "backspace": delete,
            "forwarddelete": forwardDelete, "fwddelete": forwardDelete,
            "escape": escape, "esc": escape,
            "up": upArrow, "down": downArrow, "left": leftArrow, "right": rightArrow,
            "home": home, "end": end, "pageup": pageUp, "pagedown": pageDown,
            "f1": f1, "f2": f2, "f3": f3, "f4": f4, "f5": f5, "f6": f6,
            "f7": f7, "f8": f8, "f9": f9, "f10": f10, "f11": f11, "f12": f12,
        ]
    }
}

// MARK: - Errors

public enum InputError: Error, LocalizedError {
    case eventCreationFailed(String)
    case targetNotFound(pid_t)

    public var errorDescription: String? {
        switch self {
        case .eventCreationFailed(let ctx): return "Failed to create CGEvent: \(ctx)"
        case .targetNotFound(let pid): return "Process \(pid) not found"
        }
    }
}
