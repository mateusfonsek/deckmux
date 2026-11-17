import DeckmuxJSON
import Foundation

/// How a hooks file is laid out.
public enum AgentHookFormat: Sendable {
    /// `{"hooks": {"Event": [{"hooks": [{"type", "command", "timeout"}]}]}}`:
    /// Claude Code's settings, and Codex's hooks.json.
    case claudeStyle
    /// Kiro CLI V3: `{"version": "v1", "hooks": [{"name", "trigger", "action", …}]}`.
    case kiroV1
}

/// One of the agent's hook events and the name `deckmux hook` gets for it.
public struct AgentHookEvent: Equatable, Sendable {
    public let native: String
    public let deckmux: String

    public init(_ native: String, _ deckmux: String) {
        self.native = native
        self.deckmux = deckmux
    }
}

/// A hooks file in the user's home that Deckmux adds its hooks to when the
/// agent is turned on and takes them out of when it is turned off, leaving
/// everything else in the file as it was.
public struct AgentHookFile: Sendable {
    /// From the home folder: ".codex/hooks.json".
    public let relativePath: String
    public let format: AgentHookFormat
    public let events: [AgentHookEvent]

    public init(relativePath: String, format: AgentHookFormat, events: [AgentHookEvent]) {
        self.relativePath = relativePath
        self.format = format
        self.events = events
    }

    /// The command of a Deckmux hook. It does nothing outside a Deckmux
    /// terminal (no `DECKMUX_CLI`) and always succeeds.
    public static func command(agent: AgentKind, event: String) -> String {
        #"[ -x "$DECKMUX_CLI" ] && "$DECKMUX_CLI" hook \#(agent.rawValue) \#(event) || true"#
    }

    static func isDeckmux(_ command: String?, agent: AgentKind) -> Bool {
        command?.contains(#""$DECKMUX_CLI" hook \#(agent.rawValue) "#) == true
    }

    /// The file's new text with Deckmux's hooks in (or out); nil when nothing
    /// would be left in it, so the file is deleted.
    public func edited(_ current: String?, install: Bool, agent: AgentKind) throws -> String? {
        switch format {
        case .claudeStyle: try editedClaudeStyle(current, install: install, agent: agent)
        case .kiroV1: try editedKiro(current, install: install, agent: agent)
        }
    }

    private func editedClaudeStyle(_ current: String?, install: Bool, agent: AgentKind) throws -> String? {
        var json = try current.map { try JSONValue(parsing: $0) } ?? .object([])
        for event in events {
            json.update(["hooks", event.native]) { groups in
                // Deckmux's own groups come out; the user's stay in order.
                var kept: [JSONValue] = (groups?.arrayValue ?? []).compactMap { group in
                    let hooks = (group["hooks"]?.arrayValue ?? []).filter { !Self.isDeckmux($0["command"]?.stringValue, agent: agent) }
                    guard !hooks.isEmpty else { return nil }
                    var group = group
                    group.set("hooks", .array(hooks))
                    return group
                }
                if install {
                    kept.append(.object([("hooks", .array([.object([
                        ("type", .string("command")),
                        ("command", .string(Self.command(agent: agent, event: event.deckmux))),
                        ("timeout", .number("5")),
                    ])]))]))
                }
                return kept.isEmpty ? nil : .array(kept)
            }
        }
        if json["hooks"]?.objectMembers?.isEmpty == true { json.set("hooks", nil) }
        if json.objectMembers?.isEmpty == true { return nil }
        return json.formatted(trailingNewline: current?.hasSuffix("\n") ?? true)
    }

    private func editedKiro(_ current: String?, install: Bool, agent: AgentKind) throws -> String? {
        preconditionFailure("Kiro hooks come with the Kiro provider")
    }
}

extension AgentProvider {
    /// The hooks file Deckmux installs when the agent is turned on; nil for
    /// agents that get their hooks another way (Claude: the wrapper).
    public var hookFile: AgentHookFile? { nil }
}
