import Foundation
import Testing
@testable import DeckmuxAgents

/// Mirrors SessionSnapshot.Terminal's use of SavedAgentSession.
private struct Terminal: Codable {
    var agent: AgentSession?
    enum CodingKeys: String, CodingKey { case agent, claude }
    init(agent: AgentSession?) { self.agent = agent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try SavedAgentSession.decode(c, key: .agent, legacyClaudeKey: .claude)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(agent, forKey: .agent)
    }
}

private func decode(_ json: String) throws -> Terminal {
    try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
}

@Test func legacyClaudeKeyIsRead() throws {
    let t = try decode(#"{"claude":{"sessionID":"s1","directory":"/x"}}"#)
    #expect(t.agent == AgentSession(agent: .claude, sessionID: "s1", directory: "/x"))
}

@Test func agentKeyIsRead() throws {
    let t = try decode(#"{"agent":{"agent":"codex","sessionID":"c1"}}"#)
    #expect(t.agent == AgentSession(agent: .codex, sessionID: "c1", directory: nil))
}

@Test func noSessionIsNil() throws {
    #expect(try decode("{}").agent == nil)
}

@Test func encodesOnlyAgentKey() throws {
    let data = try JSONEncoder().encode(Terminal(agent: AgentSession(agent: .kiro, sessionID: "k", directory: nil)))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"agent\""))
    #expect(!text.contains("\"claude\""))
}
