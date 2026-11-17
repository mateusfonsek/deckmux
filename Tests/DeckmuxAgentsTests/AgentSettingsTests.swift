import Foundation
import Testing
@testable import DeckmuxAgents

private func fresh() -> (AgentSettings, UserDefaults) {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    return (AgentSettings(defaults: defaults), defaults)
}

@Test func onlyClaudeByDefault() {
    let (settings, _) = fresh()
    #expect(settings.enabled == [.claude])
    #expect(settings.defaultAgent == .claude)
    #expect(settings.resumesConversations == true)
    #expect(settings.usageAgent == .claude)
}

@Test func enablingKeepsRegistryOrder() {
    let (settings, _) = fresh()
    settings.setEnabled(.kiro, true)
    settings.setEnabled(.codex, true)
    #expect(settings.enabled == [.claude, .codex, .kiro])
}

@Test func defaultFallsBackWhenTurnedOff() {
    let (settings, _) = fresh()
    settings.setEnabled(.codex, true)
    settings.setEnabled(.claude, false)
    #expect(settings.enabled == [.codex])
    #expect(settings.defaultAgent == .codex)
    #expect(settings.usageAgent == .codex)
}

@Test func noAgentsAllowed() {
    let (settings, _) = fresh()
    settings.setEnabled(.claude, false)
    #expect(settings.enabled == [])
    #expect(settings.defaultAgent == nil)
    #expect(settings.usageAgent == nil)
}

@Test func keepsTheOldResumeChoice() {
    let (settings, defaults) = fresh()
    defaults.set(false, forKey: "resumeClaudeSessions")
    #expect(settings.resumesConversations == false)
    settings.resumesConversations = true
    #expect(defaults.bool(forKey: "resumeClaudeSessions"))
}

@Test func unknownAgentsAreIgnored() {
    let (settings, defaults) = fresh()
    defaults.set(["claude", "zzz"], forKey: "agents.enabled")
    #expect(settings.enabled == [.claude])
}

@Test func choicesStick() {
    let (settings, _) = fresh()
    settings.setEnabled(.codex, true)
    settings.defaultAgent = .codex
    settings.usageAgent = .codex
    #expect(settings.defaultAgent == .codex)
    #expect(settings.usageAgent == .codex)
    // A choice of an agent that is off is not kept.
    settings.defaultAgent = .kiro
    #expect(settings.defaultAgent == .codex)
}
