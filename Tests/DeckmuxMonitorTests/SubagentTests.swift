import Foundation
import Testing
@testable import DeckmuxMonitor

@Test func encodesProjectFolder() {
    #expect(TranscriptPaths.projectFolderName(cwd: "/Users/f/src/github.com/MateusFonseK/fonsek.dev") == "-Users-f-src-github-com-MateusFonseK-fonsek-dev")
    #expect(TranscriptPaths.projectFolderName(cwd: "/private/tmp/claude-501/-Users-f/x_y z") == "-private-tmp-claude-501--Users-f-x-y-z")
    let home = URL(fileURLWithPath: "/h")
    #expect(TranscriptPaths.subagentsFolder(claudeHome: home, cwd: "/a/b", sessionID: "S").path == "/h/projects/-a-b/S/subagents")
}

@Test func finishedIsAssistantWithoutToolUse() {
    #expect(SubagentReader.isFinished(lastLine: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#))
    #expect(!SubagentReader.isFinished(lastLine: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]}}"#))
    #expect(!SubagentReader.isFinished(lastLine: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t"}]}}"#))
}

@Test func truncatedTailMeansRunning() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("agent-1.jsonl")
    try (#"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(SubagentReader.isFinished(transcript: file))
    try (#"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"# + "\n" + #"{"type":"assistant","message":{"con"#)
        .write(to: file, atomically: true, encoding: .utf8)
    #expect(!SubagentReader.isFinished(transcript: file))      // half a line: still writing
    #expect(!SubagentReader.isFinished(transcript: dir.appendingPathComponent("missing.jsonl")))
}

@Test func readsMetaAndOrdersNewestFirstWithinMaxAgeAndLimit() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    func agent(_ id: String, age: TimeInterval, finished: Bool) throws {
        try #"{"agentType":"Explore","description":"revisão do diff","toolUseId":"toolu_1","spawnDepth":1,"model":"opus"}"#
            .write(to: dir.appendingPathComponent("agent-\(id).meta.json"), atomically: true, encoding: .utf8)
        let line = finished ? #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#
                            : #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t"}]}}"#
        let url = dir.appendingPathComponent("agent-\(id).jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    for i in 0..<7 { try agent("a\(i)", age: Double(i) * 60, finished: i % 2 == 0) }
    try agent("old", age: 2 * 3600, finished: true)
    let agents = SubagentReader.read(folder: dir, now: now)
    #expect(agents.map(\.id) == ["a0", "a1", "a2", "a3", "a4"])
    #expect(agents[0].agentType == "Explore" && agents[0].description == "revisão do diff" && agents[0].model == "opus")
    #expect(agents[0].isFinished && !agents[1].isFinished)
    #expect(SubagentReader.read(folder: dir.appendingPathComponent("nope"), now: now).isEmpty)
}

// Review fix: on this Mac every finished subagent ends with a SubagentHandback
// call and its tool_result, not with a plain assistant message.
private let handback = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"SubagentHandback","input":{"message":"done"}}]}}"#
private let handbackResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":[{"type":"text","text":"{\"success\":true,\"message\":\"Report delivered to your caller.\"}"}]}]}}"#

@Test func handbackEndsTheAgent() throws {
    #expect(SubagentReader.isFinished(lastLines: [handback, handbackResult]))
    #expect(SubagentReader.isFinished(lastLines: [handback]))
    #expect(!SubagentReader.isFinished(lastLines: [#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t"}]}}"#]))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("agent-h.jsonl")
    try (#"{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}"# + "\n" + handback + "\n" + handbackResult + "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    #expect(SubagentReader.isFinished(transcript: file))
}
