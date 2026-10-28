import Foundation
import DeckmuxChat
import DeckmuxCode

/// Everything Deckmux brings back on the next launch: the sidebar items in
/// order, each item's splits and tabs, and per terminal its folder and the
/// Claude Code conversation it was running. Scrollback is stored next to it,
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
        var claude: ClaudeSession?
        /// "code" for a code tab; nil for a terminal.
        var kind: String? = nil
        var code: CodeTabState? = nil
    }
}

/// A Claude Code conversation running in a terminal, as reported by its
/// SessionStart hook.
struct ClaudeSession: Codable, Equatable {
    var sessionID: String
    var directory: String?

    /// Whether Claude Code saved this conversation. One closed before any
    /// message (only /mcp, say) has no transcript, and `--resume` would fail.
    /// nil when it cannot tell (no projects folder where expected).
    var hasTranscript: Bool? {
        guard let directory else { return nil }
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        let projects = configDir.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path) else { return nil }
        // Claude Code names a project's folder after its path, every
        // character other than a letter or digit turned into "-".
        let folder = String(directory.map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" })
        return FileManager.default.fileExists(atPath: projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl").path)
    }
}
