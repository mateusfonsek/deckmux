import Foundation
import Testing
import DeckmuxMonitor
@testable import DeckmuxCaffeine

private let now = Date(timeIntervalSince1970: 2_000_000)

private enum State { case running, finished }

private func agent(_ state: State, ago seconds: TimeInterval) -> SubagentInfo {
    SubagentInfo(id: UUID().uuidString, agentType: "general-purpose", description: "", model: nil,
                 startedAt: now - seconds - 10, updatedAt: now - seconds, isFinished: state == .finished)
}

@Test func needsInputNeverCounts() {
    #expect(WorkRule.work(titleWorking: true, needsInput: true, subagents: [agent(.running, ago: 5)], now: now) == .idle)
}

@Test func titleWorkingWins() {
    #expect(WorkRule.work(titleWorking: true, needsInput: false, subagents: [agent(.running, ago: 5)], now: now) == .working)
}

@Test func liveSubagentsCount() {
    let agents = [agent(.running, ago: 30), agent(.running, ago: 599), agent(.finished, ago: 1)]
    #expect(WorkRule.work(titleWorking: false, needsInput: false, subagents: agents, now: now) == .subagents(2))
}

@Test func staleSubagentIsDead() {
    #expect(WorkRule.work(titleWorking: false, needsInput: false, subagents: [agent(.running, ago: 601)], now: now) == .idle)
}

@Test func nothingIsIdle() {
    #expect(WorkRule.work(titleWorking: false, needsInput: false, subagents: [], now: now) == .idle)
}
