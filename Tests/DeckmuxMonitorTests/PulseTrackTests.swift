import Foundation
import Testing
@testable import DeckmuxMonitor

private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

@Test func worstSampleOfEachMinuteWins() {
    var track = PulseTrack()
    for i in 0..<6 { track.record(i == 3 ? .waiting : .working, at: t0.addingTimeInterval(Double(i) * 10)) }
    for i in 6..<12 { track.record(.idle, at: t0.addingTimeInterval(Double(i) * 10)) }
    let bars = track.minutes(now: t0.addingTimeInterval(120), count: 2)
    #expect(bars == [.waiting, .idle])
}

@Test func gapsStayEmptyAfterSleep() {
    var track = PulseTrack()
    track.record(.working, at: t0)
    let now = t0.addingTimeInterval(40 * 60)           // asleep for 40 min
    track.record(.idle, at: now)
    let bars = track.minutes(now: now.addingTimeInterval(1), count: 30)
    #expect(bars.count == 30)
    #expect(bars.last == .idle)
    #expect(bars.dropLast().allSatisfy { $0 == nil })  // the sample from 40 min ago is outside the window
}

@Test func ringKeepsOnlyCapacity() {
    var track = PulseTrack()
    for i in 0..<(PulseTrack.capacity + 20) { track.record(.working, at: t0.addingTimeInterval(Double(i) * 10)) }
    let now = t0.addingTimeInterval(Double(PulseTrack.capacity + 20) * 10)
    #expect(track.minutes(now: now, count: 40).prefix(9).allSatisfy { $0 == nil })  // 40 min asked, 30 kept (+ partial)
    #expect(track.minutes(now: now, count: 30).allSatisfy { $0 == .working })
}

@Test func emptyTrackIsAllNil() {
    #expect(PulseTrack().minutes(now: t0) == Array(repeating: nil, count: 30))
}
