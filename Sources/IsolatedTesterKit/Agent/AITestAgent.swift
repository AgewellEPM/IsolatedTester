import CoreGraphics
import Foundation

/// AI-powered test agent that uses vision models to understand UI state
/// and decide which actions to take. The agent loop:
///   screenshot → send to LLM → get action → execute → repeat
public final class AITestAgent: @unchecked Sendable {

    public struct AgentConfig: Sendable {
        public let provider: AIProvider
        public let apiKey: String
        public let model: String
        public let maxSteps: Int
        public let actionDelay: Double // seconds between actions
        public let screenshotFormat: ScreenCapture.ImageFormat

        public init(
            provider: AIProvider = .anthropic,
            apiKey: String,
            model: String? = nil,
            maxSteps: Int = 25,
            actionDelay: Double = 0.5,
            screenshotFormat: ScreenCapture.ImageFormat = .jpeg
        ) {
            self.provider = provider
            self.apiKey = apiKey
            self.model = model ?? (provider == .openai ? "gpt-4o" : "claude-sonnet-4-20250514")
            self.maxSteps = maxSteps
            self.actionDelay = actionDelay
            self.screenshotFormat = screenshotFormat
        }
    }

    public enum AIProvider: String, Sendable, Codable {
        case anthropic
        case openai
    }

    public struct TestObjective: Sendable {
        public let description: String
        public let successCriteria: [String]
        public let failureCriteria: [String]

        public init(
            description: String,
            successCriteria: [String] = [],
            failureCriteria: [String] = []
        ) {
            self.description = description
            self.successCriteria = successCriteria
            self.failureCriteria = failureCriteria
        }
    }

    public enum AgentAction: Sendable, Codable {
        case click(x: Double, y: Double)
        case doubleClick(x: Double, y: Double)
        case type(text: String)
        case keyPress(key: String)
        case scroll(deltaY: Int, deltaX: Int)
        case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
        case wait(seconds: Double)
        case done(success: Bool, summary: String)
    }

    public struct StepResult: Sendable {
        public let step: Int
        public let action: AgentAction
        public let reasoning: String
        public let screenshotData: Data?
        public let timestamp: Date
    }

    public struct TestReport: Sendable, Codable {
        public let objective: String
        public let success: Bool
        public let summary: String
        public let stepCount: Int
        public let duration: TimeInterval
        public let steps: [StepDetail]

        public struct StepDetail: Sendable, Codable {
            public let step: Int
            public let action: AgentAction
            public let reasoning: String
        }
    }

    private let config: AgentConfig
    private let session: TestSession
    private var overlay: AIOverlayWindow?

    public init(session: TestSession, config: AgentConfig) {
        self.session = session
        self.config = config
    }

    // MARK: - Run Test

    /// Execute a test objective using the AI agent loop.
    public func runTest(objective: TestObjective) async throws -> TestReport {
        let startTime = Date()
        var steps: [StepResult] = []
        var consecutiveErrors = 0
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            initialDelay: 0.5,
            backoffMultiplier: 2.0,
            maxDelay: 5.0
        )

        // Show AI control overlay around the target app
        if let pid = session.state.appPID {
            let overlayWindow = AIOverlayWindow(
                targetPID: pid,
                displayID: session.state.displayID
            )
            self.overlay = overlayWindow
            await MainActor.run { overlayWindow.show() }
        }

        defer {
            // Hide overlay when test completes
            if let overlayWindow = overlay {
                Task { @MainActor in overlayWindow.hide() }
                self.overlay = nil
            }
        }

