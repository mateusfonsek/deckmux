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
