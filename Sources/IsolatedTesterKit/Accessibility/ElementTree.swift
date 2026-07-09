import Foundation
import CoreGraphics

/// Represents a single UI element from the macOS accessibility tree.
public struct AXElement: Codable, Sendable {
    public let role: String
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let frame: AXFrame
    public let children: [AXElement]
    public let actions: [String]
    public let isEnabled: Bool
    public let isFocused: Bool

    public init(role: String, label: String? = nil, value: String? = nil,
                identifier: String? = nil, frame: AXFrame = .zero,
                children: [AXElement] = [], actions: [String] = [],
                isEnabled: Bool = true, isFocused: Bool = false) {
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.children = children
        self.actions = actions
        self.isEnabled = isEnabled
        self.isFocused = isFocused
    }
}

/// Codable-friendly CGRect replacement.
public struct AXFrame: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public static let zero = AXFrame(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var center: (x: Double, y: Double) {
        (x + width / 2, y + height / 2)
    }
}

/// Summary of the accessibility tree for AI consumption.
/// Flattened list of interactive elements with their locations.
public struct AXTreeSummary: Codable, Sendable {
    public let elementCount: Int
    public let interactiveElements: [AXInteractiveElement]

    public init(elementCount: Int, interactiveElements: [AXInteractiveElement]) {
        self.elementCount = elementCount
        self.interactiveElements = interactiveElements
    }
}

/// A flattened interactive element for easy AI targeting.
public struct AXInteractiveElement: Codable, Sendable {
    public let index: Int
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: AXFrame
    public let actions: [String]
    public let isEnabled: Bool

    public init(index: Int, role: String, label: String? = nil, value: String? = nil,
                frame: AXFrame = .zero, actions: [String] = [], isEnabled: Bool = true) {
        self.index = index
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.actions = actions
        self.isEnabled = isEnabled
    }
}
