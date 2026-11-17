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
    /// The agent used a tool: its turn is still alive.
    case activity
}

/// When an open turn of an agent that reports work through hooks still
/// counts as working. Without a heartbeat (a tool used) for this long, the
/// turn is taken as over: an interrupt that sends no Stop must not keep the
/// symbol spinning or the Mac awake.
public enum TurnRule {
    public static let staleTurn: TimeInterval = 600

    public static func isWorking(turnOpen: Bool, lastActivity: Date?, now: Date) -> Bool {
        guard turnOpen else { return false }
        guard let lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) <= staleTurn
    }
}
