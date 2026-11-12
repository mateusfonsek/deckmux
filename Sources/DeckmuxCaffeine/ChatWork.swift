import Foundation
import DeckmuxMonitor

/// What keeps a chat counting as working.
public enum ChatWork: Equatable, Sendable {
    case idle
    /// Claude's spinner is in the title.
    case working
    /// Only background subagents are running.
    case subagents(Int)
}

public enum WorkRule {
    /// A subagent silent for longer than this is taken as dead.
    public static let staleSubagent: TimeInterval = 600

    /// A chat waiting on the user never counts; otherwise the title's spinner,
    /// then the live subagents.
    public static func work(titleWorking: Bool, needsInput: Bool, subagents: [SubagentInfo], now: Date) -> ChatWork {
        if needsInput { return .idle }
        if titleWorking { return .working }
        let live = subagents.filter { !$0.isFinished && now.timeIntervalSince($0.updatedAt) <= staleSubagent }.count
        return live > 0 ? .subagents(live) : .idle
    }
}
