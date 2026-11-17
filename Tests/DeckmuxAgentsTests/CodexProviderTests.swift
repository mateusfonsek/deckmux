import Foundation
import Testing
@testable import DeckmuxAgents

private let codex = CodexProvider()

@Test func codexCommands() {
    #expect(codex.launchCommand() == "codex\n")
    #expect(codex.resumeCommand(sessionID: "019a-b") == "codex resume '019a-b'\n")
    #expect(codex.workSignal == .hookTurns)
    #expect(codex.executable == "codex")
}

@Test func codexEvents() {
    let start = ["session_id": "019a", "cwd": "/x", "hook_event_name": "SessionStart", "source": "startup"]
    #expect(codex.event(hook: "session-start", payload: start) == .sessionStarted(sessionID: "019a", cwd: "/x"))
    #expect(codex.event(hook: "prompt", payload: [:]) == .turnStarted)
    #expect(codex.event(hook: "stop", payload: [:]) == .turnFinished)
    #expect(codex.event(hook: "permission-request", payload: ["tool_name": "shell"]) == .needsInput("Quer usar shell"))
    #expect(codex.event(hook: "session-end", payload: [:]) == .sessionEnded)
    #expect(codex.event(hook: "notification", payload: [:]) == nil)
}

@Test func codexTranscript() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = AgentSession(agent: .codex, sessionID: "c1", directory: "/x")
    #expect(codex.hasTranscript(session, home: home, environment: [:]) == nil)
    let day = home.appendingPathComponent(".codex/sessions/2026/11/17")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    #expect(codex.hasTranscript(session, home: home, environment: [:]) == false)
    try Data().write(to: day.appendingPathComponent("rollout-2026-11-17T10-00-00-c1.jsonl"))
    #expect(codex.hasTranscript(session, home: home, environment: [:]) == true)
    // CODEX_HOME wins over ~/.codex.
    #expect(codex.hasTranscript(session, home: home, environment: ["CODEX_HOME": home.appendingPathComponent("none").path]) == nil)
}

@Test func codexHookFile() {
    let file = codex.hookFile
    #expect(file?.relativePath == ".codex/hooks.json")
    #expect(file?.format == .claudeStyle)
    #expect(file?.events.map(\.native) == ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd"])
}
