import Foundation

/// Claude Code. Its hooks come from the bundled `claude` wrapper (through
/// `--settings`, for that launch only), and its working state from the
/// terminal title.
public struct ClaudeProvider: AgentProvider {
    public init() {}

    public let kind = AgentKind.claude
    public let displayName = "Claude"
    public let executable = "claude"
    public let install = AgentInstallInfo(command: "curl -fsSL https://claude.ai/install.sh | bash",
                                          docsURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
    public let mark = AgentMark(glyph: "\u{2733}\u{FE0E}", colorHex: "#D97757", scale: 1.2)
    public let workSignal = AgentWorkSignal.terminalTitle

    public func launchCommand() -> String { "claude\n" }

    public func resumeCommand(sessionID: String) -> String { "claude --resume \(Shell.quoted(sessionID))\n" }

    public func hasTranscript(_ session: AgentSession, home: URL, environment: [String: String]) -> Bool? {
        guard let directory = session.directory else { return nil }
        let configDir = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let projects = configDir.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path) else { return nil }
        // Claude Code names a project's folder after its path, every
        // character other than a letter or digit turned into "-".
        let folder = String(directory.map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" })
        return FileManager.default.fileExists(atPath: projects.appendingPathComponent(folder).appendingPathComponent("\(session.sessionID).jsonl").path)
    }

    public func event(hook: String, payload: [String: String]) -> AgentEvent? {
        switch hook {
        case "session-start":
            guard let session = payload["session_id"] else { return nil }
            return .sessionStarted(sessionID: session, cwd: payload["cwd"])
        case "session-end":
            return .sessionEnded
        case "stop":
            return .turnFinished
        case "permission-request":
            return .needsInput(payload["tool_name"].map { "Quer usar \($0)" })
        case "notification":
            // The idle reminder repeats what Stop already said.
            if payload["notification_type"] == "idle_prompt" { return nil }
            return .needsInput(payload["message"])
        default:
            return nil
        }
    }
}
