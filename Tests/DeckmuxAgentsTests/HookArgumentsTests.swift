import Testing
@testable import DeckmuxAgents

@Test func hookArgumentsWithAgent() {
    #expect(HookArguments.parse(["claude", "stop"])! == (.claude, "stop"))
    #expect(HookArguments.parse(["codex", "prompt"])! == (.codex, "prompt"))
}

@Test func hookArgumentsLegacyMeansClaude() {
    #expect(HookArguments.parse(["stop"])! == (.claude, "stop"))
}

@Test func hookArgumentsInvalid() {
    #expect(HookArguments.parse(["xyz", "stop"]) == nil)
    #expect(HookArguments.parse([]) == nil)
    #expect(HookArguments.parse(["codex"]) == nil)
}
