import Foundation

/// Kiro CLI. Deckmux keeps its hooks in a file of its own,
/// `~/.kiro/hooks/deckmux.json` (Kiro V3 runs every file there). Kiro has no
/// permission event, so it only ever says "terminou".
public struct KiroProvider: AgentProvider {
    public init() {}

    public let kind = AgentKind.kiro
    public let displayName = "Kiro"
    public let executable = "kiro-cli"
    public let install = AgentInstallInfo(command: "curl -fsSL https://cli.kiro.dev/install | bash",
                                          docsURL: URL(string: "https://kiro.dev/docs/cli/")!)
    public let colorHex = "#9046FF"
    public let workSignal = AgentWorkSignal.hookTurns

    public var mcp: (any AgentMcp)? { KiroMcp() }

    public func launchCommand() -> String { "kiro-cli\n" }

    public func resumeCommand(sessionID: String) -> String { "kiro-cli chat --resume-id \(Shell.quoted(sessionID))\n" }

    /// Kiro's session store is not documented: resume and let Kiro say so.
    public func hasTranscript(_ session: AgentSession, home: URL, environment: [String: String]) -> Bool? { nil }

    public var hookFile: AgentHookFile? {
        AgentHookFile(relativePath: ".kiro/hooks/deckmux.json", format: .kiroV1, events: [
            .init("SessionStart", "session-start"),
            .init("UserPromptSubmit", "prompt"),
            .init("Stop", "stop"),
            .init("PostToolUse", "activity"),
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
        case "session-end": return .sessionEnded
        case "activity": return .activity
        default: return nil
        }
    }
}
