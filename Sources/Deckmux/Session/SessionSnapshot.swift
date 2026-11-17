import DeckmuxAgents
import Foundation
import DeckmuxChat
import DeckmuxCode

/// Everything Deckmux brings back on the next launch: the sidebar items in
/// order, each item's splits and tabs, and per terminal its folder and the
/// agent conversation it was running. Scrollback is stored next to it,
/// one file per terminal (see `SessionStore`).
struct SessionSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version = SessionSnapshot.currentVersion
    var items: [Item]
    var selectedItem: UUID?

    struct Item: Codable, Equatable {
        var id: UUID
        var layout: Node
        var focusedTerminal: UUID?
        /// The user's name and tag; absent in sessions saved before it existed.
        var customization: ChatCustomization? = nil
    }

    /// Bonsplit's tree: a pane with tabs, or a split of two nodes.
    indirect enum Node: Codable, Equatable {
        case pane(Pane)
        case split(Split)

        var terminals: [Terminal] {
            switch self {
            case .pane(let pane): pane.terminals
            case .split(let split): split.first.terminals + split.second.terminals
            }
        }

        /// Only the shell tabs; code tabs have no folder or scrollback.
        var shells: [Terminal] { terminals.filter { $0.kind == nil } }

        // Stored as {"pane": {...}} or {"split": {...}}.
        private enum CodingKeys: String, CodingKey { case pane, split }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let pane = try container.decodeIfPresent(Pane.self, forKey: .pane) {
                self = .pane(pane)
            } else {
                self = .split(try container.decode(Split.self, forKey: .split))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pane(let pane): try container.encode(pane, forKey: .pane)
            case .split(let split): try container.encode(split, forKey: .split)
            }
        }
    }

    struct Pane: Codable, Equatable {
        var terminals: [Terminal]
        var selectedTerminal: UUID?
    }

    struct Split: Codable, Equatable {
        enum Orientation: String, Codable { case horizontal, vertical }
        var orientation: Orientation
        /// Fraction of the split taken by `first`.
        var dividerPosition: Double
        var first: Node
        var second: Node
    }

    struct Terminal: Codable, Equatable {
        var id: UUID
        var directory: String?
        /// The agent conversation it was running. Sessions saved before
        /// multi-agent support stored it as `claude` (see SavedAgentSession).
        var agent: AgentSession?
        /// "code" for a code tab; nil for a terminal.
        var kind: String? = nil
        var code: CodeTabState? = nil

        init(id: UUID, directory: String?, agent: AgentSession?, kind: String? = nil, code: CodeTabState? = nil) {
            self.id = id
            self.directory = directory
            self.agent = agent
            self.kind = kind
            self.code = code
        }

        private enum CodingKeys: String, CodingKey { case id, directory, agent, claude, kind, code }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            directory = try container.decodeIfPresent(String.self, forKey: .directory)
            agent = try SavedAgentSession.decode(container, key: .agent, legacyClaudeKey: .claude)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            code = try container.decodeIfPresent(CodeTabState.self, forKey: .code)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(directory, forKey: .directory)
            try container.encodeIfPresent(agent, forKey: .agent)
            try container.encodeIfPresent(kind, forKey: .kind)
            try container.encodeIfPresent(code, forKey: .code)
        }
    }
}
