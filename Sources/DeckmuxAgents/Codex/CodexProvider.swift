import Foundation

/// OpenAI's Codex CLI. Deckmux installs its hooks once in `~/.codex/hooks.json`
/// (Codex runs them only after the user trusts them in `/hooks`); a prompt
/// opens the turn and Stop closes it.
public struct CodexProvider: AgentProvider {
    public init() {}

    public let kind = AgentKind.codex
    public let displayName = "Codex"
    public let executable = "codex"
    public let install = AgentInstallInfo(command: "npm install -g @openai/codex",
                                          docsURL: URL(string: "https://developers.openai.com/codex/cli")!)
    /// A hexagon: abstract, and apart from Gemini's four-pointed star.
    public let mark = AgentMark(glyph: "\u{2B21}\u{FE0E}", colorHex: "#10A37F", scale: 1.5, relativeSize: 1.35)
    public let workSignal = AgentWorkSignal.hookTurns

    public func launchCommand() -> String { "codex\n" }

    public func resumeCommand(sessionID: String) -> String { "codex resume \(Shell.quoted(sessionID))\n" }

    /// Codex keeps each conversation as `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
    public func hasTranscript(_ session: AgentSession, home: URL, environment: [String: String]) -> Bool? {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let sessions = codexHome.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path),
              let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        let suffix = "-\(session.sessionID).jsonl"
        for case let file as URL in files where file.lastPathComponent.hasPrefix("rollout-") && file.lastPathComponent.hasSuffix(suffix) {
            return true
        }
        return false
    }

    public var hookFile: AgentHookFile? {
        AgentHookFile(relativePath: ".codex/hooks.json", format: .claudeStyle, events: [
            .init("SessionStart", "session-start"),
            .init("UserPromptSubmit", "prompt"),
            .init("Stop", "stop"),
            .init("PermissionRequest", "permission-request"),
            .init("SessionEnd", "session-end"),
        ])
    }

    public func event(hook: String, payload: [String: String]) -> AgentEvent? {
        switch hook {
        case "session-start":
            guard let session = payload["session_id"] else { return nil }
            return .sessionStarted(sessionID: session, cwd: payload["cwd"])
        case "prompt": return .turnStarted
        case "stop": return .turnFinished
        case "permission-request": return .needsInput(payload["tool_name"].map { "Quer usar \($0)" })
        case "session-end": return .sessionEnded
        default: return nil
        }
    }
}
