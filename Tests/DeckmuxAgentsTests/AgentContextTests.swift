import Testing
@testable import DeckmuxAgents

@Test func contextLayoutFollowsTheAgentsOn() {
    #expect(AgentContextLayout.layout(enabled: [.claude]) == .claudeOnly)
    #expect(AgentContextLayout.layout(enabled: []) == .claudeOnly)
    #expect(AgentContextLayout.layout(enabled: [.claude, .codex]) == .shared)
    #expect(AgentContextLayout.layout(enabled: [.kiro]) == .shared)
    #expect(AgentContextLayout.claudeOnly.fileToEdit == "CLAUDE.md")
    #expect(AgentContextLayout.shared.fileToEdit == "AGENTS.md")
}

@Test func migrationMovesClaudeMdIntoAgentsMd() throws {
    let plan = try #require(AgentContextMigration.plan(claudeMd: "# Acme\n\nRegras.\n", agentsMd: nil))
    #expect(plan.agents == "# Acme\n\nRegras.\n")
    #expect(plan.claude == "@AGENTS.md\n")
}

@Test func migrationIsDoneWhenClaudeMdOnlyImports() {
    #expect(AgentContextMigration.plan(claudeMd: "@AGENTS.md\n", agentsMd: "# Acme\n") == nil)
    #expect(AgentContextMigration.isMigrated(claudeMd: "@AGENTS.md\n"))
    #expect(!AgentContextMigration.isMigrated(claudeMd: "# Acme\n"))
}

@Test func migrationNeverLosesText() throws {
    // Both files exist: AGENTS.md stays, CLAUDE.md keeps its own text under the import.
    let plan = try #require(AgentContextMigration.plan(claudeMd: "# Só do Claude\n", agentsMd: "# Acme\n"))
    #expect(plan.agents == nil)
    #expect(plan.claude == "@AGENTS.md\n\n# Só do Claude\n")
    // No CLAUDE.md at all: it gets the import.
    let none = try #require(AgentContextMigration.plan(claudeMd: nil, agentsMd: "# Acme\n"))
    #expect(none.agents == nil)
    #expect(none.claude == "@AGENTS.md\n")
}
