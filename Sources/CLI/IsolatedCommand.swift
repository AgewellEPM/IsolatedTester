import ArgumentParser
import CoreGraphics
import Foundation
import IsolatedTesterKit

/// Unbuffered print that works when stdout is piped
func out(_ msg: String) {
    FileHandle.standardOutput.write(Data((msg + "\n").utf8))
}

// MARK: - Shared verbosity options

/// Shared `--verbose` / `--quiet` flags included in every subcommand via @OptionGroup.
/// Setting these updates ISTLogger.verbosity on the MainActor before the subcommand runs.
struct VerbosityOptions: ParsableArguments {
    @Flag(name: .long, help: "Enable verbose logging to stderr")
    var verbose: Bool = false

    @Flag(name: .long, help: "Suppress all logging to stderr")
    var quiet: Bool = false

    /// Apply the chosen verbosity to ISTLogger. Call this at the start of every subcommand.
    func apply() {
        if quiet {
            ISTLogger.verbosity = .quiet
        } else if verbose {
            ISTLogger.verbosity = .verbose
        } else {
            ISTLogger.verbosity = .normal
        }
    }
}

@main
struct Isolated: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isolated",
        abstract: "AI-powered isolated app testing for macOS",
        version: "0.1.0",
        subcommands: [
            ListDisplays.self,
            Screenshot.self,
            Launch.self,
            Test.self,
            Serve.self,
        ]
    )
}

// MARK: - List Displays

struct ListDisplays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "displays",
        abstract: "List all active displays"
    )

    @OptionGroup var verbosityOptions: VerbosityOptions

    func run() async throws {
        verbosityOptions.apply()

        let manager = VirtualDisplayManager()
        let displays = manager.getActiveDisplays()

        out("Active Displays:")
        for displayID in displays {
            let bounds = manager.displayBounds(for: displayID)
            let isMain = displayID == CGMainDisplayID() ? " (main)" : ""
            out("  [\(displayID)] \(Int(bounds.width))x\(Int(bounds.height))\(isMain)")
        }

        if manager.isVirtualDisplayAvailable {
            out("  Virtual display creation: available")
        } else {
            out("  Virtual display creation: not available")
        }
    }
}

// MARK: - Screenshot

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from a display"
    )

    @OptionGroup var verbosityOptions: VerbosityOptions

    @Option(name: .shortAndLong, help: "Display ID (0 = main display)")
    var display: UInt32 = 0

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "screenshot.png"

    @Option(name: .shortAndLong, help: "Format: png or jpeg")
    var format: String = "png"

    func run() async throws {
        verbosityOptions.apply()
        guard PermissionChecker.checkAndPrint() else { throw ExitCode.failure }

        let displayID = display == 0 ? CGMainDisplayID() : display
        let capture = ScreenCapture()
        let imageFormat: ScreenCapture.ImageFormat = format == "jpeg" ? .jpeg : .png

        let result = try await capture.capture(
            displayID: displayID,
            format: imageFormat
        )

        try capture.saveToDisk(result, path: output)
        out("Captured \(result.width)x\(result.height) \(format) (\(result.sizeKB)KB) → \(output)")
    }
}

// MARK: - Launch

/// Module-level storage so the SIGINT signal handler (a plain C function) can access
/// the launched app's PID and display ID for synchronous cleanup. These are written
/// once before the signal handler is installed and never mutated afterwards, so there
/// is no data-race concern.
private var _launchSessionAppPID: pid_t = 0
private var _launchSessionDisplayID: CGDirectDisplayID = 0
/// Semaphore used to unblock the async wait loop when SIGINT fires.
private let _launchSemaphore = DispatchSemaphore(value: 0)

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an app in a test session"
    )

    @OptionGroup var verbosityOptions: VerbosityOptions

    @Argument(help: "Path to .app bundle")
    var appPath: String

    @Option(name: .shortAndLong, help: "Display ID (0 = main display)")
    var display: UInt32 = 0

    func run() async throws {
        verbosityOptions.apply()
        guard PermissionChecker.checkAndPrint() else { throw ExitCode.failure }

        let appURL = URL(fileURLWithPath: appPath)
        guard FileManager.default.fileExists(atPath: appPath) else {
            out("Error: App not found at \(appPath)")
            throw ExitCode.failure
        }

        out("Launching \(appPath)...")
        let session = TestSession()

        let state = try await session.startOnMainDisplay(appURL: appURL)
        out("Session started: \(state.sessionID)")
        out("  Display: \(state.displayID)")
        out("  App PID: \(state.appPID ?? 0)")
        out("  Running: \(state.isRunning)")
        out("\nPress Ctrl+C to stop")

        // Store the session's identifiers in module-level variables so the C-style
        // signal handler below can reach them. Signal handlers cannot call async
        // code, so we do synchronous cleanup here and use a semaphore to wake the
        // async wait loop.
        _launchSessionAppPID = state.appPID ?? 0
        _launchSessionDisplayID = state.displayID

        signal(SIGINT) { _ in
            // Terminate the launched app directly via POSIX kill so the process is
            // not orphaned even if the Swift runtime is unwinding.
            if _launchSessionAppPID > 0 {
                kill(_launchSessionAppPID, SIGTERM)
            }
            // Signal the async loop to exit cleanly.
            _launchSemaphore.signal()
        }

        // Block the async context without spinning the CPU. The semaphore is
        // signalled by the SIGINT handler above.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _launchSemaphore.wait()
                continuation.resume()
            }
        }

        // Perform full async cleanup now that we are back in the async context.
        out("\nStopping session...")
        session.stop()
    }
}

