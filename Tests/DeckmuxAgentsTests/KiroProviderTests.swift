import DeckmuxJSON
import Foundation
import Testing
@testable import DeckmuxAgents

private let kiro = KiroProvider()

@Test func kiroCommands() {
    #expect(kiro.launchCommand() == "kiro-cli\n")
    #expect(kiro.resumeCommand(sessionID: "abc") == "kiro-cli chat --resume-id 'abc'\n")
    #expect(kiro.workSignal == .hookTurns)
    #expect(kiro.hasTranscript(AgentSession(agent: .kiro, sessionID: "abc", directory: "/x"), home: URL(fileURLWithPath: "/"), environment: [:]) == nil)
}

@Test func kiroEvents() {
    #expect(kiro.event(hook: "session-start", payload: ["session_id": "abc", "cwd": "/x"]) == .sessionStarted(sessionID: "abc", cwd: "/x"))
    #expect(kiro.event(hook: "prompt", payload: [:]) == .turnStarted)
    #expect(kiro.event(hook: "stop", payload: [:]) == .turnFinished)
    #expect(kiro.event(hook: "session-end", payload: [:]) == .sessionEnded)
    // Kiro has no permission event.
    #expect(kiro.event(hook: "permission-request", payload: [:]) == nil)
}

@Test func kiroHookFileIsDeckmuxOwn() throws {
    let file = try #require(kiro.hookFile)
    #expect(file.relativePath == ".kiro/hooks/deckmux.json")
    let text = try #require(try file.edited(nil, install: true, agent: .kiro))
    let json = try JSONValue(parsing: text)
    #expect(json["version"]?.stringValue == "v1")
    let hooks = json["hooks"]?.arrayValue ?? []
    #expect(hooks.compactMap { $0["trigger"]?.stringValue } == ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"])
    #expect(hooks.first?["name"]?.stringValue == "deckmux-session-start")
    #expect(hooks.first?["action"]?["type"]?.stringValue == "command")
    #expect(hooks.first?["action"]?["command"]?.stringValue == AgentHookFile.command(agent: .kiro, event: "session-start"))
    #expect(hooks.first?["timeout"] == .number("5"))
    #expect(hooks.first?["enabled"] == .bool(true))
    #expect(try file.edited(text, install: false, agent: .kiro) == nil)
}

@Test func registryHasAllThree() {
    #expect(AgentRegistry.all.map(\.kind) == [.claude, .codex, .kiro])
}

/// Capabilities must be protocol requirements: read through `any AgentProvider`
/// (as the app does) an extension-only property would always be its default.
@Test func capabilitiesThroughTheRegistry() {
    #expect(AgentRegistry.provider(for: .codex).hookFile?.relativePath == ".codex/hooks.json")
    #expect(AgentRegistry.provider(for: .kiro).hookFile?.relativePath == ".kiro/hooks/deckmux.json")
    #expect(AgentRegistry.provider(for: .claude).hookFile == nil)
}
