import DeckmuxAgents
import Foundation

/// Whether an agent in a terminal is working, by the signal its provider uses.
enum AgentWork {
    /// Claude Code says so in the title or over OSC 7501; the others open a
    /// turn with their prompt hook and close it with Stop.
    static func isWorking(agent: AgentKind, reportsWorking: Bool, title: String, turnOpen: Bool) -> Bool {
        switch AgentRegistry.provider(for: agent).workSignal {
        case .terminalTitle: reportsWorking || TerminalLabel.isWorking(title)
        case .hookTurns: turnOpen
        }
    }

    @MainActor
    static func isWorking(terminal id: UUID, in layout: TerminalLayout) -> Bool {
        guard let session = layout.agentSessions[id] else { return false }
        let surface = layout.terminal(withID: id)
        return isWorking(agent: session.agent, reportsWorking: surface?.reportsWorking ?? false,
                         title: surface?.title ?? "", turnOpen: layout.agentTurns.contains(id))
    }
}

extension Notification.Name {
    /// A terminal's shell reported a finished command (OSC 133;D); object: the SurfaceView.
    static let deckmuxCommandFinished = Notification.Name("dev.fonsek.deckmux.commandFinished")
}
