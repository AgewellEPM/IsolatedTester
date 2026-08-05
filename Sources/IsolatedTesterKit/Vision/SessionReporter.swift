import Foundation

/// Reads the queryable session index (~/.isolated-tester/sessions/index.jsonl)
/// and produces reviewable reports + cross-session trend analysis — the
/// "learn from footage later" layer. Self-contained (no cross-repo imports):
/// it emits structured findings that Peel/Jeeves can INGEST over MCP to improve
/// the platforms, rather than reaching into those systems directly.
public enum SessionReporter {

    public struct SessionRow: Codable, Sendable {
        public let sessionID: String
        public let objective: String
        public let app: String
        public let summary: String
        public let video: String
        public let actionCount: Int
        public let evidenceChainHead: String
    }

    public struct Trends: Codable, Sendable {
        public let sessionCount: Int
        public let totalActions: Int
        /// app → number of sessions.
        public let byApp: [String: Int]
        /// action verb → total occurrences across all sessions.
        public let actionMix: [String: Int]
        /// sessions whose evidence chain is missing/empty (unsealed or broken).
        public let unsealedSessions: [String]
        /// sessions with a recorded video, and those without.
        public let withVideo: Int
        public let withoutVideo: Int
        /// Heuristic failure signals surfaced for later analysis.
        public let signals: [String]
    }

    private static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isolated-tester/sessions/index.jsonl")
    }

    /// All indexed sessions, newest last.
    public static func allSessions() -> [SessionRow] {
        guard let text = try? String(contentsOf: indexURL) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(SessionRow.self, from: Data(line.utf8))
        }
    }

    /// The full per-session record (includes the action log), if present.
    public static func sessionDetail(id: String) -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isolated-tester/sessions/\(id)/session.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Cross-session trend analysis over every recorded run — the input to
    /// "learn from failures later." Deterministic; no model required.
    public static func trends() -> Trends {
        let rows = allSessions()
        var byApp: [String: Int] = [:]
        var actionMix: [String: Int] = [:]
        var unsealed: [String] = []
        var withVideo = 0, withoutVideo = 0
        var totalActions = 0

        for row in rows {
            byApp[row.app.isEmpty ? "(unknown)" : row.app, default: 0] += 1
            totalActions += row.actionCount
            row.video.isEmpty ? (withoutVideo += 1) : (withVideo += 1)
            if row.evidenceChainHead.isEmpty { unsealed.append(row.sessionID) }
            // Pull the action mix from each session's detail file.
            if let detail = sessionDetail(id: row.sessionID),
               let actions = detail["actions"] as? [[String: Any]] {
                for a in actions {
                    if let verb = a["action"] as? String { actionMix[verb, default: 0] += 1 }
                }
            }
        }

        var signals: [String] = []
        if !unsealed.isEmpty {
            signals.append("\(unsealed.count) session(s) have no evidence chain head — unsealed or interrupted; check for crashes on teardown.")
        }
        if withoutVideo > 0 {
            signals.append("\(withoutVideo) session(s) produced no video — likely a missing Screen Recording grant or a zero-frame run.")
        }
        // Sessions that recorded but did nothing are a common "agent stalled" tell.
        let idleRuns = rows.filter { $0.actionCount == 0 }.map(\.sessionID)
        if !idleRuns.isEmpty {
            signals.append("\(idleRuns.count) session(s) took 0 actions — agent may have stalled or been blind; review those videos first.")
        }
        if rows.isEmpty {
            signals.append("No sessions indexed yet — run and stop a session to populate the footage index.")
        }

        return Trends(
            sessionCount: rows.count,
            totalActions: totalActions,
            byApp: byApp,
            actionMix: actionMix,
            unsealedSessions: unsealed,
            withVideo: withVideo,
            withoutVideo: withoutVideo,
            signals: signals
        )
    }

    /// A human-readable Markdown report of a single session's footage + evidence.
    public static func sessionReportMarkdown(id: String) -> String? {
        guard let detail = sessionDetail(id: id) else { return nil }
        let objective = detail["objective"] as? String ?? ""
        let app = detail["app"] as? String ?? ""
        let summary = detail["summary"] as? String ?? ""
        let video = detail["video"] as? String ?? ""
        let head = detail["evidenceChainHead"] as? String ?? ""
        let actions = detail["actions"] as? [[String: Any]] ?? []
        var md = "# Session \(id)\n\n"
        md += "- **Objective:** \(objective.isEmpty ? "(none set)" : objective)\n"
        md += "- **App:** \(app)\n"
        md += "- **Summary:** \(summary)\n"
        md += "- **Video:** \(video.isEmpty ? "(none)" : video)\n"
        md += "- **Evidence chain head:** \(head.isEmpty ? "(unsealed)" : head)\n\n"
        md += "## Actions (\(actions.count))\n\n"
        for (i, a) in actions.enumerated() {
            let at = a["at"] as? String ?? ""
            let verb = a["action"] as? String ?? ""
            let details = a["details"] as? String ?? ""
            md += "\(i + 1). `\(verb)` \(details) — \(at)\n"
        }
        return md
    }
}
