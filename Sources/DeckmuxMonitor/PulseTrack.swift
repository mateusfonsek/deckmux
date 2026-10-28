import Foundation

/// What a terminal's Claude was doing when sampled. Ordered by
/// urgency: the worst sample of a minute is the one its bar shows.
public enum PulseSample: Int, Comparable, Sendable {
    case idle = 0
    case working = 1
    case waiting = 2

    public static func < (a: PulseSample, b: PulseSample) -> Bool { a.rawValue < b.rawValue }
}

/// The last 30 minutes of one terminal, sampled every 10 s and shown as one
/// bar per minute. A minute with no sample (the Mac slept, the app was not
/// running) stays empty: nothing is invented.
public struct PulseTrack: Equatable, Sendable {
    public static let sampleInterval: TimeInterval = 10
    public static let capacity = 180

    private var samples: [(date: Date, sample: PulseSample)] = []

    public init() {}

    public static func == (a: PulseTrack, b: PulseTrack) -> Bool {
        a.samples.count == b.samples.count && zip(a.samples, b.samples).allSatisfy { $0.date == $1.date && $0.sample == $1.sample }
    }

    public mutating func record(_ sample: PulseSample, at date: Date) {
        samples.append((date, sample))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// `count` bars of one minute each, oldest first; nil for a minute with no sample.
    public func minutes(now: Date, count: Int = 30) -> [PulseSample?] {
        (0..<count).map { i in
            let start = now.addingTimeInterval(-Double(count - i) * 60)
            let end = start.addingTimeInterval(60)
            return samples.lazy.filter { $0.date >= start && $0.date < end }.map(\.sample).max()
        }
    }
}
