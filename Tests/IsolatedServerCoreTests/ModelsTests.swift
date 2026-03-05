import XCTest
@testable import IsolatedServerCore

final class ModelsTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Request Codable Round-Trips

    func testCreateSessionRequestCodable() throws {
        let request = CreateSessionRequest(appPath: "/App.app", displayWidth: 1920, displayHeight: 1080, fallbackToMainDisplay: true)
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(CreateSessionRequest.self, from: data)
        XCTAssertEqual(decoded.appPath, "/App.app")
        XCTAssertEqual(decoded.displayWidth, 1920)
        XCTAssertEqual(decoded.displayHeight, 1080)
        XCTAssertEqual(decoded.fallbackToMainDisplay, true)
    }

    func testRunTestRequestCodable() throws {
        let request = RunTestRequest(
            objective: "Test login",
            successCriteria: ["Dashboard visible"],
            failureCriteria: ["Error shown"],
            provider: "anthropic",
            maxSteps: 30
        )
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(RunTestRequest.self, from: data)
        XCTAssertEqual(decoded.objective, "Test login")
        XCTAssertEqual(decoded.successCriteria, ["Dashboard visible"])
        XCTAssertEqual(decoded.failureCriteria, ["Error shown"])
        XCTAssertEqual(decoded.provider, "anthropic")
        XCTAssertEqual(decoded.maxSteps, 30)
    }

    func testActionRequestCodable() throws {
        let action = ActionRequest(action: "click", x: 100, y: 200)
        let data = try encoder.encode(action)
        let decoded = try decoder.decode(ActionRequest.self, from: data)
        XCTAssertEqual(decoded.action, "click")
        XCTAssertEqual(decoded.x, 100)
        XCTAssertEqual(decoded.y, 200)
    }

    func testActionRequestAllFields() throws {
        let action = ActionRequest(
            action: "drag",
            x: 1, y: 2, text: "hello", key: "a",
            modifiers: ["command", "shift"],
            deltaY: 10, deltaX: 5,
            fromX: 100, fromY: 200, toX: 300, toY: 400,
            seconds: 2.5
        )
        let data = try encoder.encode(action)
        let decoded = try decoder.decode(ActionRequest.self, from: data)
        XCTAssertEqual(decoded.action, "drag")
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.key, "a")
        XCTAssertEqual(decoded.modifiers, ["command", "shift"])
        XCTAssertEqual(decoded.fromX, 100)
        XCTAssertEqual(decoded.toY, 400)
        XCTAssertEqual(decoded.seconds, 2.5)
    }

    // MARK: - Response Codable Round-Trips

    func testSessionResponseCodable() throws {
        let response = SessionResponse(sessionId: "abc123", displayID: 1, appPID: 42, isRunning: true)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(SessionResponse.self, from: data)
        XCTAssertEqual(decoded.sessionId, "abc123")
        XCTAssertEqual(decoded.displayID, 1)
        XCTAssertEqual(decoded.appPID, 42)
        XCTAssertTrue(decoded.isRunning)
    }

    func testTestResultResponseCodable() throws {
        let response = TestResultResponse(sessionId: "abc", success: true, summary: "Passed", stepCount: 5, duration: 12.3)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(TestResultResponse.self, from: data)
        XCTAssertEqual(decoded.summary, "Passed")
        XCTAssertEqual(decoded.stepCount, 5)
        XCTAssertEqual(decoded.duration, 12.3, accuracy: 0.01)
    }

    func testScreenshotResponseCodable() throws {
        let response = ScreenshotResponse(sessionId: "abc", width: 1920, height: 1080, format: "png", base64Data: "abc123", sizeKB: 256)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(ScreenshotResponse.self, from: data)
        XCTAssertEqual(decoded.width, 1920)
        XCTAssertEqual(decoded.format, "png")
        XCTAssertEqual(decoded.base64Data, "abc123")
    }

    func testDisplayInfoResponseCodable() throws {
        let response = DisplayInfoResponse(displayID: 42, width: 3440, height: 1440, isMain: true)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(DisplayInfoResponse.self, from: data)
        XCTAssertEqual(decoded.displayID, 42)
        XCTAssertTrue(decoded.isMain)
    }

    func testPermissionsResponseCodable() throws {
        let response = PermissionsResponse(screenRecording: true, accessibility: false, allGranted: false)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(PermissionsResponse.self, from: data)
        XCTAssertTrue(decoded.screenRecording)
        XCTAssertFalse(decoded.accessibility)
        XCTAssertFalse(decoded.allGranted)
    }

    func testHealthResponseCodable() throws {
        let perms = PermissionsResponse(screenRecording: true, accessibility: true, allGranted: true)
        let response = HealthResponse(
            version: "1.0.0", status: "healthy", uptime: 42.5,
            activeSessions: 2, permissions: perms,
            virtualDisplayAvailable: true, timestamp: "2025-01-01T00:00:00Z"
        )
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(HealthResponse.self, from: data)
        XCTAssertEqual(decoded.version, "1.0.0")
        XCTAssertEqual(decoded.status, "healthy")
        XCTAssertEqual(decoded.activeSessions, 2)
        XCTAssertTrue(decoded.virtualDisplayAvailable)
    }

    func testErrorResponseCodable() throws {
        let response = ErrorResponse(error: "Something failed", code: "FAIL")
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(ErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error, "Something failed")
        XCTAssertEqual(decoded.code, "FAIL")
    }

    func testTestProgressEventCodable() throws {
        let event = TestProgressEvent(sessionId: "abc", step: 3, totalSteps: 10, action: "click", reasoning: "Button visible")
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(TestProgressEvent.self, from: data)
        XCTAssertEqual(decoded.step, 3)
        XCTAssertEqual(decoded.action, "click")
    }

    // MARK: - ServerError

    func testServerErrorDescriptions() {
        XCTAssertTrue(ServerError.sessionNotFound("abc").localizedDescription.contains("abc"))
        XCTAssertTrue(ServerError.unknownAction("fly").localizedDescription.contains("fly"))
        XCTAssertTrue(ServerError.invalidRequest("bad").localizedDescription.contains("bad"))
        XCTAssertTrue(ServerError.missingApiKey.localizedDescription.contains("API key"))
    }

    func testServerErrorCodes() {
        XCTAssertEqual(ServerError.sessionNotFound("abc").code, "SESSION_NOT_FOUND")
        XCTAssertEqual(ServerError.unknownAction("x").code, "UNKNOWN_ACTION")
        XCTAssertEqual(ServerError.invalidRequest("x").code, "INVALID_REQUEST")
        XCTAssertEqual(ServerError.missingApiKey.code, "MISSING_API_KEY")
    }

    // MARK: - Accessibility Models

    func testElementSearchRequestCodable() throws {
        let request = ElementSearchRequest(role: "AXButton", label: "OK")
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ElementSearchRequest.self, from: data)
        XCTAssertEqual(decoded.role, "AXButton")
        XCTAssertEqual(decoded.label, "OK")
    }

    func testElementActionRequestCodable() throws {
        let request = ElementActionRequest(x: 100, y: 200, action: "AXPress")
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ElementActionRequest.self, from: data)
        XCTAssertEqual(decoded.x, 100)
        XCTAssertEqual(decoded.action, "AXPress")
    }
}
