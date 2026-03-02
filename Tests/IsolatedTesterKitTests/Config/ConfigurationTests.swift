import XCTest
@testable import IsolatedTesterKit

final class ConfigurationTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = Configuration.default
        XCTAssertEqual(config.provider, "anthropic")
        XCTAssertNil(config.model)
        XCTAssertEqual(config.maxSteps, 25)
        XCTAssertEqual(config.actionDelay, 0.5)
        XCTAssertEqual(config.screenshotFormat, "jpeg")
    }

    func testConfiguration_displayDefaults() {
        let config = Configuration.default
        XCTAssertEqual(config.display.width, 1920)
        XCTAssertEqual(config.display.height, 1080)
        XCTAssertEqual(config.display.ppi, 144)
        XCTAssertTrue(config.display.useVirtual)
        XCTAssertTrue(config.display.fallbackToMain)
    }

    func testConfiguration_retryDefaults() {
        let config = Configuration.default
        XCTAssertEqual(config.retry.maxRetries, 3)
        XCTAssertEqual(config.retry.retryDelay, 1.0)
        XCTAssertEqual(config.retry.backoffMultiplier, 2.0)
    }

    func testConfiguration_merging() {
        let config = Configuration.default
        let merged = config.merging(provider: "openai", maxSteps: 50, verbose: true)
        XCTAssertEqual(merged.provider, "openai")
        XCTAssertEqual(merged.maxSteps, 50)
        XCTAssertEqual(merged.logging.level, "debug")
        // Unchanged values
        XCTAssertEqual(merged.actionDelay, 0.5)
        XCTAssertEqual(merged.screenshotFormat, "jpeg")
    }

    func testConfiguration_mergingQuiet() {
        let config = Configuration.default
        let merged = config.merging(quiet: true)
        XCTAssertEqual(merged.logging.level, "error")
    }

    func testConfiguration_codable() throws {
        let config = Configuration(provider: "openai", model: "gpt-4o", maxSteps: 10)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(decoded.provider, "openai")
        XCTAssertEqual(decoded.model, "gpt-4o")
        XCTAssertEqual(decoded.maxSteps, 10)
    }

    func testConfigLoader_defaultsWhenNoFile() throws {
        // When no config file exists, should return defaults
        let config = try ConfigLoader.load()
        XCTAssertEqual(config.provider, "anthropic")
        XCTAssertEqual(config.maxSteps, 25)
    }
}