        for stepIndex in 0..<config.maxSteps {
            // 1. Capture current state with retry
            ISTLogger.agent.info("Step \(stepIndex): capturing screenshot")
            ISTLogger.debug("[step \(stepIndex + 1)/\(config.maxSteps)] Capturing screenshot...")
            let screenshot: ScreenCapture.CaptureResult
            do {
                screenshot = try await retryPolicy.execute {
                    try await session.screenshot(format: config.screenshotFormat)
                }
            } catch {
                consecutiveErrors += 1
                ISTLogger.agent.warning("Screenshot capture failed after retries: \(error.localizedDescription)")
                if consecutiveErrors >= retryPolicy.maxAttempts {
                    return TestReport(
                        objective: objective.description,
                        success: false,
                        summary: "Screenshot capture failed repeatedly: \(error.localizedDescription)",
                        stepCount: stepIndex,
                        duration: Date().timeIntervalSince(startTime),
                        steps: steps.map { .init(step: $0.step, action: $0.action, reasoning: $0.reasoning) }
                    )
                }
                continue
            }

            // 2. Ask AI what to do next (with exponential backoff retry)
            var action: AgentAction?
            var reasoning = ""
            do {
                let result = try await retryPolicy.execute {
                    try await self.decideNextAction(
                        objective: objective,
                        screenshot: screenshot.imageData,
                        previousSteps: steps
                    )
                }
                action = result.0
                reasoning = result.1
                ISTLogger.agent.debug("AI reasoning: \(result.1)")
            } catch {
                reasoning = "AI decision failed after retries: \(error.localizedDescription)"
                action = .wait(seconds: 1.0)
            }

            guard let resolvedAction = action else { continue }
            consecutiveErrors = 0

            steps.append(StepResult(
                step: stepIndex,
                action: resolvedAction,
                reasoning: reasoning,
                screenshotData: screenshot.imageData,
                timestamp: Date()
            ))

            // 3. Check if done
            if case .done(let success, let summary) = resolvedAction {
                return TestReport(
                    objective: objective.description,
                    success: success,
                    summary: summary,
                    stepCount: stepIndex + 1,
                    duration: Date().timeIntervalSince(startTime),
                    steps: steps.map { .init(step: $0.step, action: $0.action, reasoning: $0.reasoning) }
                )
            }

            // 4. Execute the action (with error tolerance)
            ISTLogger.agent.info("Executing: \(String(describing: resolvedAction))")
            ISTLogger.info("[step \(stepIndex + 1)] \(describeAction(resolvedAction))")

            // Update overlay label with current step info
            if let overlayWindow = overlay {
                let stepLabel = "AI STEP \(stepIndex + 1)/\(config.maxSteps)"
                await MainActor.run {
                    overlayWindow.updateLabel(stepLabel)
                    overlayWindow.flash()
                }
            }

            do {
                try await executeAction(resolvedAction)
            } catch {
                // Log but don't crash — the AI will see the unchanged state and adapt
                reasoning += " [action failed: \(error.localizedDescription)]"
            }

            // 5. Wait for UI to settle
            await session.wait(seconds: config.actionDelay)
        }

