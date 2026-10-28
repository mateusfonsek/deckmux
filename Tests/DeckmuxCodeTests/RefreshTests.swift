import Foundation
import Testing
@testable import DeckmuxCode

@Test func ignoresLockAndObjectNoise() {
    let root = "/r"
    #expect(WatchFilter.isRelevant("/r/src/a.swift", root: root))
    #expect(WatchFilter.isRelevant("/r/.git/index", root: root))
    #expect(WatchFilter.isRelevant("/r/.git/HEAD", root: root))
    #expect(WatchFilter.isRelevant("/r/Cargo.lock", root: root))
    #expect(WatchFilter.isRelevant("/r/app/yarn.lock", root: root))
    #expect(!WatchFilter.isRelevant("/r/.git/index.lock", root: root))
    #expect(!WatchFilter.isRelevant("/r/.git/worktrees/w/index.lock", root: root))
    #expect(!WatchFilter.isRelevant("/r/.git/objects/ab/cdef", root: root))
    #expect(!WatchFilter.isRelevant("/r/.git/logs/HEAD", root: root))
    #expect(!WatchFilter.isRelevant("/r/x/.watchman-cookie-1", root: root))
}

@Test func debouncesAndThrottles() {
    var gate = RefreshGate()
    _ = gate.change(at: 0); _ = gate.change(at: 0.1)
    #expect(gate.change(at: 0.2) == 0.5)          // 300 ms after the last change
    gate.didRun(at: 0.5)
    #expect(gate.change(at: 0.6) == 1.5)          // at most once a second
}

@Test func continuousChangesStillRunEverySecond() {
    // A change every 0.1 s from t = 0; the refresh runs when it is due.
    var gate = RefreshGate()
    var runs: [Double] = []
    var due: Double?
    for tenth in 0...25 {
        let t = Double(tenth) / 10
        if let d = due, d <= t + 1e-9 {
            runs.append(d)
            gate.didRun(at: d)
            due = nil
        }
        due = gate.change(at: t)
    }
    #expect(runs.count == 2)
    #expect(abs(runs[0] - 1.0) < 1e-9)       // not postponed by the stream
    #expect(abs(runs[1] - 2.0) < 1e-9)       // and at most once a second
}
