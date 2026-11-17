import Foundation

/// An agent conversation running in a terminal, as its SessionStart hook
/// reported it.
public struct AgentSession: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    public var directory: String?

    public init(agent: AgentKind, sessionID: String, directory: String?) {
        self.agent = agent
        self.sessionID = sessionID
        self.directory = directory
    }
}

/// Reads a saved terminal's conversation: the `agent` key, or the `claude`
/// key that sessions saved before multi-agent support carry
/// (`{"sessionID": …, "directory": …}`, always Claude Code).
public enum SavedAgentSession {
    private struct LegacyClaude: Decodable {
        var sessionID: String
        var directory: String?
    }

    public static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, key: Key, legacyClaudeKey: Key) throws -> AgentSession? {
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: key) { return session }
        guard let legacy = try container.decodeIfPresent(LegacyClaude.self, forKey: legacyClaudeKey) else { return nil }
        return AgentSession(agent: .claude, sessionID: legacy.sessionID, directory: legacy.directory)
    }
}
