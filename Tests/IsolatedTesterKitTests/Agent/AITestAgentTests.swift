import XCTest
@testable import IsolatedTesterKit

final class AITestAgentTests: XCTestCase {

    // MARK: - extractJSON Tests

    func testExtractJSON_plainJSON() {
        let input = """
        {"reasoning": "test", "action": {"type": "click", "x": 100, "y": 200}}
        """
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
        // Verify it parses as valid JSON
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.utf8)))
    }

    func testExtractJSON_markdownFenced() {
        let input = """
        ```json
        {"reasoning": "clicking button", "action": {"type": "click", "x": 50, "y": 50}}
        ```
        """
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertTrue(result.contains("reasoning"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.utf8)))
    }

    func testExtractJSON_markdownFencedNoLang() {
        let input = """
        Here is my response:
        ```
        {"reasoning": "test", "action": {"type": "done", "success": true, "summary": "ok"}}
        ```
        """
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.utf8)))
    }

    func testExtractJSON_withSurroundingText() {
        let input = """
        I can see the calculator. Let me click the button.
        {"reasoning": "clicking 5", "action": {"type": "click", "x": 100, "y": 200}}
        That should work.
        """
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.utf8)))
    }

    func testExtractJSON_nestedBraces() {
        let input = """
        {"reasoning": "test", "action": {"type": "click", "x": 100, "y": 200}, "metadata": {"nested": true}}
        """
        let result = AITestAgent.extractJSON(from: input)
        let parsed = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertNotNil(parsed?["metadata"])
    }

    func testExtractJSON_noJSON() {
        let input = "I don't know what to do"
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertEqual(result, input)
    }

    func testExtractJSON_emptyInput() {
        let result = AITestAgent.extractJSON(from: "")
        XCTAssertEqual(result, "")
    }

    func testExtractJSON_whitespace() {
        let input = "  \n  {\"action\": {\"type\": \"wait\", \"seconds\": 1}}  \n  "
        let result = AITestAgent.extractJSON(from: input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(result.utf8)))
    }

    // MARK: - AgentAction Codable Tests

    func testAgentAction_clickRoundTrip() throws {
        let action = AITestAgent.AgentAction.click(x: 100.5, y: 200.3)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
        if case .click(let x, let y) = decoded {
            XCTAssertEqual(x, 100.5)
            XCTAssertEqual(y, 200.3)
        } else {
            XCTFail("Expected click action")
        }
    }

    func testAgentAction_typeRoundTrip() throws {
        let action = AITestAgent.AgentAction.type(text: "Hello World!")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
        if case .type(let text) = decoded {
            XCTAssertEqual(text, "Hello World!")
        } else {
            XCTFail("Expected type action")
        }
    }

    func testAgentAction_doneRoundTrip() throws {
        let action = AITestAgent.AgentAction.done(success: true, summary: "Test passed")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
        if case .done(let success, let summary) = decoded {
            XCTAssertTrue(success)
            XCTAssertEqual(summary, "Test passed")
        } else {
            XCTFail("Expected done action")
        }
    }

    func testAgentAction_scrollRoundTrip() throws {
        let action = AITestAgent.AgentAction.scroll(deltaY: -3, deltaX: 0)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
        if case .scroll(let dy, let dx) = decoded {
            XCTAssertEqual(dy, -3)
            XCTAssertEqual(dx, 0)
        } else {
            XCTFail("Expected scroll action")
        }
    }

    func testAgentAction_dragRoundTrip() throws {
        let action = AITestAgent.AgentAction.drag(fromX: 10, fromY: 20, toX: 30, toY: 40)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
        if case .drag(let fx, let fy, let tx, let ty) = decoded {
            XCTAssertEqual(fx, 10)
            XCTAssertEqual(fy, 20)
            XCTAssertEqual(tx, 30)
            XCTAssertEqual(ty, 40)
        } else {
            XCTFail("Expected drag action")
        }
    }

    func testAgentAction_allCasesEncode() throws {
        let cases: [AITestAgent.AgentAction] = [
            .click(x: 0, y: 0),
            .doubleClick(x: 0, y: 0),
            .type(text: ""),
            .keyPress(key: "return"),
            .scroll(deltaY: 0, deltaX: 0),
            .drag(fromX: 0, fromY: 0, toX: 0, toY: 0),
            .wait(seconds: 1.0),
            .done(success: false, summary: ""),
        ]
        for action in cases {
            let data = try JSONEncoder().encode(action)
            XCTAssertFalse(data.isEmpty, "Failed to encode: \(action)")
            let decoded = try JSONDecoder().decode(AITestAgent.AgentAction.self, from: data)
            XCTAssertNotNil(decoded)
        }
    }

    // MARK: - TestReport Codable Tests

    func testTestReport_roundTrip() throws {
        let report = AITestAgent.TestReport(
            objective: "Click button",
            success: true,
            summary: "Successfully clicked",
            stepCount: 3,
            duration: 5.5,
            steps: [
                .init(step: 0, action: .click(x: 100, y: 200), reasoning: "Clicking button"),
                .init(step: 1, action: .wait(seconds: 0.5), reasoning: "Waiting"),
                .init(step: 2, action: .done(success: true, summary: "Done"), reasoning: "Complete"),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(report)
        XCTAssertFalse(data.isEmpty)

        let decoded = try JSONDecoder().decode(AITestAgent.TestReport.self, from: data)
        XCTAssertEqual(decoded.objective, "Click button")
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.stepCount, 3)
        XCTAssertEqual(decoded.duration, 5.5)
        XCTAssertEqual(decoded.steps.count, 3)
    }

    // MARK: - AgentConfig Tests

    func testAgentConfig_defaultModel() {
        let anthropicConfig = AITestAgent.AgentConfig(provider: .anthropic, apiKey: "test")
        XCTAssertEqual(anthropicConfig.model, "claude-sonnet-4-20250514")

        let openaiConfig = AITestAgent.AgentConfig(provider: .openai, apiKey: "test")
        XCTAssertEqual(openaiConfig.model, "gpt-4o")
    }

    func testAgentConfig_customModel() {
        let config = AITestAgent.AgentConfig(provider: .anthropic, apiKey: "test", model: "custom-model")
        XCTAssertEqual(config.model, "custom-model")
    }

    func testAgentConfig_defaults() {
        let config = AITestAgent.AgentConfig(apiKey: "test")
        XCTAssertEqual(config.maxSteps, 25)
        XCTAssertEqual(config.actionDelay, 0.5)
    }
}
