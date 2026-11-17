import AppKit
import DeckmuxAgents

/// Turning an agent on or off in Ajustes.
@MainActor
enum AgentActivation {
    static func request(_ kind: AgentKind, on: Bool, settings: AgentSettings) {
        settings.setEnabled(kind, on)
    }
}
