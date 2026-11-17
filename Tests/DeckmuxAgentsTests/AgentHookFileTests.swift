import DeckmuxJSON
import Foundation
import Testing
@testable import DeckmuxAgents

private let file = CodexProvider().hookFile!
private let deckmuxStop = #"[ -x "$DECKMUX_CLI" ] && "$DECKMUX_CLI" hook codex stop || true"#

private func commands(_ text: String?, event: String) throws -> [String] {
    let json = try JSONValue(parsing: text ?? "{}")
    return (json["hooks"]?[event]?.arrayValue ?? []).flatMap { group in
        (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
    }
}

@Test func installsIntoEmptyFile() throws {
    let text = try file.edited(nil, install: true, agent: .codex)
    #expect(try commands(text, event: "Stop") == [deckmuxStop])
    #expect(try commands(text, event: "UserPromptSubmit") == [#"[ -x "$DECKMUX_CLI" ] && "$DECKMUX_CLI" hook codex prompt || true"#])
    for event in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", "SessionEnd"] {
        #expect(try commands(text, event: event).count == 1)
    }
    #expect(text?.contains(#""timeout": 5"#) == true)
}

@Test func keepsTheUsersHooks() throws {
    let user = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
    let installed = try file.edited(user, install: true, agent: .codex)
    #expect(try commands(installed, event: "Stop") == ["say done", deckmuxStop])
    // Installing again does not duplicate.
    let again = try file.edited(installed, install: true, agent: .codex)
    #expect(try commands(again, event: "Stop") == ["say done", deckmuxStop])
    // Removing leaves only the user's.
    let removed = try file.edited(again, install: false, agent: .codex)
    #expect(try commands(removed, event: "Stop") == ["say done"])
    #expect(try commands(removed, event: "SessionStart") == [])
}

@Test func removingOnlyDeckmuxHooksDeletesTheFile() throws {
    let installed = try file.edited(nil, install: true, agent: .codex)
    #expect(try file.edited(installed, install: false, agent: .codex) == nil)
    #expect(try file.edited(nil, install: false, agent: .codex) == nil)
}
