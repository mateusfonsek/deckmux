import Foundation

/// CPU use per process: CPU time spent between two reads over the time
/// between them (100% = one core). A process read for the first time shows
/// 0%, and reads closer than a second keep the last value, as in cmux.
/// Not locked: use it from one serial queue.
public final class CPUTracker: @unchecked Sendable {
    private struct Sample {
        let cpuTime: UInt64
        let at: UInt64
        let percent: Double
    }

    private static let minimumWindow: UInt64 = 1_000_000_000
    private var samples: [Int: Sample] = [:]

    public init() {}

    /// `now` in nanoseconds (monotonic).
    public func percentages(for table: [Int: ProcessRecord], now: UInt64) -> [Int: Double] {
        var result: [Int: Double] = [:]
        var next: [Int: Sample] = [:]
        for (pid, process) in table {
            guard let previous = samples[pid], process.cpuTime >= previous.cpuTime, now > previous.at else {
                next[pid] = Sample(cpuTime: process.cpuTime, at: now, percent: 0)
                result[pid] = 0
                continue
            }
            let elapsed = now - previous.at
            if elapsed < Self.minimumWindow {
                next[pid] = previous
                result[pid] = previous.percent
                continue
            }
            let percent = Double(process.cpuTime - previous.cpuTime) / Double(elapsed) * 100
            next[pid] = Sample(cpuTime: process.cpuTime, at: now, percent: percent)
            result[pid] = percent
        }
        // Processes that ended drop out with the old dictionary.
        samples = next
        return result
    }
}
