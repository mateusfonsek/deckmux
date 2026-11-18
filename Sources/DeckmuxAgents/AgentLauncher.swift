import Foundation

/// The tab bar's single AI button: a click opens the default agent (Ajustes),
/// a right-click lists the agents turned on.
public enum AgentLauncher {
    public static let buttonID = "newAgent"
    private static let prefix = buttonID + "."

    /// The agent an action opens: the button itself → the default one;
    /// a menu item → its agent, while it is on. nil for anything else.
    public static func agent(forAction id: String, settings: AgentSettings) -> AgentKind? {
        if id == buttonID { return settings.defaultAgent }
        guard id.hasPrefix(prefix), let kind = AgentKind(rawValue: String(id.dropFirst(prefix.count))),
              settings.isEnabled(kind) else { return nil }
        return kind
    }

    /// The right-click menu: (action id, title) per agent on, the default marked.
    public static func menu(settings: AgentSettings) -> [(id: String, title: String)] {
        let chosen = settings.defaultAgent
        return settings.enabled.map { kind in
            let name = AgentRegistry.provider(for: kind).displayName
            return (prefix + kind.rawValue, "Novo terminal com \(name)" + (kind == chosen ? " (padrão)" : ""))
        }
    }

    /// The button's tooltip; nil when no agent is on (no button).
    public static func tooltip(settings: AgentSettings) -> String? {
        settings.defaultAgent.map { "Novo terminal com \(AgentRegistry.provider(for: $0).displayName) · clique direito: escolher a IA" }
    }
}
