import Foundation
import XCTest
import IsolatedServerCore
@testable import IsolatedMCPServer

/// Pins the MCP tool-annotation contract required by the Anthropic directory
/// review: every advertised tool carries a title and an explicit
/// readOnlyHint / destructiveHint. One assertion set per tool, named by tool,
/// so a regression identifies WHICH tool lost its annotations.
final class MCPToolAnnotationTests: XCTestCase {
    // Tools whose only side effects are owner-private local artifacts
    // (frames, reports); they never mutate the app under test.
    private static let readOnly: Set<String> = [
        "screenshot", "session_frame", "frame_history", "ocr_frame",
        "ascii_frame", "session_report", "trend_report", "list_sessions",
        "list_displays", "check_permissions", "get_test_report",
        "get_accessibility_tree", "get_interactive_elements", "find_element",
        "setup_status",
    ]
    // Tools that can irreversibly change state in the app under test.
    private static let destructive: Set<String> = [
        "run_test", "click", "click_element", "type_text", "key_press",
        "drag", "stop_session",
    ]

    private func listedTools() -> [[String: Any]] {
        MCPToolHandlers(sessionManager: SessionManager()).listTools()
    }

    func testEveryToolHasCompleteAnnotations() throws {
        let tools = listedTools()
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(
                tool["annotations"] as? [String: Any],
                "tool '\(name)' is missing annotations — directory review flags this"
            )
            let title = annotations["title"] as? String
            XCTAssertNotNil(title, "tool '\(name)' has no annotation title")
            XCTAssertFalse(title?.isEmpty ?? true, "tool '\(name)' has an empty title")
            let readOnly = annotations["readOnlyHint"] as? Bool
            XCTAssertNotNil(readOnly, "tool '\(name)' has no readOnlyHint")
            if readOnly == false {
                XCTAssertNotNil(
                    annotations["destructiveHint"] as? Bool,
                    "tool '\(name)' is not read-only but has no destructiveHint"
                )
            }
        }
    }

    func testReadOnlyClassificationPerTool() throws {
        for tool in listedTools() {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(
                annotations["readOnlyHint"] as? Bool,
                Self.readOnly.contains(name),
                "tool '\(name)' readOnlyHint does not match its classification"
            )
        }
    }

    func testDestructiveClassificationPerTool() throws {
        for tool in listedTools() {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            guard annotations["readOnlyHint"] as? Bool == false else { continue }
            XCTAssertEqual(
                annotations["destructiveHint"] as? Bool,
                Self.destructive.contains(name),
                "tool '\(name)' destructiveHint does not match its classification"
            )
        }
    }

    func testAnnotationTableHasNoOrphanEntries() {
        let advertised = Set(listedTools().compactMap { $0["name"] as? String })
        for key in MCPToolHandlers.toolAnnotations.keys {
            XCTAssertTrue(
                advertised.contains(key),
                "annotation table entry '\(key)' has no matching advertised tool"
            )
        }
    }
}
