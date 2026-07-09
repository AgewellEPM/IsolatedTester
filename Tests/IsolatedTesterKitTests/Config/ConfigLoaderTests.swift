import XCTest
@testable import IsolatedTesterKit

final class ConfigLoaderTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = Configuration.default
        XCTAssertEqual(config.provider, "anthropic")
        XCTAssertNil(config.model)
        XCTAssertEqual(config.maxSteps, 25)
        XCTAssertEqual(config.actionDelay, 0.5)
        XCTAssertEqual(config.screenshotFormat, "jpeg")
        XCTAssertEqual(config.display.width, 1920)
        XCTAssertEqual(config.display.height, 1080)
        XCTAssertEqual(config.display.ppi, 144)
        XCTAssertTrue(config.display.useVirtual)
        XCTAssertTrue(config.display.fallbackToMain)
    }

    func testMergingOverridesProvider() {
        let base = Configuration.default
        let merged = base.merging(provider: "openai")
        XCTAssertEqual(merged.provider, "openai")
        XCTAssertEqual(merged.maxSteps, 25)  // Unchanged
    }

    func testMergingOverridesMultiple() {
        let base = Configuration.default
        let merged = base.merging(provider: "openai", maxSteps: 50, screenshotFormat: "png")
        XCTAssertEqual(merged.provider, "openai")
        XCTAssertEqual(merged.maxSteps, 50)
        XCTAssertEqual(merged.screenshotFormat, "png")
    }

    func testMergingNilDoesNotOverride() {
        let base = Configuration.default
        let merged = base.merging(provider: nil, model: nil)
        XCTAssertEqual(merged.provider, "anthropic")
        XCTAssertNil(merged.model)
    }

    func testMergingVerbose() {
        let merged = Configuration.default.merging(verbose: true)
        XCTAssertEqual(merged.logging.level, "debug")
    }

    func testMergingQuiet() {
        let merged = Configuration.default.merging(quiet: true)
        XCTAssertEqual(merged.logging.level, "error")
    }

    func testLoadFromJSONFile() throws {
        let tmpDir = NSTemporaryDirectory()
        let configPath = tmpDir + "test-config-\(UUID().uuidString).json"
        let json = """
        {
            "provider": "openai",
            "maxSteps": 50,
            "actionDelay": 1.0,
            "screenshotFormat": "png",
            "display": {"width": 1280, "height": 720, "ppi": 72, "useVirtual": false, "fallbackToMain": true},
            "retry": {"maxRetries": 5, "retryDelay": 2.0, "screenshotRetries": 2, "backoffMultiplier": 3.0, "maxDelay": 60.0},
            "timeouts": {"apiCall": 30, "appLaunch": 5, "sessionTotal": 300},
            "output": {"format": "junit", "path": "./out/", "saveScreenshots": true, "screenshotDir": "./imgs/"},
            "logging": {"level": "debug"}
        }
        """
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let config = try ConfigLoader.load(explicitPath: configPath)
        XCTAssertEqual(config.provider, "openai")
        XCTAssertEqual(config.maxSteps, 50)
        XCTAssertEqual(config.display.width, 1280)
        XCTAssertEqual(config.retry.maxRetries, 5)
        XCTAssertEqual(config.timeouts.apiCall, 30)
        XCTAssertEqual(config.output.format, "junit")
        XCTAssertEqual(config.logging.level, "debug")
    }

    func testLoadDefaultsWhenNoFile() throws {
        let config = try ConfigLoader.load()
        XCTAssertEqual(config.provider, "anthropic")
    }

    // MARK: - Config Validation

    func testValidConfigPasses() throws {
        let config = Configuration.default
        XCTAssertNoThrow(try config.validate())
    }

    func testInvalidProvider() {
        var config = Configuration.default
        config.provider = "gemini"
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidMaxSteps() {
        var config = Configuration.default
        config.maxSteps = 0
        XCTAssertThrowsError(try config.validate())
    }

    func testMaxStepsTooHigh() {
        var config = Configuration.default
        config.maxSteps = 501
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidActionDelay() {
        var config = Configuration.default
        config.actionDelay = -1
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidScreenshotFormat() {
        var config = Configuration.default
        config.screenshotFormat = "bmp"
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidDisplayWidth() {
        var config = Configuration.default
        config.display.width = 100
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidDisplayPPI() {
        var config = Configuration.default
        config.display.ppi = 10
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidRetryMaxRetries() {
        var config = Configuration.default
        config.retry.maxRetries = -1
        XCTAssertThrowsError(try config.validate())
    }

    func testInvalidTimeout() {
        var config = Configuration.default
        config.timeouts.apiCall = 0
        XCTAssertThrowsError(try config.validate())
    }

    func testAllValidProviders() throws {
        for provider in ["anthropic", "openai", "claude-code", "claudecode"] {
            var config = Configuration.default
            config.provider = provider
            XCTAssertNoThrow(try config.validate(), "Provider '\(provider)' should be valid")
        }
    }
}
