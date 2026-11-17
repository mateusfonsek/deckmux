import DeckmuxJSON
import Foundation
import Testing
@testable import DeckmuxAgents

private let time = McpServer(name: "custom-acme", transport: .stdio(command: "uvx", args: ["--port", "8000"], env: ["A": "1"]))
private let slack = McpServer(name: "slack-acme", transport: .http(url: "https://mcp.slack.com/mcp", headers: [:]))

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: TOML (Codex)

@Test func tomlAddKeepsUserAndRoundTrips() throws {
    let user = "model = \"o3\"\n\n[mcp_servers.meu]\ncommand = \"x\"\n"
    let added = try #require(try TomlTables.edited(user, adding: [slack], removing: []))
    #expect(added.hasPrefix(user))
    #expect(added.contains("[mcp_servers.slack-acme]\nurl = \"https://mcp.slack.com/mcp\"\n"))
    #expect(try TomlTables.edited(added, adding: [], removing: ["slack-acme"]) == user)
}

@Test func tomlStdioWithEnvAndEscaping() throws {
    let tricky = McpServer(name: "x", transport: .stdio(command: #"C:\bin "q""#, args: ["--port", "8000"], env: ["A": "1"]))
    let text = try #require(try TomlTables.edited(nil, adding: [tricky], removing: []))
    #expect(text == """
        [mcp_servers.x]
        command = "C:\\\\bin \\"q\\""
        args = ["--port", "8000"]

        [mcp_servers.x.env]
        A = "1"

        """)
    // Removing the only server leaves nothing: the file goes away.
    #expect(try TomlTables.edited(text, adding: [], removing: ["x"]) == nil)
}

@Test func tomlRemovesFromTheMiddle() throws {
    let text = "a = 1\n\n[mcp_servers.x]\ncommand = \"c\"\n\n[mcp_servers.x.env]\nK = \"v\"\n\n[other]\nb = 2\n"
    #expect(try TomlTables.edited(text, adding: [], removing: ["x"]) == "a = 1\n\n[other]\nb = 2\n")
}

@Test func tomlReplacesAnExistingServer() throws {
    let first = try #require(try TomlTables.edited(nil, adding: [slack], removing: []))
    let moved = McpServer(name: "slack-acme", transport: .http(url: "https://example.com/mcp", headers: ["X": "1"]))
    let second = try #require(try TomlTables.edited(first, adding: [moved], removing: []))
    #expect(!second.contains("mcp.slack.com"))
    #expect(second.contains("[mcp_servers.slack-acme.http_headers]\nX = \"1\""))
    #expect(second.components(separatedBy: "[mcp_servers.slack-acme]").count == 2)
}

// MARK: Kiro JSON

@Test func kiroMcpKeepsUserServers() throws {
    let kiro = try #require(KiroProvider().mcp)
    let user = #"{"mcpServers":{"meu":{"command":"x"}}}"#
    let added = try #require(try kiro.edited(user, adding: [time, slack], removing: []))
    let json = try JSONValue(parsing: added)
    #expect(json["mcpServers"]?.objectMembers?.map(\.key) == ["meu", "custom-acme", "slack-acme"])
    #expect(json["mcpServers"]?["custom-acme"]?["args"] == .array([.string("--port"), .string("8000")]))
    #expect(json["mcpServers"]?["slack-acme"]?["url"]?.stringValue == "https://mcp.slack.com/mcp")
    let removed = try #require(try kiro.edited(added, adding: [], removing: ["custom-acme", "slack-acme"]))
    #expect(try JSONValue(parsing: removed)["mcpServers"]?.objectMembers?.map(\.key) == ["meu"])
    #expect(try kiro.edited(try kiro.edited(nil, adding: [time], removing: []), adding: [], removing: ["custom-acme"]) == nil)
    #expect(kiro.relativePath == ".kiro/settings/mcp.json")
}

// MARK: From .mcp.json

@Test func serversFromClaudeEntries() throws {
    let stdio = try JSONValue(parsing: #"{"type":"stdio","command":"uvx","args":["workspace-mcp@2.1.0","--single-user"],"env":{"WORKSPACE_MCP_PORT":"8001"}}"#)
    #expect(McpServer(name: "google-acme", claudeEntry: stdio)
            == McpServer(name: "google-acme", transport: .stdio(command: "uvx", args: ["workspace-mcp@2.1.0", "--single-user"], env: ["WORKSPACE_MCP_PORT": "8001"])))
    let http = try JSONValue(parsing: #"{"type":"http","url":"https://mcp.slack.com/mcp","oauth":{"clientId":"1"}}"#)
    #expect(McpServer(name: "slack-acme", claudeEntry: http) == slack)
    #expect(McpServer(name: "bad", claudeEntry: .object([])) == nil)
}

// MARK: Health

@Test func codexHealth() throws {
    let codex = try #require(CodexProvider().mcp)
    #expect(codex.listArguments == ["mcp", "list", "--json"])
    let health = codex.parseHealth(try fixture("codex-mcp-list.json"))
    #expect(health["custom-acme"] == .configured)
    #expect(health["slack-acme"] == .needsLogin)
    #expect(health["off-acme"] == .failed("disabled in config"))
    #expect(codex.loginCommand(server: "slack-acme") == "codex mcp login 'slack-acme'\n")
    #expect(codex.relativePath == ".codex/config.toml")
}

@Test func kiroHealth() throws {
    let kiro = try #require(KiroProvider().mcp)
    let health = kiro.parseHealth(try fixture("kiro-mcp-list.txt"))
    #expect(health == ["custom-acme": .configured, "slack-acme": .configured])
    #expect(kiro.loginCommand(server: "slack-acme") == nil)
}

@Test func claudeHealth() throws {
    let claude = try #require(ClaudeProvider().mcp)
    #expect(claude.relativePath == nil)
    let text = "slack-acme: https://mcp.slack.com/mcp (HTTP) - ✔ Connected\ngoogle-acme: uvx workspace-mcp - ✗ Failed to connect\nclickup-acme: https://mcp.clickup.com/mcp (HTTP) - ⚠ Needs authentication\n"
    #expect(claude.parseHealth(text) == ["slack-acme": .connected, "google-acme": .failed("Failed to connect"), "clickup-acme": .needsLogin])
    #expect(claude.loginCommand(server: "slack-acme") == "claude '/mcp'\n")
}

@Test func mcpThroughTheRegistry() {
    #expect(AgentRegistry.provider(for: .codex).mcp?.relativePath == ".codex/config.toml")
}

/// Kiro prints its list to stderr when it is not on a terminal.
@Test func healthFallsBackToStandardError() throws {
    let kiro = try #require(KiroProvider().mcp)
    let list = try fixture("kiro-mcp-list.txt")
    #expect(kiro.health(stdout: "", stderr: list) == ["custom-acme": .configured, "slack-acme": .configured])
    #expect(kiro.health(stdout: list, stderr: "noise") == ["custom-acme": .configured, "slack-acme": .configured])
}
