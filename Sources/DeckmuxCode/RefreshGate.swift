import Foundation

/// Debounce plus throttle for refreshes: waits `debounce` after the last change,
/// never runs twice within `minInterval`, and never lets a stream of changes
/// postpone a run by more than `minInterval` (Claude editing nonstop still sees
/// the list move, about once a second).
public struct RefreshGate: Sendable {
    public let debounce: TimeInterval
    public let minInterval: TimeInterval
    private var lastRun: TimeInterval?
    /// The first change since the last run.
    private var firstPending: TimeInterval?

    public init(debounce: TimeInterval = 0.3, minInterval: TimeInterval = 1) {
        self.debounce = debounce
        self.minInterval = minInterval
    }

    /// Returns the instant the refresh should run; the caller reschedules to it.
    public mutating func change(at time: TimeInterval) -> TimeInterval {
        if firstPending == nil { firstPending = time }
        var due = min(time + debounce, (firstPending ?? time) + minInterval)
        if let lastRun { due = max(due, lastRun + minInterval) }
        return due
    }

    public mutating func didRun(at time: TimeInterval) {
        lastRun = time
        firstPending = nil
    }
}