// MARK: - AI Test

struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run an AI-powered test on an app"
    )

    @OptionGroup var verbosityOptions: VerbosityOptions

    @Argument(help: "Path to .app bundle")
    var appPath: String

    @Option(name: .shortAndLong, help: "Test objective description")
    var objective: String

    @Option(name: .long, help: "AI provider: anthropic or openai")
    var provider: String?

    @Option(name: .long, help: "AI model override")
    var model: String?

    @Option(name: .long, help: "API key (or set ANTHROPIC_API_KEY / OPENAI_API_KEY env var, or store in Keychain)")
    var apiKey: String?

    @Option(name: .long, help: "Maximum test steps")
    var maxSteps: Int?

    @Option(name: .long, help: "Output report path (directory or file)")
    var output: String?

    @Option(name: .long, help: "Report format: json, junit, or both")
    var format: String?

    @Option(name: .long, help: "Path to config file")
    var config: String?

    func run() async throws {
        verbosityOptions.apply()
        guard PermissionChecker.checkAndPrint() else { throw ExitCode.failure }

        // 1. Load config (file + CLI overrides)
        let baseConfig = (try? ConfigLoader.load(explicitPath: config)) ?? .default
        let mergedConfig = baseConfig.merging(
            provider: provider,
            model: model,
            apiKey: apiKey,
            maxSteps: maxSteps,
            screenshotFormat: nil,
            outputFormat: format,
            verbose: verbosityOptions.verbose,
            quiet: verbosityOptions.quiet
        )

        ISTLogger.debug("Config loaded: provider=\(mergedConfig.provider), maxSteps=\(mergedConfig.maxSteps)")

        let appURL = URL(fileURLWithPath: appPath)

        // 2. Resolve API key via unified resolver (CLI flag > env var > config file > Keychain)
        let resolvedProvider = mergedConfig.provider
        guard let resolvedKey = APIKeyResolver.resolve(
            provider: resolvedProvider,
            explicit: apiKey,
            config: mergedConfig
        ) else {
            ISTLogger.error("Error: No API key found. Options:")
            ISTLogger.error("  --api-key <key>")
            ISTLogger.error("  ANTHROPIC_API_KEY or OPENAI_API_KEY env var")
            ISTLogger.error("  .isolatedtester.yml config file (api_key field)")
            ISTLogger.error("  macOS Keychain (com.isolatedtester.apikeys)")
            throw ExitCode.failure
        }

        // 3. Start session
        let session = TestSession()
        ISTLogger.info("Starting test session...")
        let state = try await session.startOnMainDisplay(appURL: appURL)
        ISTLogger.info("Session \(state.sessionID) started (PID: \(state.appPID ?? 0))")

        // 4. Configure agent with config values
        let aiProvider: AITestAgent.AIProvider = resolvedProvider.lowercased() == "openai" ? .openai : .anthropic
        let screenshotFmt: ScreenCapture.ImageFormat = mergedConfig.screenshotFormat == "png" ? .png : .jpeg

        let agentConfig = AITestAgent.AgentConfig(
            provider: aiProvider,
            apiKey: resolvedKey,
            model: mergedConfig.model,
            maxSteps: mergedConfig.maxSteps,
            actionDelay: mergedConfig.actionDelay,
            screenshotFormat: screenshotFmt
        )

        let agent = AITestAgent(session: session, config: agentConfig)

        let testObjective = AITestAgent.TestObjective(
            description: objective
        )

        // 5. Run test
        ISTLogger.info("Running test: \(objective)")
        ISTLogger.info("Provider: \(resolvedProvider) | Max steps: \(mergedConfig.maxSteps)")
        ISTLogger.info("---")

        let report = try await agent.runTest(objective: testObjective)

        // 6. Output results to console
        out("\n=== TEST REPORT ===")
        out("Objective: \(report.objective)")
        out("Result: \(report.success ? "PASS" : "FAIL")")
        out("Summary: \(report.summary)")
        out("Steps: \(report.stepCount)")
        out("Duration: \(String(format: "%.1f", report.duration))s")

        // 7. Save report using TestReporter with proper formatting
        let outputPath = output ?? mergedConfig.output.path
        let outputFormat = format ?? mergedConfig.output.format

        if output != nil || format != nil {
            let reportData = TestReportData(
                sessionId: state.sessionID,
                objective: report.objective,
                success: report.success,
                summary: report.summary,
                stepCount: report.stepCount,
                duration: report.duration,
                steps: report.steps.map { step in
                    TestReportData.StepData(
                        step: step.step,
                        action: String(describing: step.action),
                        reasoning: step.reasoning,
                        timestamp: nil
                    )
                },
                appPath: appPath,
                provider: resolvedProvider,
                model: mergedConfig.model,
                screenshotFormat: mergedConfig.screenshotFormat
            )

            let outputConfig = OutputConfiguration(
                format: outputFormat,
                path: outputPath,
                saveScreenshots: mergedConfig.output.saveScreenshots,
                screenshotDir: mergedConfig.output.screenshotDir
            )
            let reporter = TestReporter.fromConfig(outputConfig)

            do {
                let savedFiles = try reporter.save(report: reportData)
                for file in savedFiles {
                    ISTLogger.info("Report saved: \(file.path)")
                }
            } catch {
                ISTLogger.error("Failed to save report: \(error.localizedDescription)")
            }
        }

        // 8. Cleanup
        session.stop()

        // Exit with appropriate code
        if !report.success {
            throw ExitCode(1)
        }
    }
}
