import Foundation
import Testing
@testable import DeckmuxMonitor

private let tokenCount = #"{"timestamp":"2026-11-17T14:53:47.005Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1794884336},"secondary":{"used_percent":48.0,"window_minutes":10080,"resets_at":1794891569}}}}"#
private let older = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1}}}}"#

@Test func codexUsageFromTheLastRateLimits() throws {
    let now = Date(timeIntervalSince1970: 1_794_880_000)
    let jsonl = [older, #"{"type":"response_item","payload":{}}"#, tokenCount].joined(separator: "\n")
    let usage = try #require(CodexUsage.parse(jsonl: jsonl, fetchedAt: now))
    #expect(usage.fiveHour == UsageWindow(percent: 2.0, resetsAt: Date(timeIntervalSince1970: 1_794_884_336)))
    #expect(usage.sevenDay == UsageWindow(percent: 48.0, resetsAt: Date(timeIntervalSince1970: 1_794_891_569)))
    #expect(usage.fetchedAt == now)
}

@Test func codexUsageWithoutRateLimitsIsNil() {
    #expect(CodexUsage.parse(jsonl: #"{"type":"response_item","payload":{}}"#, fetchedAt: Date()) == nil)
}

@Test func codexUsageIgnoresATruncatedLastLine() throws {
    let jsonl = tokenCount + "\n" + #"{"type":"event_msg","payload":{"type":"token_count","rate_li"#
    #expect(try #require(CodexUsage.parse(jsonl: jsonl, fetchedAt: Date())).fiveHour?.percent == 2.0)
}

@Test func codexUsageFindsTheNewestSession() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = home.appendingPathComponent("sessions/2026/11/16"), b = home.appendingPathComponent("sessions/2026/11/17")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let old = a.appendingPathComponent("rollout-a.jsonl"), new = b.appendingPathComponent("rollout-b.jsonl")
    try Data(older.utf8).write(to: old)
    try Data(tokenCount.utf8).write(to: new)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
    #expect(CodexUsage.latestSessionFile(codexHome: home)?.lastPathComponent == "rollout-b.jsonl")
    #expect(CodexUsage.latestSessionFile(codexHome: home.appendingPathComponent("none")) == nil)
}
