import DeckmuxJSON
import Foundation

/// An MCP server as every agent understands it. The workspace's `.mcp.json`
/// (Claude Code's format) is the list; other agents get a copy in theirs.
public struct McpServer: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: String, headers: [String: String])
    }

    public var name: String
    public var transport: Transport

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    /// From an entry of `.mcp.json`. Claude-only fields (OAuth client) stay behind.
    public init?(name: String, claudeEntry entry: JSONValue) {
        func strings(_ value: JSONValue?) -> [String: String] {
            Dictionary((value?.objectMembers ?? []).compactMap { member in member.value.stringValue.map { (member.key, $0) } },
                       uniquingKeysWith: { $1 })
        }
        if let url = entry["url"]?.stringValue, entry["type"]?.stringValue != "stdio" {
            self.init(name: name, transport: .http(url: url, headers: strings(entry["headers"])))
        } else if let command = entry["command"]?.stringValue {
            let args = (entry["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            self.init(name: name, transport: .stdio(command: command, args: args, env: strings(entry["env"])))
        } else {
            return nil
        }
    }
}

/// The health of one MCP server, as an agent's list command reports it.
public enum McpHealth: Equatable, Sendable {
    case checking
    case connected
    case needsLogin
    case failed(String)
    /// The agent lists it but does not say whether it connects.
    case configured
    /// Not listed (Claude Code ignores servers it has not been asked to approve).
    case unknown
}

/// How an agent keeps a workspace's MCP servers and reports on them.
public protocol AgentMcp: Sendable {
    /// The file Deckmux writes for this agent, from the workspace root; nil
    /// for Claude Code, whose `.mcp.json` is the list itself.
    var relativePath: String? { get }
    /// The file's new text with `adding` in (replacing same-named ones) and
    /// `removing` out; nil when nothing is left, so the file is deleted.
    func edited(_ current: String?, adding: [McpServer], removing: [String]) throws -> String?
    /// The agent's command that lists the servers, run in the workspace root.
    var listArguments: [String] { get }
    func parseHealth(_ stdout: String) -> [String: McpHealth]
    /// Typed into a terminal to log in to `server`; nil when the agent has no way.
    func loginCommand(server: String) -> String?
}

extension AgentProvider {
    public var mcp: (any AgentMcp)? { nil }
}

extension AgentMcp {
    /// The list command's output: stdout, or stderr when stdout is empty
    /// (Kiro writes there when it is not on a terminal).
    public func health(stdout: String, stderr: String) -> [String: McpHealth] {
        parseHealth(stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stderr : stdout)
    }
}
