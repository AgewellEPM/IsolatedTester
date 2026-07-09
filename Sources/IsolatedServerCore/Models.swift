import Foundation
import CoreGraphics

// MARK: - Request Types

public struct CreateSessionRequest: Codable, Sendable {
    public let appPath: String
    public let displayWidth: Int?
    public let displayHeight: Int?
    public let fallbackToMainDisplay: Bool?

    public init(appPath: String, displayWidth: Int? = nil, displayHeight: Int? = nil, fallbackToMainDisplay: Bool? = nil) {
        self.appPath = appPath
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.fallbackToMainDisplay = fallbackToMainDisplay
    }
}

public struct RunTestRequest: Codable, Sendable {
    public let objective: String
    public let successCriteria: [String]?
    public let failureCriteria: [String]?
    public let provider: String?
    public let apiKey: String?
    public let model: String?
    public let maxSteps: Int?

    public init(objective: String, successCriteria: [String]? = nil, failureCriteria: [String]? = nil,
                provider: String? = nil, apiKey: String? = nil, model: String? = nil, maxSteps: Int? = nil) {
        self.objective = objective
        self.successCriteria = successCriteria
        self.failureCriteria = failureCriteria
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.maxSteps = maxSteps
    }
}

public struct ActionRequest: Codable, Sendable {
    public let action: String
    public let x: Double?
    public let y: Double?
    public let text: String?
    public let key: String?
    public let modifiers: [String]?
    public let deltaY: Int?
    public let deltaX: Int?
    public let fromX: Double?
    public let fromY: Double?
    public let toX: Double?
    public let toY: Double?
    public let seconds: Double?

    public init(action: String, x: Double? = nil, y: Double? = nil, text: String? = nil,
                key: String? = nil, modifiers: [String]? = nil, deltaY: Int? = nil, deltaX: Int? = nil,
                fromX: Double? = nil, fromY: Double? = nil, toX: Double? = nil, toY: Double? = nil,
                seconds: Double? = nil) {
        self.action = action
        self.x = x; self.y = y; self.text = text; self.key = key
        self.modifiers = modifiers
        self.deltaY = deltaY; self.deltaX = deltaX
        self.fromX = fromX; self.fromY = fromY; self.toX = toX; self.toY = toY
        self.seconds = seconds
    }
}

public struct ScreenshotRequest: Codable, Sendable {
    public let format: String?
    public init(format: String? = nil) { self.format = format }
}

// MARK: - Response Types

public struct SessionResponse: Codable, Sendable {
    public let sessionId: String
    public let displayID: UInt32
    public let appPID: Int32
    public let isRunning: Bool

    public init(sessionId: String, displayID: UInt32, appPID: Int32, isRunning: Bool) {
        self.sessionId = sessionId
        self.displayID = displayID
        self.appPID = appPID
        self.isRunning = isRunning
    }
}

public struct SessionInfoResponse: Codable, Sendable {
    public let sessionId: String
    public let displayID: UInt32
    public let appPID: Int32
    public let isRunning: Bool
    public let actionCount: Int

    public init(sessionId: String, displayID: UInt32, appPID: Int32, isRunning: Bool, actionCount: Int) {
        self.sessionId = sessionId
        self.displayID = displayID
        self.appPID = appPID
        self.isRunning = isRunning
        self.actionCount = actionCount
    }
}

public struct TestResultResponse: Codable, Sendable {
    public let sessionId: String
    public let success: Bool
    public let summary: String
    public let stepCount: Int
    public let duration: TimeInterval

    public init(sessionId: String, success: Bool, summary: String, stepCount: Int, duration: TimeInterval) {
        self.sessionId = sessionId
        self.success = success
        self.summary = summary
        self.stepCount = stepCount
        self.duration = duration
    }
}

public struct ScreenshotResponse: Codable, Sendable {
    public let sessionId: String
    public let width: Int
    public let height: Int
    public let format: String
    public let base64Data: String
    public let sizeKB: Int

    public init(sessionId: String, width: Int, height: Int, format: String, base64Data: String, sizeKB: Int) {
        self.sessionId = sessionId
        self.width = width
        self.height = height
        self.format = format
        self.base64Data = base64Data
        self.sizeKB = sizeKB
    }
}

public struct DisplayInfoResponse: Codable, Sendable {
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let isMain: Bool

    public init(displayID: UInt32, width: Int, height: Int, isMain: Bool) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

public struct PermissionsResponse: Codable, Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public let allGranted: Bool

    public init(screenRecording: Bool, accessibility: Bool, allGranted: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.allGranted = allGranted
    }
}

public struct TestProgressEvent: Codable, Sendable {
    public let sessionId: String
    public let step: Int
    public let totalSteps: Int
    public let action: String
    public let reasoning: String

    public init(sessionId: String, step: Int, totalSteps: Int, action: String, reasoning: String) {
        self.sessionId = sessionId
        self.step = step
        self.totalSteps = totalSteps
        self.action = action
        self.reasoning = reasoning
    }
}

public struct ErrorResponse: Codable, Sendable {
    public let error: String
    public let code: String

    public init(error: String, code: String) {
        self.error = error
        self.code = code
    }
}

public struct HealthResponse: Codable, Sendable {
    public let version: String
    public let status: String  // "healthy", "degraded", "unhealthy"
    public let uptime: TimeInterval
    public let activeSessions: Int
    public let permissions: PermissionsResponse
    public let virtualDisplayAvailable: Bool
    public let timestamp: String

    public init(version: String, status: String, uptime: TimeInterval,
                activeSessions: Int = 0, permissions: PermissionsResponse = .init(screenRecording: false, accessibility: false, allGranted: false),
                virtualDisplayAvailable: Bool = false, timestamp: String = "") {
        self.version = version
        self.status = status
        self.uptime = uptime
        self.activeSessions = activeSessions
        self.permissions = permissions
        self.virtualDisplayAvailable = virtualDisplayAvailable
        self.timestamp = timestamp
    }
}

// MARK: - Accessibility

public struct ElementSearchRequest: Codable, Sendable {
    public let role: String?
    public let label: String?
    public let identifier: String?

    public init(role: String? = nil, label: String? = nil, identifier: String? = nil) {
        self.role = role
        self.label = label
        self.identifier = identifier
    }
}

public struct ElementActionRequest: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let action: String  // "AXPress", "AXRaise", etc.

    public init(x: Double, y: Double, action: String = "AXPress") {
        self.x = x
        self.y = y
        self.action = action
    }
}

// MARK: - Errors

public enum ServerError: Error, LocalizedError {
    case sessionNotFound(String)
    case unknownAction(String)
    case invalidRequest(String)
    case missingApiKey

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "Session not found: \(id)"
        case .unknownAction(let action): return "Unknown action: \(action)"
        case .invalidRequest(let msg): return "Invalid request: \(msg)"
        case .missingApiKey: return "API key required. Set via request body, ANTHROPIC_API_KEY/OPENAI_API_KEY env var, or Keychain."
        }
    }

    public var code: String {
        switch self {
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .unknownAction: return "UNKNOWN_ACTION"
        case .invalidRequest: return "INVALID_REQUEST"
        case .missingApiKey: return "MISSING_API_KEY"
        }
    }
}
