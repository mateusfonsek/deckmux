import Foundation
import Testing
@testable import DeckmuxMonitor

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Test func parsesBothWindowsWithFractionalSeconds() throws {
    let json = #"{"five_hour":{"utilization":42,"resets_at":"2026-10-20T18:40:00.123456+00:00"},"seven_day":{"utilization":83.4,"resets_at":"2026-10-24T12:00:00Z"}}"#
    let now = iso("2026-10-20T15:00:00Z")
    let usage = try UsageParser.parse(Data(json.utf8), now: now)
    #expect(usage.fiveHour?.percent == 42)
    #expect(usage.fiveHour?.resetsAt == iso("2026-10-20T18:40:00Z"))
    #expect(usage.sevenDay?.percent == 83.4)
    #expect(usage.fetchedAt == now)
}

@Test func pastResetMeansZero() throws {
    let json = #"{"five_hour":{"utilization":70,"resets_at":"2026-10-20T10:00:00Z"}}"#
    let usage = try UsageParser.parse(Data(json.utf8), now: iso("2026-10-20T15:00:00Z"))
    #expect(usage.fiveHour == UsageWindow(percent: 0, resetsAt: nil))
    #expect(usage.sevenDay == nil)
}

@Test func windowWithoutResetKeepsPercent() throws {
    let usage = try UsageParser.parse(Data(#"{"seven_day":{"utilization":12}}"#.utf8), now: Date())
    #expect(usage.sevenDay == UsageWindow(percent: 12, resetsAt: nil))
}

@Test func noWindowsIsAnError() {
    #expect(throws: UsageParser.Problem.noWindows) { try UsageParser.parse(Data(#"{"ok":true}"#.utf8), now: Date()) }
    #expect(throws: UsageParser.Problem.malformed) { try UsageParser.parse(Data("nope".utf8), now: Date()) }
}

@Test func readsAccessToken() {
    #expect(UsageParser.accessToken(credentials: Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r"}}"#.utf8)) == "sk-ant-oat01-abc")
}

@Test func tokenMissingWhenShapeDiffers() {
    #expect(UsageParser.accessToken(credentials: Data(#"{"apiKey":"x"}"#.utf8)) == nil)
    #expect(UsageParser.accessToken(credentials: Data("{".utf8)) == nil)
}

@Test func renewalTexts() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    calendar.locale = Locale(identifier: "pt_BR")
    let now = iso("2026-10-20T15:00:00-03:00")   // terça
    #expect(UsageParser.renewalText(now.addingTimeInterval(40 * 60), now: now, calendar: calendar) == "renova 15:40")
    #expect(UsageParser.renewalText(now.addingTimeInterval(18 * 3600 + 10 * 60), now: now, calendar: calendar) == "renova amanhã 09:10")
    #expect(UsageParser.renewalText(now.addingTimeInterval(4 * 86400), now: now, calendar: calendar) == "renova sáb")
}

@Test func usageRoundTripsThroughJSON() throws {
    let usage = Usage(fiveHour: UsageWindow(percent: 42, resetsAt: iso("2026-10-20T18:40:00Z")), sevenDay: nil, fetchedAt: iso("2026-10-20T15:00:00Z"))
    let data = try JSONEncoder().encode(usage)
    #expect(try JSONDecoder().decode(Usage.self, from: data) == usage)
}
