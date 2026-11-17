import Foundation

/// Which file holds a workspace's context. With only Claude Code on, it is
/// `CLAUDE.md`, as always. With an agent that reads `AGENTS.md` (Codex, Kiro)
/// on, the text lives in `AGENTS.md` and `CLAUDE.md` only imports it, so every
/// agent reads the same rules.
public enum AgentContextLayout: Equatable, Sendable {
    case claudeOnly
    case shared

    public static func layout(enabled: [AgentKind]) -> AgentContextLayout {
        enabled.contains { $0 != .claude } ? .shared : .claudeOnly
    }

    public var fileToEdit: String {
        switch self {
        case .claudeOnly: "CLAUDE.md"
        case .shared: "AGENTS.md"
        }
    }
}

/// Moving a workspace's `CLAUDE.md` text into `AGENTS.md`. Offered, never automatic.
public enum AgentContextMigration {
    public static let importLine = "@AGENTS.md"

    public static func isMigrated(claudeMd: String?) -> Bool {
        claudeMd?.trimmingCharacters(in: .whitespacesAndNewlines) == importLine
    }

    /// The new texts (agents nil: leave AGENTS.md as is), or nil when there is
    /// nothing to do. No text is ever dropped.
    public static func plan(claudeMd: String?, agentsMd: String?) -> (agents: String?, claude: String)? {
        if isMigrated(claudeMd: claudeMd) { return nil }
        let own = claudeMd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if agentsMd == nil {
            return (claudeMd ?? "", importLine + "\n")
        }
        return (nil, own.isEmpty ? importLine + "\n" : importLine + "\n\n" + (claudeMd ?? ""))
    }
}
