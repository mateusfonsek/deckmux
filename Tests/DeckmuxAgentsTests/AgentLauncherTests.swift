import Foundation
import Testing
@testable import DeckmuxAgents

private func settings(_ on: [AgentKind], default chosen: AgentKind? = nil) -> AgentSettings {
    let s = AgentSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    for kind in AgentKind.allCases { s.setEnabled(kind, on.contains(kind)) }
    if let chosen { s.defaultAgent = chosen }
    return s
}

@Test func clickOpensTheDefaultAgent() {
    let s = settings([.claude, .codex], default: .codex)
    #expect(AgentLauncher.agent(forAction: AgentLauncher.buttonID, settings: s) == .codex)
    #expect(AgentLauncher.agent(forAction: "newAgent.claude", settings: s) == .claude)
    // An agent turned off is not opened, even from an old menu.
    #expect(AgentLauncher.agent(forAction: "newAgent.kiro", settings: s) == nil)
    #expect(AgentLauncher.agent(forAction: "code", settings: s) == nil)
}

@Test func rightClickListsTheAgentsOn() {
    let s = settings([.claude, .codex, .kiro], default: .kiro)
    let menu = AgentLauncher.menu(settings: s)
    #expect(menu.map(\.id) == ["newAgent.claude", "newAgent.codex", "newAgent.kiro"])
    #expect(menu.map(\.title) == ["Novo terminal com Claude", "Novo terminal com Codex", "Novo terminal com Kiro (padrão)"])
}

@Test func noAgentsMeansNoButton() {
    let s = settings([])
    #expect(AgentLauncher.agent(forAction: AgentLauncher.buttonID, settings: s) == nil)
    #expect(AgentLauncher.menu(settings: s).isEmpty)
    #expect(AgentLauncher.tooltip(settings: s) == nil)
    #expect(AgentLauncher.tooltip(settings: settings([.claude])) == "Novo terminal com Claude · clique direito: escolher a IA")
}
