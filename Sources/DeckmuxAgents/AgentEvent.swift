import Foundation

/// A hook message from any agent, translated into what Deckmux does with it.
public enum AgentEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String, cwd: String?)
    case sessionEnded
    /// The user sent a prompt: the agent is working.
    case turnStarted
    /// The agent finished its turn.
    case turnFinished
    /// The agent waits on a permission prompt or a question.
    case needsInput(String?)
}
