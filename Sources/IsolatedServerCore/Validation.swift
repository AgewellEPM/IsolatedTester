import Foundation

/// Validates request parameters before processing.
/// All validation errors throw `ServerError.invalidRequest` with a descriptive message.
public struct RequestValidator {

    // MARK: - Limits

    public static let maxCoordinate: Double = 10_000
    public static let maxObjectiveLength = 10_000
    public static let maxTextLength = 50_000
    public static let maxAppPathLength = 1024
    public static let maxActiveSessions = 50
    public static let maxStepsLimit = 500
    public static let maxDisplayDimension = 7680  // 8K
    public static let minDisplayDimension = 320
    public static let maxScrollDelta = 10_000
    public static let maxWaitSeconds: Double = 300
    public static let maxCriteriaCount = 50
    public static let maxCriterionLength = 2000

    // MARK: - Request Validation

    public static func validate(_ request: CreateSessionRequest, activeSessionCount: Int) throws {
        // Session limit
        guard activeSessionCount < maxActiveSessions else {
            throw ServerError.invalidRequest("Maximum active sessions (\(maxActiveSessions)) reached. Stop an existing session first.")
        }

        // App path validation
        try validateAppPath(request.appPath)

        // Display dimensions
        if let w = request.displayWidth {
            guard w >= minDisplayDimension && w <= maxDisplayDimension else {
                throw ServerError.invalidRequest("displayWidth must be \(minDisplayDimension)-\(maxDisplayDimension), got \(w)")
            }
        }
        if let h = request.displayHeight {
            guard h >= minDisplayDimension && h <= maxDisplayDimension else {
                throw ServerError.invalidRequest("displayHeight must be \(minDisplayDimension)-\(maxDisplayDimension), got \(h)")
            }
        }
    }

    public static func validate(_ request: RunTestRequest) throws {
        // Objective
        guard !request.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerError.invalidRequest("objective must not be empty")
        }
        guard request.objective.count <= maxObjectiveLength else {
            throw ServerError.invalidRequest("objective exceeds maximum length of \(maxObjectiveLength) characters")
        }

        // Max steps
        if let steps = request.maxSteps {
            guard steps >= 1 && steps <= maxStepsLimit else {
                throw ServerError.invalidRequest("maxSteps must be 1-\(maxStepsLimit), got \(steps)")
            }
        }

        // Provider
        if let provider = request.provider {
            let valid = ["anthropic", "openai", "claude-code", "claudecode"]
            guard valid.contains(provider.lowercased()) else {
                throw ServerError.invalidRequest("Unknown provider '\(provider)'. Valid: anthropic, openai, claude-code")
            }
        }

        // Criteria
        if let criteria = request.successCriteria {
            guard criteria.count <= maxCriteriaCount else {
                throw ServerError.invalidRequest("successCriteria count exceeds maximum of \(maxCriteriaCount)")
            }
            for c in criteria {
                guard c.count <= maxCriterionLength else {
                    throw ServerError.invalidRequest("Success criterion exceeds maximum length of \(maxCriterionLength) characters")
                }
            }
        }
        if let criteria = request.failureCriteria {
            guard criteria.count <= maxCriteriaCount else {
                throw ServerError.invalidRequest("failureCriteria count exceeds maximum of \(maxCriteriaCount)")
            }
            for c in criteria {
                guard c.count <= maxCriterionLength else {
                    throw ServerError.invalidRequest("Failure criterion exceeds maximum length of \(maxCriterionLength) characters")
                }
            }
        }
    }

    public static func validate(_ action: ActionRequest) throws {
        let validActions = ["click", "doubleClick", "type", "keyPress", "scroll", "drag", "wait"]
        guard validActions.contains(action.action) else {
            throw ServerError.invalidRequest("Unknown action '\(action.action)'. Valid: \(validActions.joined(separator: ", "))")
        }

        // Coordinate bounds
        if let x = action.x { try validateCoordinate(x, name: "x") }
        if let y = action.y { try validateCoordinate(y, name: "y") }
        if let x = action.fromX { try validateCoordinate(x, name: "fromX") }
        if let y = action.fromY { try validateCoordinate(y, name: "fromY") }
        if let x = action.toX { try validateCoordinate(x, name: "toX") }
        if let y = action.toY { try validateCoordinate(y, name: "toY") }

        // Text length
        if let text = action.text {
            guard text.count <= maxTextLength else {
                throw ServerError.invalidRequest("text exceeds maximum length of \(maxTextLength) characters")
            }
        }

        // Scroll deltas
        if let dy = action.deltaY {
            guard abs(dy) <= maxScrollDelta else {
                throw ServerError.invalidRequest("deltaY magnitude exceeds maximum of \(maxScrollDelta)")
            }
        }
        if let dx = action.deltaX {
            guard abs(dx) <= maxScrollDelta else {
                throw ServerError.invalidRequest("deltaX magnitude exceeds maximum of \(maxScrollDelta)")
            }
        }

        // Wait duration
        if let seconds = action.seconds {
            guard seconds >= 0 && seconds <= maxWaitSeconds else {
                throw ServerError.invalidRequest("wait seconds must be 0-\(Int(maxWaitSeconds)), got \(seconds)")
            }
        }

        // Action-specific required fields
        switch action.action {
        case "click", "doubleClick":
            guard action.x != nil && action.y != nil else {
                throw ServerError.invalidRequest("\(action.action) requires x and y coordinates")
            }
        case "type":
            guard action.text != nil else {
                throw ServerError.invalidRequest("type requires text parameter")
            }
        case "keyPress":
            guard action.key != nil else {
                throw ServerError.invalidRequest("keyPress requires key parameter")
            }
        case "drag":
            guard action.fromX != nil && action.fromY != nil && action.toX != nil && action.toY != nil else {
                throw ServerError.invalidRequest("drag requires fromX, fromY, toX, and toY coordinates")
            }
        default:
            break
        }
    }

    public static func validateSessionId(_ id: String) throws {
        // Session IDs are 8-char lowercase hex strings derived from UUID
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        guard id.count >= 4 && id.count <= 64,
              id.unicodeScalars.allSatisfy({ hexChars.contains($0) || $0 == "-" }) else {
            throw ServerError.invalidRequest("Invalid session ID format")
        }
    }

    // MARK: - Helpers

    private static func validateAppPath(_ path: String) throws {
        guard path.count <= maxAppPathLength else {
            throw ServerError.invalidRequest("appPath exceeds maximum length of \(maxAppPathLength) characters")
        }
        guard !path.isEmpty else {
            throw ServerError.invalidRequest("appPath must not be empty")
        }

        // Path traversal check
        let normalized = (path as NSString).standardizingPath
        guard !normalized.contains("..") else {
            throw ServerError.invalidRequest("appPath must not contain path traversal sequences")
        }

        // Must be a .app bundle
        guard normalized.hasSuffix(".app") else {
            throw ServerError.invalidRequest("appPath must point to a .app bundle")
        }

        // Must exist
        guard FileManager.default.fileExists(atPath: normalized) else {
            throw ServerError.invalidRequest("App not found at path: \(normalized)")
        }
    }

    private static func validateCoordinate(_ value: Double, name: String) throws {
        guard value >= 0 && value <= maxCoordinate else {
            throw ServerError.invalidRequest("\(name) must be 0-\(Int(maxCoordinate)), got \(value)")
        }
        guard !value.isNaN && !value.isInfinite else {
            throw ServerError.invalidRequest("\(name) must be a finite number")
        }
    }
}
