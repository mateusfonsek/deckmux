import DeckmuxJSON
import Foundation

/// Kiro reads MCP servers from the workspace's `.kiro/settings/mcp.json`
/// (same shape as `.mcp.json`) and lists them, one `• name` per line.
struct KiroMcp: AgentMcp {
    let relativePath: String? = ".kiro/settings/mcp.json"
    let listArguments = ["mcp", "list"]

    func edited(_ current: String?, adding: [McpServer], removing: [String]) throws -> String? {
        var json = try current.map { try JSONValue(parsing: $0) } ?? .object([])
        for name in removing { json.update(["mcpServers", name]) { _ in nil } }
        for server in adding { json.update(["mcpServers", server.name]) { _ in Self.entry(server) } }
        if json["mcpServers"]?.objectMembers?.isEmpty == true { json.set("mcpServers", nil) }
        if json.objectMembers?.isEmpty == true { return nil }
        return json.formatted(trailingNewline: current?.hasSuffix("\n") ?? true)
    }

    static func entry(_ server: McpServer) -> JSONValue {
        func object(_ values: [String: String]) -> JSONValue {
            .object(values.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) })
        }
        switch server.transport {
        case .stdio(let command, let args, let env):
            var members: [(key: String, value: JSONValue)] = [("command", .string(command)), ("args", .array(args.map(JSONValue.string)))]
            if !env.isEmpty { members.append(("env", object(env))) }
            return .object(members)
        case .http(let url, let headers):
            var members: [(key: String, value: JSONValue)] = [("url", .string(url))]
            if !headers.isEmpty { members.append(("headers", object(headers))) }
            return .object(members)
        }
    }

    func parseHealth(_ stdout: String) -> [String: McpHealth] {
        var result: [String: McpHealth] = [:]
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("•") else { continue }
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if let name = rest.split(separator: " ").first { result[String(name)] = .configured }
        }
        return result
    }

    func loginCommand(server: String) -> String? { nil }
}
