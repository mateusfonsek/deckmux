import Foundation
import Testing
@testable import DeckmuxAgents

private let claude = ClaudeProvider()

@Test func claudeCommands() {
    #expect(claude.launchCommand() == "claude\n")
    #expect(claude.resumeCommand(sessionID: "a'b") == "claude --resume 'a'\\''b'\n")
}

@Test func claudeEvents() {
    #expect(claude.event(hook: "session-start", payload: ["session_id": "s1", "cwd": "/x"]) == .sessionStarted(sessionID: "s1", cwd: "/x"))
    #expect(claude.event(hook: "session-start", payload: [:]) == nil)
    #expect(claude.event(hook: "session-end", payload: [:]) == .sessionEnded)
    #expect(claude.event(hook: "stop", payload: [:]) == .turnFinished)
    #expect(claude.event(hook: "permission-request", payload: ["tool_name": "Bash"]) == .needsInput("Quer usar Bash"))
    #expect(claude.event(hook: "notification", payload: ["notification_type": "idle_prompt"]) == nil)
    #expect(claude.event(hook: "notification", payload: ["message": "m"]) == .needsInput("m"))
    #expect(claude.event(hook: "whatever", payload: [:]) == nil)
}

@Test func claudeTranscript() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = AgentSession(agent: .claude, sessionID: "s1", directory: "/x/y")
    #expect(claude.hasTranscript(session, home: home, environment: [:]) == nil)
    let projects = home.appendingPathComponent(".claude/projects/-x-y")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    #expect(claude.hasTranscript(session, home: home, environment: [:]) == false)
    try Data().write(to: projects.appendingPathComponent("s1.jsonl"))
    #expect(claude.hasTranscript(session, home: home, environment: [:]) == true)
    // CLAUDE_CONFIG_DIR wins over ~/.claude.
    let other = home.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other.appendingPathComponent("projects"), withIntermediateDirectories: true)
    #expect(claude.hasTranscript(session, home: home, environment: ["CLAUDE_CONFIG_DIR": other.path]) == false)
}

@Test func registryOrder() {
    #expect(AgentRegistry.all.map(\.kind) == [.claude, .codex])
    #expect(AgentRegistry.provider(for: .claude).displayName == "Claude")
}
