import Foundation
import Testing
@testable import DeckmuxCaffeine

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func input(_ seconds: TimeInterval, chats: Int, battery: Int? = 80, onBattery: Bool = true, hot: Bool = false) -> CaffeineInput {
    CaffeineInput(now: t0 + seconds, workingChats: chats, onBattery: onBattery, batteryPercent: battery, thermalCritical: hot)
}

@Test func waitsThenGivesUpAfterTwoMinutes() {
    var c = Caffeine()
    #expect(c.turnOn(input(0, chats: 0)) == nil)
    #expect(c.phase == .waiting(since: t0))
    #expect(c.update(input(119, chats: 0)) == nil)
    #expect(c.update(input(120, chats: 0))?.reason == .nothingStarted)
    #expect(c.phase == .off)
}

@Test func waitingBecomesActiveWhenWorkStarts() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 0))
    #expect(c.update(input(30, chats: 2)) == nil)
    #expect(c.phase == .active(since: t0, idleSince: nil))
}

@Test func graceOfSixtySeconds() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    #expect(c.update(input(10, chats: 0)) == nil)
    #expect(c.update(input(69, chats: 0)) == nil)
    let s = c.update(input(70, chats: 0))
    #expect(s == CaffeineSummary(reason: .lastChatFinished, onSince: t0, offAt: t0 + 70, peakChats: 1))
}

@Test func workReturningResetsGrace() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    _ = c.update(input(10, chats: 0))
    _ = c.update(input(40, chats: 3))
    #expect(c.update(input(90, chats: 0)) == nil)
    #expect(c.update(input(150, chats: 0))?.peakChats == 3)
}

@Test func lowBatteryOnlyOnBattery() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    #expect(c.update(input(5, chats: 1, battery: 19, onBattery: false)) == nil)
    #expect(c.update(input(10, chats: 1, battery: 19))?.reason == .lowBattery(19))
}

@Test func turnOnRefusesLowBattery() {
    var c = Caffeine()
    #expect(c.turnOn(input(0, chats: 1, battery: 18)) == .lowBattery(18))
    #expect(c.phase == .off)
    #expect(c.turnOn(input(0, chats: 1, hot: true)) == .hot)
    #expect(!c.isOn)
}

@Test func timeLimitAndHeat() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    #expect(c.deadline == t0 + 12 * 3600)
    #expect(c.update(input(12 * 3600, chats: 1))?.reason == .timeLimit)
    var h = Caffeine()
    _ = h.turnOn(input(0, chats: 1))
    #expect(h.update(input(5, chats: 1, hot: true))?.reason == .hot)
}

@Test func heatWinsOverBatteryAndTime() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    #expect(c.update(input(13 * 3600, chats: 0, battery: 5, hot: true))?.reason == .hot)
}

@Test func clockJumpAppliesRules() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 1))
    #expect(c.update(input(13 * 3600, chats: 0))?.reason == .timeLimit)
}

@Test func userTurnOff() {
    var c = Caffeine()
    _ = c.turnOn(input(0, chats: 2))
    #expect(c.turnOff(at: t0 + 30)?.reason == .user)
    #expect(c.turnOff(at: t0 + 31) == nil)
    #expect(c.onSince == nil && c.deadline == nil)
}
