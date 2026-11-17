import Foundation

/// Which agents the user works with (Ajustes → IAs), the one the new-terminal
/// button opens, whether conversations come back on relaunch and whose usage
/// the Janelinha shows. Only Claude is on until the user turns others on;
/// everything in Deckmux asks only about the agents that are on.
public final class AgentSettings: @unchecked Sendable {
    /// `DECKMUX_DEFAULTS_SUITE` keeps a test instance's choices apart from
    /// the installed app's, which shares its bundle id.
    public static let shared = AgentSettings(defaults: {
        if let suite = ProcessInfo.processInfo.environment["DECKMUX_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) { return defaults }
        return .standard
    }())
    /// Posted (object: the settings) whenever a value changes.
    public static let didChange = Notification.Name("dev.fonsek.deckmux.agentSettingsDidChange")

    private let defaults: UserDefaults
    private enum Key {
        static let enabled = "agents.enabled"
        static let defaultAgent = "agents.default"
        static let usage = "agents.usage"
        /// Kept from the Claude-only menu item, so the choice survives.
        static let resume = "resumeClaudeSessions"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// In `AgentKind` order; [.claude] until changed.
    public var enabled: [AgentKind] {
        guard let raw = defaults.stringArray(forKey: Key.enabled) else { return [.claude] }
        let kinds = Set(raw.compactMap(AgentKind.init(rawValue:)))
        return AgentKind.allCases.filter(kinds.contains)
    }

    public func isEnabled(_ kind: AgentKind) -> Bool { enabled.contains(kind) }

    public func setEnabled(_ kind: AgentKind, _ on: Bool) {
        var kinds = Set(enabled)
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        defaults.set(AgentKind.allCases.filter(kinds.contains).map(\.rawValue), forKey: Key.enabled)
        changed()
    }

    /// The agent of the new-terminal button: the chosen one while it is on,
    /// else the first one on; nil when none is.
    public var defaultAgent: AgentKind? {
        get { chosen(Key.defaultAgent) }
        set { choose(newValue, Key.defaultAgent) }
    }

    /// Whose usage the Janelinha shows: Claude by default, while it is on.
    public var usageAgent: AgentKind? {
        get { chosen(Key.usage) }
        set { choose(newValue, Key.usage) }
    }

    public var resumesConversations: Bool {
        get { defaults.object(forKey: Key.resume) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.resume); changed() }
    }

    private func chosen(_ key: String) -> AgentKind? {
        let on = enabled
        if let raw = defaults.string(forKey: key), let kind = AgentKind(rawValue: raw), on.contains(kind) { return kind }
        return on.first
    }

    private func choose(_ kind: AgentKind?, _ key: String) {
        guard let kind, isEnabled(kind) else { return }
        defaults.set(kind.rawValue, forKey: key)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