        // Hit max steps without completing
        return TestReport(
            objective: objective.description,
            success: false,
            summary: "Reached maximum step limit (\(config.maxSteps)) without completing objective",
            stepCount: config.maxSteps,
            duration: Date().timeIntervalSince(startTime),
            steps: steps.map { .init(step: $0.step, action: $0.action, reasoning: $0.reasoning) }
        )
    }

    // MARK: - AI Decision Making

    private func decideNextAction(
        objective: TestObjective,
        screenshot: Data,
        previousSteps: [StepResult]
    ) async throws -> (AgentAction, String) {
        let systemPrompt = buildSystemPrompt(objective: objective)
        let history = buildHistory(previousSteps)

        switch config.provider {
        case .anthropic:
            return try await callAnthropic(
                system: systemPrompt,
                history: history,
                screenshot: screenshot
            )
        case .openai:
            return try await callOpenAI(
                system: systemPrompt,
                history: history,
                screenshot: screenshot
            )
        }
    }

    private func buildSystemPrompt(objective: TestObjective) -> String {
        """
        You are an AI test agent controlling a macOS application through an isolated virtual display.

        OBJECTIVE: \(objective.description)

        SUCCESS CRITERIA:
        \(objective.successCriteria.map { "- \($0)" }.joined(separator: "\n"))

        FAILURE CRITERIA:
        \(objective.failureCriteria.map { "- \($0)" }.joined(separator: "\n"))

        You can see the current state of the application as a screenshot.

        Respond with a JSON object containing:
        - "reasoning": Brief explanation of what you see and why you're choosing this action
        - "action": One of the following:
          - {"type": "click", "x": <number>, "y": <number>}
          - {"type": "doubleClick", "x": <number>, "y": <number>}
          - {"type": "type", "text": "<string>"}
          - {"type": "keyPress", "key": "return|tab|escape|space|delete|up|down|left|right|cmd+<key>"}
          - {"type": "scroll", "deltaY": <int>, "deltaX": <int>}
          - {"type": "drag", "fromX": <number>, "fromY": <number>, "toX": <number>, "toY": <number>}
          - {"type": "wait", "seconds": <number>}
          - {"type": "done", "success": <bool>, "summary": "<string>"}

        Use "done" when the objective is achieved or when you've determined it cannot be achieved.

        Respond ONLY with valid JSON. No markdown, no explanation outside the JSON.
        """
    }

    private func buildHistory(_ steps: [StepResult]) -> String {
        steps.map { step in
            "Step \(step.step): \(step.reasoning) → \(step.action)"
        }.joined(separator: "\n")
    }

    // MARK: - API Calls

    private var mediaType: String {
        config.screenshotFormat == .jpeg ? "image/jpeg" : "image/png"
    }

    private func callAnthropic(
        system: String,
        history: String,
        screenshot: Data
    ) async throws -> (AgentAction, String) {
        let base64Image = screenshot.base64EncodedString()

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "system": system,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": history.isEmpty
                                ? "This is the current state. What should I do first?"
                                : "Previous actions:\n\(history)\n\nThis is the current state. What should I do next?"
                        ]
                    ]
                ]
            ]
        ]

        let request = try buildRequest(
            url: "https://api.anthropic.com/v1/messages",
            body: body,
            headers: [
                "x-api-key": config.apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ]
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseAIResponse(data, provider: .anthropic)
    }

    private func callOpenAI(
        system: String,
        history: String,
        screenshot: Data
    ) async throws -> (AgentAction, String) {
        let base64Image = screenshot.base64EncodedString()

        let body: [String: Any] = [
            "model": config.model,
            "max_completion_tokens": 1024,
            "messages": [
                ["role": "system", "content": system],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:\(mediaType);base64,\(base64Image)"]
                        ],
                        [
                            "type": "text",
                            "text": history.isEmpty
                                ? "This is the current state. What should I do first?"
                                : "Previous actions:\n\(history)\n\nCurrent state. What next?"
                        ]
                    ]
                ]
            ]
        ]

        let request = try buildRequest(
            url: "https://api.openai.com/v1/chat/completions",
            body: body,
            headers: [
                "Authorization": "Bearer \(config.apiKey)",
                "Content-Type": "application/json"
            ]
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseAIResponse(data, provider: .openai)
    }

    // MARK: - Parsing

    private func buildRequest(url: String, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        guard let requestURL = URL(string: url) else {
            throw AgentError.apiError("Invalid URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func parseAIResponse(_ data: Data, provider: AIProvider) throws -> (AgentAction, String) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.invalidResponse("Not valid JSON: \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        }

        // Check for API errors first (both providers return {"error": {...}})
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown API error"
            let type = error["type"] as? String ?? ""
            throw AgentError.apiError("\(type): \(msg)")
        }

        // Extract text content based on provider
        let text: String
        switch provider {
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let t = first["text"] as? String else {
                throw AgentError.invalidResponse("Missing content in Anthropic response: \(json.keys.joined(separator: ", "))")
            }
            text = t
        case .openai:
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let t = message["content"] as? String else {
                throw AgentError.invalidResponse("Missing content in OpenAI response: \(json.keys.joined(separator: ", "))")
            }
            text = t
        }

        // Parse the JSON action from the AI's response, stripping markdown fences if present
        let cleanedText = Self.extractJSON(from: text)
        guard let actionData = cleanedText.data(using: .utf8),
              let actionJSON = try JSONSerialization.jsonObject(with: actionData) as? [String: Any] else {
            throw AgentError.invalidResponse("AI response is not valid JSON: \(text)")
        }

        let reasoning = actionJSON["reasoning"] as? String ?? ""
        guard let actionObj = actionJSON["action"] as? [String: Any],
              let actionType = actionObj["type"] as? String else {
            throw AgentError.invalidResponse("Missing action in AI response")
        }

        let action: AgentAction = switch actionType {
        case "click":
            .click(x: actionObj["x"] as? Double ?? 0, y: actionObj["y"] as? Double ?? 0)
        case "doubleClick":
            .doubleClick(x: actionObj["x"] as? Double ?? 0, y: actionObj["y"] as? Double ?? 0)
        case "type":
            .type(text: actionObj["text"] as? String ?? "")
        case "keyPress":
            .keyPress(key: actionObj["key"] as? String ?? "")
        case "scroll":
            .scroll(deltaY: actionObj["deltaY"] as? Int ?? 0, deltaX: actionObj["deltaX"] as? Int ?? 0)
        case "drag":
            .drag(
                fromX: actionObj["fromX"] as? Double ?? 0,
                fromY: actionObj["fromY"] as? Double ?? 0,
                toX: actionObj["toX"] as? Double ?? 0,
                toY: actionObj["toY"] as? Double ?? 0
            )
        case "wait":
            .wait(seconds: actionObj["seconds"] as? Double ?? 1.0)
        case "done":
            .done(
                success: actionObj["success"] as? Bool ?? false,
                summary: actionObj["summary"] as? String ?? ""
            )
        default:
            throw AgentError.invalidResponse("Unknown action type: \(actionType)")
        }

        return (action, reasoning)
    }

    // MARK: - Action Execution

    private func executeAction(_ action: AgentAction) async throws {
        switch action {
        case .click(let x, let y):
            try session.click(x: x, y: y)
        case .doubleClick(let x, let y):
            try session.doubleClick(x: x, y: y)
        case .type(let text):
            try session.type(text)
        case .keyPress(let key):
            let keyCode = resolveKeyCode(key)
            let modifiers = resolveModifiers(key)
            try session.keyPress(keyCode, modifiers: modifiers)
        case .scroll(let deltaY, let deltaX):
            try session.scroll(deltaY: Int32(deltaY), deltaX: Int32(deltaX))
        case .drag(let fx, let fy, let tx, let ty):
            try session.drag(fromX: fx, fromY: fy, toX: tx, toY: ty)
        case .wait(let seconds):
            await session.wait(seconds: seconds)
        case .done:
            break // Handled in run loop
        }
    }

    private func resolveKeyCode(_ key: String) -> CGKeyCode {
        let baseKey = key.replacingOccurrences(of: "cmd+", with: "")
            .replacingOccurrences(of: "shift+", with: "")
            .replacingOccurrences(of: "alt+", with: "")
            .replacingOccurrences(of: "ctrl+", with: "")

        if let code = InputController.KeyCode.fromString(baseKey) {
            return code
        }

        // Fallback: return 0 for truly unknown keys
        ISTLogger.agent.warning("Unknown key code: \(baseKey), defaulting to 0")
        return 0
    }

    private func resolveModifiers(_ key: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        if key.contains("cmd+") { flags.insert(.maskCommand) }
        if key.contains("shift+") { flags.insert(.maskShift) }
        if key.contains("alt+") { flags.insert(.maskAlternate) }
        if key.contains("ctrl+") { flags.insert(.maskControl) }
        return flags
    }

    // MARK: - JSON Extraction

    /// Extract JSON from LLM responses that may include markdown fences or commentary.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract from ```json ... ``` or ``` ... ``` blocks
        if let fenceRange = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let afterFence = trimmed[fenceRange.upperBound...]
            if let closingFence = afterFence.range(of: "```") {
                return String(afterFence[afterFence.startIndex..<closingFence.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Try to find the first { ... } block (outermost braces)
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace < lastBrace {
            return String(trimmed[firstBrace...lastBrace])
        }

        // Return as-is and let the caller handle the error
        return trimmed
    }

    /// Human-readable action description for console logging.
    private func describeAction(_ action: AgentAction) -> String {
        switch action {
        case .click(let x, let y): return "Click at (\(Int(x)), \(Int(y)))"
        case .doubleClick(let x, let y): return "Double-click at (\(Int(x)), \(Int(y)))"
        case .type(let text): return "Type: \"\(text.prefix(50))\""
        case .keyPress(let key): return "Key press: \(key)"
        case .scroll(let dy, let dx): return "Scroll dy=\(dy) dx=\(dx)"
        case .drag(let fx, let fy, let tx, let ty): return "Drag (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty)))"
        case .wait(let s): return "Wait \(s)s"
        case .done(let success, let summary): return "Done: \(success ? "PASS" : "FAIL") - \(summary.prefix(80))"
        }
    }
}

// MARK: - Errors

public enum AgentError: Error, LocalizedError {
    case invalidResponse(String)
    case apiError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return "Invalid AI response: \(msg)"
        case .apiError(let msg): return "API error: \(msg)"
        case .timeout: return "Agent timed out"
        }
    }
}
