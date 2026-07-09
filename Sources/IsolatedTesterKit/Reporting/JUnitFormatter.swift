import Foundation

/// Formats test reports as JUnit XML for CI system integration.
/// Compatible with Jenkins, GitHub Actions, GitLab CI, CircleCI, etc.
public struct JUnitFormatter: ReportFormatter, Sendable {

    public init() {}

    public func format(report: TestReportData) throws -> Data {
        let xml = buildXML(report: report)
        guard let data = xml.data(using: .utf8) else {
            throw ReportError.encodingFailed("Failed to encode JUnit XML as UTF-8")
        }
        return data
    }

    public var fileExtension: String { "xml" }

    private func buildXML(report: TestReportData) -> String {
        let appName = report.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "UnknownApp"
        let failures = report.success ? 0 : 1
        let time = String(format: "%.3f", report.duration)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="IsolatedTester" tests="1" failures="\(failures)" time="\(time)">
          <testsuite name="\(escapeXML(appName))" tests="1" failures="\(failures)" time="\(time)">
            <testcase name="\(escapeXML(report.objective))" classname="\(escapeXML(appName))" time="\(time)">
        """

        if !report.success {
            xml += """

                  <failure message="\(escapeXML(report.summary))" type="TestFailure">
            \(escapeXML(report.summary))
                  </failure>
            """
        }

        // Add step details as system-out
        let stepOutput = report.steps.map { step in
            "Step \(step.step): [\(step.action)] \(step.reasoning)"
        }.joined(separator: "\n")

        xml += """

              <system-out><![CDATA[
        Session: \(report.sessionId)
        Provider: \(report.provider ?? "unknown")
        Model: \(report.model ?? "default")
        Steps: \(report.stepCount)
        Duration: \(time)s

        \(stepOutput)
        ]]></system-out>
            </testcase>
          </testsuite>
        </testsuites>
        """

        return xml
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

public enum ReportError: Error, LocalizedError {
    case encodingFailed(String)
    case writeError(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let msg): return "Report encoding failed: \(msg)"
        case .writeError(let msg): return "Report write error: \(msg)"
        }
    }
}
