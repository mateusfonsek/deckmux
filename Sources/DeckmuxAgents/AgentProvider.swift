import Foundation

/// Everything Deckmux needs to know about one agent. Each agent lives in its
/// own folder (Claude/, Codex/, Kiro/) and is listed in `AgentRegistry`.
/// Optional capabilities (hooks file, MCP, context, usage) are extensions
/// with a nil default: an agent without one simply does not show it.
public protocol AgentProvider: Sendable {
    var kind: AgentKind { get }
    /// "Claude", "Codex", "Kiro": used in "<name> terminou".
    var displayName: String { get }
    /// The executable on the user's PATH.
    var executable: String { get }
    var install: AgentInstallInfo { get }
    var mark: AgentMark { get }
    var workSignal: AgentWorkSignal { get }

    /// Typed into a new terminal to start the agent.
    func launchCommand() -> String
    /// Typed into a restored terminal to reopen a conversation.
    func resumeCommand(sessionID: String) -> String
    /// Whether the agent saved this conversation (resuming one it did not
    /// save fails). nil when it cannot tell: resume anyway.
    func hasTranscript(_ session: AgentSession, home: URL, environment: [String: String]) -> Bool?
    /// Translates one of this agent's hook messages; nil when Deckmux ignores it.
    func event(hook: String, payload: [String: String]) -> AgentEvent?

    // Optional capabilities. They are requirements (with defaults in
    // extensions) so that `any AgentProvider` dispatches to the agent's own.

    /// The hooks file Deckmux installs when the agent is turned on.
    var hookFile: AgentHookFile? { get }
    /// How it keeps and reports a workspace's MCP servers.
    var mcp: (any AgentMcp)? { get }
    /// Where its usage limits can be read; nil shows "Uso indisponível".
    var usageSource: AgentUsageSource? { get }
    /// Whether it writes subagent transcripts Deckmux can follow
    /// (`~/.claude/projects/<folder>/<session>/subagents`).
    var keepsSubagentTranscripts: Bool { get }
    /// What the user still has to do once the agent is on (Codex: trust the hooks).
    var postInstallNotice: String? { get }
}

extension AgentProvider {
    public var usageSource: AgentUsageSource? { nil }
    public var keepsSubagentTranscripts: Bool { false }
    public var postInstallNotice: String? { nil }
}

public enum Shell {
    /// Single-quoted for zsh: `a'b` → `'a'\''b'`.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
