import XCTest
@testable import IsolatedTesterKit

final class ReportingTests: XCTestCase {

    func testJSONFormatter_producesValidJSON() throws {
        let report = TestReportData(
            sessionId: "abc123",
            objective: "Click button",
            success: true,
            summary: "Clicked successfully",
            stepCount: 2,
            duration: 3.5,
            steps: [
                .init(step: 0, action: "click", reasoning: "Found button", timestamp: Date()),
                .init(step: 1, action: "done", reasoning: "Complete", timestamp: Date()),
            ],
            appPath: "/Applications/Calculator.app",
            provider: "anthropic",
            model: "claude-sonnet-4-20250514"
        )

        let formatter = JSONReportFormatter()
        let data = try formatter.format(report: report)
        XCTAssertFalse(data.isEmpty)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["sessionId"] as? String, "abc123")
        XCTAssertEqual(json?["success"] as? Bool, true)
        XCTAssertEqual(json?["stepCount"] as? Int, 2)
    }

    func testJUnitFormatter_producesValidXML() throws {
        let report = TestReportData(
            sessionId: "def456",
            objective: "Verify addition",
            success: false,
            summary: "Wrong result displayed",
            stepCount: 5,
            duration: 12.3,
            steps: [
                .init(step: 0, action: "click", reasoning: "Clicked 5", timestamp: nil),
            ],
            provider: "openai"
        )

        let formatter = JUnitFormatter()
        let data = try formatter.format(report: report)
        let xml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(xml.contains("<?xml version=\"1.0\""))
        XCTAssertTrue(xml.contains("<testsuites"))
        XCTAssertTrue(xml.contains("<testsuite"))
        XCTAssertTrue(xml.contains("<testcase"))
        XCTAssertTrue(xml.contains("<failure"))  // Should have failure since success=false
        XCTAssertTrue(xml.contains("Verify addition"))
        XCTAssertTrue(xml.contains("Wrong result displayed"))
    }

    func testJUnitFormatter_successNoFailureTag() throws {
        let report = TestReportData(
            sessionId: "ghi789",
            objective: "Simple test",
            success: true,
            summary: "All good",
            stepCount: 1,
            duration: 1.0,
            steps: []
        )

        let formatter = JUnitFormatter()
        let data = try formatter.format(report: report)
        let xml = String(data: data, encoding: .utf8)!

        XCTAssertFalse(xml.contains("<failure"))
        XCTAssertTrue(xml.contains("failures=\"0\""))
    }

    func testJUnitFormatter_escapesXML() throws {
        let report = TestReportData(
            sessionId: "test",
            objective: "Test <special> & \"chars\"",
            success: true,
            summary: "OK",
            stepCount: 0,
            duration: 0,
            steps: []
        )

        let formatter = JUnitFormatter()
        let data = try formatter.format(report: report)
        let xml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(xml.contains("&lt;special&gt;"))
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertTrue(xml.contains("&quot;chars&quot;"))
    }

    func testJSONFormatter_fileExtension() {
        let formatter = JSONReportFormatter()
        XCTAssertEqual(formatter.fileExtension, "json")
    }

    func testJUnitFormatter_fileExtension() {
        let formatter = JUnitFormatter()
        XCTAssertEqual(formatter.fileExtension, "xml")
    }

    func testTestReportData_codable() throws {
        let report = TestReportData(
            sessionId: "test",
            objective: "Test",
            success: true,
            summary: "OK",
            stepCount: 0,
            duration: 1.0,
            steps: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestReportData.self, from: data)
        XCTAssertEqual(decoded.sessionId, "test")
        XCTAssertEqual(decoded.success, true)
    }
}
