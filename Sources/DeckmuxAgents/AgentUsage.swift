import Foundation

/// Where an agent's account usage (5-hour and weekly limits) comes from.
public enum AgentUsageSource: Sendable {
    /// Claude Code's OAuth token and the endpoint behind `/usage`.
    case claudeAccount
    /// The `rate_limits` Codex writes into its session files.
    case codexSessions
}
