import Foundation

/// Codex reads MCP servers from the project's `.codex/config.toml` (when the
/// project is trusted) and reports them with `codex mcp list --json`.
struct CodexMcp: AgentMcp {
    let relativePath: String? = ".codex/config.toml"
    let listArguments = ["mcp", "list", "--json"]

    func edited(_ current: String?, adding: [McpServer], removing: [String]) throws -> String? {
        try TomlTables.edited(current, adding: adding, removing: removing)
    }

    func parseHealth(_ stdout: String) -> [String: McpHealth] {
        guard let start = stdout.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(stdout[start...].utf8)) as? [[String: Any]] else { return [:] }
        var result: [String: McpHealth] = [:]
        for server in list {
            guard let name = server["name"] as? String else { continue }
            if server["enabled"] as? Bool == false {
                result[name] = .failed(server["disabled_reason"] as? String ?? "desligado")
            } else if server["auth_status"] as? String == "not_logged_in" {
                result[name] = .needsLogin
            } else {
                result[name] = .configured
            }
        }
        return result
    }

    func loginCommand(server: String) -> String? { "codex mcp login \(Shell.quoted(server))\n" }
}
