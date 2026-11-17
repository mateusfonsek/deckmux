import Foundation

/// Claude Code reads the workspace's `.mcp.json`, the list itself (written
/// by the app, with Claude-only fields such as Slack's OAuth client).
struct ClaudeMcp: AgentMcp {
    let relativePath: String? = nil
    let listArguments = ["mcp", "list"]

    func edited(_ current: String?, adding: [McpServer], removing: [String]) throws -> String? { current }

    /// Lines look like `slack-acme: https://mcp.slack.com/mcp (HTTP) - ✔ Connected`.
    func parseHealth(_ text: String) -> [String: McpHealth] {
        var result: [String: McpHealth] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            guard let colon = line.firstIndex(of: ":"), let dash = line.range(of: " - ", options: .backwards) else { continue }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { continue }
            let status = line[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if status.contains("Connected") {
                result[name] = .connected
            } else if status.localizedCaseInsensitiveContains("auth") {
                result[name] = .needsLogin
            } else {
                let message = status.replacingOccurrences(of: "✗", with: "").trimmingCharacters(in: .whitespaces)
                result[name] = .failed(message)
            }
        }
        return result
    }

    func loginCommand(server: String) -> String? { "claude '/mcp'\n" }
}
