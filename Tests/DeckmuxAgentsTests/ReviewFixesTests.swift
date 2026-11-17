import DeckmuxJSON
import Foundation
import Testing
@testable import DeckmuxAgents

// Review 1: a CLAUDE.md that starts with the import is migrated, and running
// the migration again changes nothing.
@Test func migrationIsIdempotent() throws {
    let first = try #require(AgentContextMigration.plan(claudeMd: "# Só do Claude\n", agentsMd: "# Acme\n"))
    #expect(AgentContextMigration.isMigrated(claudeMd: first.claude))
    #expect(AgentContextMigration.plan(claudeMd: first.claude, agentsMd: "# Acme\n") == nil)
    #expect(AgentContextMigration.isMigrated(claudeMd: "\n@AGENTS.md\n\n# extra\n"))
}

// Review 6: arrays of tables and a comment before the next table stay.
@Test func tomlKeepsArraysOfTablesAfterAServer() throws {
    let text = "[mcp_servers.x]\ncommand = \"c\"\n\n[[profiles]]\nname = \"a\"\n"
    #expect(try TomlTables.edited(text, adding: [], removing: ["x"]) == "[[profiles]]\nname = \"a\"\n")
}

@Test func tomlKeepsTheCommentOfTheNextTable() throws {
    let text = "a = 1\n\n[mcp_servers.x]\ncommand = \"c\"\n\n# minha nota\n[other]\nb = 2\n"
    #expect(try TomlTables.edited(text, adding: [], removing: ["x"]) == "a = 1\n\n# minha nota\n[other]\nb = 2\n")
}

// Review 5: an open turn with no activity for too long no longer counts.
@Test func turnsGoStaleWithoutActivity() {
    let start = Date(timeIntervalSince1970: 1000)
    #expect(TurnRule.isWorking(turnOpen: true, lastActivity: start, now: start.addingTimeInterval(60)))
    #expect(!TurnRule.isWorking(turnOpen: true, lastActivity: start, now: start.addingTimeInterval(TurnRule.staleTurn + 1)))
    #expect(!TurnRule.isWorking(turnOpen: false, lastActivity: start, now: start))
}

// Review 5: tool use is a heartbeat for agents that report turns by hooks.
@Test func toolUseIsActivity() {
    #expect(CodexProvider().event(hook: "activity", payload: [:]) == .activity)
    #expect(KiroProvider().event(hook: "activity", payload: [:]) == .activity)
    #expect(CodexProvider().hookFile?.events.contains(AgentHookEvent("PostToolUse", "activity")) == true)
    #expect(KiroProvider().hookFile?.events.contains(AgentHookEvent("PostToolUse", "activity")) == true)
}

// Minor 4: what is left to do after turning an agent on comes from the provider.
@Test func postInstallNoticeFromTheProvider() {
    #expect(AgentRegistry.provider(for: .codex).postInstallNotice?.contains("/hooks") == true)
    #expect(AgentRegistry.provider(for: .kiro).postInstallNotice == nil)
    #expect(AgentRegistry.provider(for: .claude).postInstallNotice == nil)
}

// Review 2: AGENTS.md is Deckmux's to delete only when CLAUDE.md imports it
// (Deckmux's migration); a repo's own AGENTS.md is left alone.
@Test func agentsMdIsDeletedOnlyWhenDeckmuxMadeIt() {
    #expect(AgentContextMigration.ownsAgentsMd(claudeMd: "@AGENTS.md\n"))
    #expect(!AgentContextMigration.ownsAgentsMd(claudeMd: "# Acme\n"))
    #expect(!AgentContextMigration.ownsAgentsMd(claudeMd: nil))
}
