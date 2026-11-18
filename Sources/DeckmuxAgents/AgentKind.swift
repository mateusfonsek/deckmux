import Foundation

/// The AI coding agents Deckmux knows. The raw value is the stable id used in
/// settings, hook arguments and saved sessions; it matches `CodingAgent.id`
/// in DeckmuxTop.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, kiro
}

/// How Deckmux tells that an agent is working.
public enum AgentWorkSignal: Sendable {
    /// The terminal title carries a spinner (and OSC 7501): Claude Code.
    case terminalTitle
    /// A prompt hook opens the turn and Stop closes it.
    case hookTurns
}

/// The one symbol Deckmux shows for any AI (SF Symbol name). Agents differ
/// by name and color, never by logo.
public enum AIMarkSymbol {
    public static let name = "sparkle"
}

/// How to install the agent when it is not on the PATH.
public struct AgentInstallInfo: Sendable {
    public let command: String
    public let docsURL: URL

    public init(command: String, docsURL: URL) {
        self.command = command
        self.docsURL = docsURL
    }
}
