import XCTest
@testable import IsolatedServerCore

final class ValidationTests: XCTestCase {

    // MARK: - CreateSessionRequest Validation

    // Use an app that exists on every macOS system
    private var existingAppPath: String {
        // Safari.app exists on every Mac
        "/System/Applications/Utilities/Terminal.app"
    }

    func testValidCreateSession() throws {
        let request = CreateSessionRequest(
            appPath: existingAppPath,
            displayWidth: 1920,
            displayHeight: 1080
        )
        XCTAssertNoThrow(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionExceedsMaxSessions() {
        let request = CreateSessionRequest(appPath: existingAppPath)
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 50)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Maximum active sessions"))
        }
    }

    func testCreateSessionInvalidDisplayWidth() {
        let request = CreateSessionRequest(appPath: existingAppPath, displayWidth: 100)
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionDisplayWidthTooLarge() {
        let request = CreateSessionRequest(appPath: existingAppPath, displayWidth: 10000)
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionInvalidDisplayHeight() {
        let request = CreateSessionRequest(appPath: existingAppPath, displayHeight: 50)
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionEmptyAppPath() {
        let request = CreateSessionRequest(appPath: "")
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionNonAppPath() {
        let request = CreateSessionRequest(appPath: "/usr/bin/ls")
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".app"))
        }
    }

    func testCreateSessionPathTraversal() {
        let request = CreateSessionRequest(appPath: "/Applications/../etc/passwd.app")
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    func testCreateSessionPathTooLong() {
        let longPath = "/Applications/" + String(repeating: "a", count: 1100) + ".app"
        let request = CreateSessionRequest(appPath: longPath)
        XCTAssertThrowsError(try RequestValidator.validate(request, activeSessionCount: 0))
    }

    // MARK: - RunTestRequest Validation

    func testValidRunTest() throws {
        let request = RunTestRequest(objective: "Test something", maxSteps: 10)
        XCTAssertNoThrow(try RequestValidator.validate(request))
    }

    func testRunTestEmptyObjective() {
        let request = RunTestRequest(objective: "")
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestWhitespaceOnlyObjective() {
        let request = RunTestRequest(objective: "   \n\t  ")
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestObjectiveTooLong() {
        let request = RunTestRequest(objective: String(repeating: "x", count: 10_001))
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestMaxStepsTooLow() {
        let request = RunTestRequest(objective: "Test", maxSteps: 0)
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestMaxStepsTooHigh() {
        let request = RunTestRequest(objective: "Test", maxSteps: 501)
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestInvalidProvider() {
        let request = RunTestRequest(objective: "Test", provider: "gemini")
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestValidProviders() throws {
        for provider in ["anthropic", "openai", "claude-code", "claudecode"] {
            let request = RunTestRequest(objective: "Test", provider: provider)
            XCTAssertNoThrow(try RequestValidator.validate(request))
        }
    }

    func testRunTestTooManyCriteria() {
        let criteria = (0..<51).map { "Criterion \($0)" }
        let request = RunTestRequest(objective: "Test", successCriteria: criteria)
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    func testRunTestCriterionTooLong() {
        let longCriterion = String(repeating: "x", count: 2001)
        let request = RunTestRequest(objective: "Test", successCriteria: [longCriterion])
        XCTAssertThrowsError(try RequestValidator.validate(request))
    }

    // MARK: - ActionRequest Validation

    func testValidClickAction() throws {
        let action = ActionRequest(action: "click", x: 100, y: 200)
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testClickMissingCoordinates() {
        let action = ActionRequest(action: "click")
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testClickNegativeX() {
        let action = ActionRequest(action: "click", x: -1, y: 100)
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testClickXTooLarge() {
        let action = ActionRequest(action: "click", x: 10_001, y: 100)
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testValidTypeAction() throws {
        let action = ActionRequest(action: "type", text: "Hello")
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testTypeMissingText() {
        let action = ActionRequest(action: "type")
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testTypeTextTooLong() {
        let action = ActionRequest(action: "type", text: String(repeating: "x", count: 50_001))
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testKeyPressMissingKey() {
        let action = ActionRequest(action: "keyPress")
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testValidKeyPress() throws {
        let action = ActionRequest(action: "keyPress", key: "return")
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testDragMissingCoordinates() {
        let action = ActionRequest(action: "drag", fromX: 0, fromY: 0)
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testValidDrag() throws {
        let action = ActionRequest(action: "drag", fromX: 10, fromY: 20, toX: 30, toY: 40)
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testScrollDeltaTooLarge() {
        let action = ActionRequest(action: "scroll", deltaY: 10_001)
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testWaitTooLong() {
        let action = ActionRequest(action: "wait", seconds: 301)
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testValidWait() throws {
        let action = ActionRequest(action: "wait", seconds: 5)
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testUnknownAction() {
        let action = ActionRequest(action: "explode")
        XCTAssertThrowsError(try RequestValidator.validate(action))
    }

    func testAllValidActions() throws {
        let actions = ["click", "doubleClick", "type", "keyPress", "scroll", "drag", "wait"]
        for actionName in actions {
            // Just test that valid action names are accepted (even without required params)
            let action: ActionRequest
            switch actionName {
            case "click", "doubleClick": action = ActionRequest(action: actionName, x: 0, y: 0)
            case "type": action = ActionRequest(action: actionName, text: "x")
            case "keyPress": action = ActionRequest(action: actionName, key: "a")
            case "drag": action = ActionRequest(action: actionName, fromX: 0, fromY: 0, toX: 1, toY: 1)
            default: action = ActionRequest(action: actionName)
            }
            XCTAssertNoThrow(try RequestValidator.validate(action), "Action '\(actionName)' should be valid")
        }
    }

    // MARK: - Session ID Validation

    func testValidSessionId() throws {
        XCTAssertNoThrow(try RequestValidator.validateSessionId("a1b2c3d4"))
    }

    func testSessionIdTooShort() {
        XCTAssertThrowsError(try RequestValidator.validateSessionId("ab"))
    }

    func testSessionIdInvalidChars() {
        XCTAssertThrowsError(try RequestValidator.validateSessionId("ZZZZZZZZ"))
    }

    func testSessionIdWithDashes() throws {
        XCTAssertNoThrow(try RequestValidator.validateSessionId("a1b2-c3d4"))
    }

    // MARK: - Limits Constants

    func testLimitsAreReasonable() {
        XCTAssertEqual(RequestValidator.maxActiveSessions, 50)
        XCTAssertEqual(RequestValidator.maxStepsLimit, 500)
        XCTAssertEqual(RequestValidator.maxObjectiveLength, 10_000)
        XCTAssertEqual(RequestValidator.maxTextLength, 50_000)
        XCTAssertEqual(RequestValidator.maxAppPathLength, 1024)
        XCTAssertEqual(RequestValidator.maxDisplayDimension, 7680)
        XCTAssertEqual(RequestValidator.minDisplayDimension, 320)
    }
}
