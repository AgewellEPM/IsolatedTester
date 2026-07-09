import Foundation
import ApplicationServices
import CoreGraphics

/// Introspects macOS accessibility tree for a given application PID.
/// Provides element discovery, search by role/label, and action execution.
public struct AXIntrospector: Sendable {

    public init() {}

    /// Build the full accessibility tree for an application.
    /// - Parameter pid: Process ID of the target application
    /// - Parameter maxDepth: Maximum tree depth to prevent infinite recursion
    /// - Returns: Root AXElement with children populated
    public func introspect(pid: pid_t, maxDepth: Int = 10) -> AXElement {
        let appRef = AXUIElementCreateApplication(pid)
        return buildElement(from: appRef, depth: 0, maxDepth: maxDepth)
    }

    /// Get a flattened summary of interactive elements for AI consumption.
    /// Returns only elements that can be clicked, typed into, or otherwise interacted with.
    public func interactiveSummary(pid: pid_t, maxDepth: Int = 10) -> AXTreeSummary {
        let root = introspect(pid: pid, maxDepth: maxDepth)
        var elements: [AXInteractiveElement] = []
        var totalCount = 0
        flattenInteractive(element: root, index: &totalCount, into: &elements)
        return AXTreeSummary(elementCount: totalCount, interactiveElements: elements)
    }

    /// Find elements matching a role and/or label.
    public func findElements(pid: pid_t, role: String? = nil, label: String? = nil,
                             identifier: String? = nil, maxDepth: Int = 10) -> [AXElement] {
        let root = introspect(pid: pid, maxDepth: maxDepth)
        var matches: [AXElement] = []
        search(element: root, role: role, label: label, identifier: identifier, into: &matches)
        return matches
    }

    /// Find the element at a specific screen coordinate.
    public func elementAtPoint(pid: pid_t, x: Float, y: Float) -> AXElement? {
        let appRef = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appRef, x, y, &elementRef)
        guard result == .success, let el = elementRef else { return nil }
        return buildElement(from: el, depth: 0, maxDepth: 3)
    }

    /// Perform an accessibility action on the element at a given position.
    public func performAction(pid: pid_t, x: Float, y: Float, action: String) -> Bool {
        let appRef = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appRef, x, y, &elementRef)
        guard result == .success, let el = elementRef else { return false }
        return AXUIElementPerformAction(el, action as CFString) == .success
    }

    // MARK: - Private

    private func buildElement(from ref: AXUIElement, depth: Int, maxDepth: Int) -> AXElement {
        let role = stringAttribute(ref, kAXRoleAttribute) ?? "Unknown"
        let label = stringAttribute(ref, kAXDescriptionAttribute)
            ?? stringAttribute(ref, kAXTitleAttribute)
        let value = stringAttribute(ref, kAXValueAttribute)
        let identifier = stringAttribute(ref, kAXIdentifierAttribute)
        let isEnabled = boolAttribute(ref, kAXEnabledAttribute) ?? true
        let isFocused = boolAttribute(ref, kAXFocusedAttribute) ?? false
        let frame = frameAttribute(ref)
        let actions = actionsForElement(ref)

        var children: [AXElement] = []
        if depth < maxDepth {
            var childrenRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(ref, kAXChildrenAttribute as CFString, &childrenRef)
            if result == .success, let childArray = childrenRef as? [AXUIElement] {
                children = childArray.prefix(100).map { // Cap children to prevent explosion
                    buildElement(from: $0, depth: depth + 1, maxDepth: maxDepth)
                }
            }
        }

        return AXElement(
            role: role,
            label: label,
            value: value,
            identifier: identifier,
            frame: frame,
            children: children,
            actions: actions,
            isEnabled: isEnabled,
            isFocused: isFocused
        )
    }

    private func stringAttribute(_ ref: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ ref: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        guard result == .success else { return nil }
        if let num = value as? NSNumber { return num.boolValue }
        return nil
    }

    private func frameAttribute(_ ref: AXUIElement) -> AXFrame {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(ref, kAXPositionAttribute as CFString, &posValue)
        let sizeResult = AXUIElementCopyAttributeValue(ref, kAXSizeAttribute as CFString, &sizeValue)

        var point = CGPoint.zero
        var size = CGSize.zero

        if posResult == .success, let posVal = posValue {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        }
        if sizeResult == .success, let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        return AXFrame(from: CGRect(origin: point, size: size))
    }

    private func actionsForElement(_ ref: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        let result = AXUIElementCopyActionNames(ref, &actionsRef)
        guard result == .success, let actions = actionsRef as? [String] else { return [] }
        return actions
    }

    private func flattenInteractive(element: AXElement, index: inout Int, into result: inout [AXInteractiveElement]) {
        index += 1

        // Interactive roles that AI should know about
        let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXComboBox", "AXSlider", "AXLink", "AXMenuItem",
            "AXMenuButton", "AXTab", "AXIncrementor", "AXColorWell", "AXDisclosureTriangle",
            "AXSegmentedControl"
        ]

        if interactiveRoles.contains(element.role) || !element.actions.isEmpty {
            result.append(AXInteractiveElement(
                index: index,
                role: element.role,
                label: element.label,
                value: element.value,
                frame: element.frame,
                actions: element.actions,
                isEnabled: element.isEnabled
            ))
        }

        for child in element.children {
            flattenInteractive(element: child, index: &index, into: &result)
        }
    }

    private func search(element: AXElement, role: String?, label: String?, identifier: String?, into result: inout [AXElement]) {
        var matches = true
        if let r = role, element.role != r { matches = false }
        if let l = label, element.label?.localizedCaseInsensitiveContains(l) != true { matches = false }
        if let i = identifier, element.identifier != i { matches = false }
        if matches && (role != nil || label != nil || identifier != nil) {
            result.append(element)
        }
        for child in element.children {
            search(element: child, role: role, label: label, identifier: identifier, into: &result)
        }
    }
}
