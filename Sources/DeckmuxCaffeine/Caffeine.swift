import Foundation

/// What the café looks at on each tick.
public struct CaffeineInput: Equatable, Sendable {
    public var now: Date
    /// Chats that count as working (`WorkRule`).
    public var workingChats: Int
    public var onBattery: Bool
    /// nil on a Mac without a battery.
    public var batteryPercent: Int?
    public var thermalCritical: Bool

    public init(now: Date, workingChats: Int, onBattery: Bool, batteryPercent: Int?, thermalCritical: Bool) {
        self.now = now
        self.workingChats = workingChats
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermalCritical = thermalCritical
    }
}

public enum CaffeineStopReason: Equatable, Sendable {
    case lastChatFinished, nothingStarted, lowBattery(Int), timeLimit, hot, user
}

public enum CaffeinePhase: Equatable, Sendable {
    case off
    /// On, no chat working yet.
    case waiting(since: Date)
    /// On with work; `idleSince` is when the last chat stopped (the grace).
    case active(since: Date, idleSince: Date?)
}

/// How a café run ended, for the notification.
public struct CaffeineSummary: Equatable, Sendable {
    public var reason: CaffeineStopReason
    public var onSince: Date
    public var offAt: Date
    public var peakChats: Int

    public init(reason: CaffeineStopReason, onSince: Date, offAt: Date, peakChats: Int) {
        self.reason = reason
        self.onSince = onSince
        self.offAt = offAt
        self.peakChats = peakChats
    }
}

/// Why the café would not turn on.
public enum CaffeineRefusal: Equatable, Sendable { case lowBattery(Int), hot }

/// Keeps the Mac awake while chats work and decides when to let it sleep.
public struct Caffeine: Equatable, Sendable {
    public static let idleGrace: TimeInterval = 60
    public static let startWait: TimeInterval = 120
    public static let minBattery = 20
    public static let maxDuration: TimeInterval = 12 * 3600

    public private(set) var phase: CaffeinePhase = .off
    public private(set) var onSince: Date?
    public private(set) var peakChats = 0

    public init() {}

    public var isOn: Bool { phase != .off }
    public var deadline: Date? { onSince.map { $0 + Self.maxDuration } }

    /// Refuses, without turning on, when the battery or the heat already rule it out.
    public mutating func turnOn(_ input: CaffeineInput) -> CaffeineRefusal? {
        if let refusal = Self.refusal(input) { return refusal }
        guard !isOn else { return nil }
        onSince = input.now
        peakChats = 0
        phase = .waiting(since: input.now)
        _ = update(input)
        return nil
    }

    /// The summary when the café turned itself off on this call.
    public mutating func update(_ input: CaffeineInput) -> CaffeineSummary? {
        guard isOn, let onSince else { return nil }
        peakChats = max(peakChats, input.workingChats)
        if let reason = Self.forcedStop(input, onSince: onSince) { return stop(reason, at: input.now) }
        switch phase {
        case .off:
            return nil
        case .waiting(let since):
            if input.workingChats > 0 {
                phase = .active(since: since, idleSince: nil)
            } else if input.now.timeIntervalSince(since) >= Self.startWait {
                return stop(.nothingStarted, at: input.now)
            }
        case .active(let since, let idleSince):
            if input.workingChats > 0 {
                phase = .active(since: since, idleSince: nil)
            } else if let idleSince {
                if input.now.timeIntervalSince(idleSince) >= Self.idleGrace { return stop(.lastChatFinished, at: input.now) }
            } else {
                phase = .active(since: since, idleSince: input.now)
            }
        }
        return nil
    }

    /// Turned off by the user; nil when it was already off.
    public mutating func turnOff(at now: Date) -> CaffeineSummary? {
        guard isOn else { return nil }
        return stop(.user, at: now)
    }

    private mutating func stop(_ reason: CaffeineStopReason, at now: Date) -> CaffeineSummary {
        let summary = CaffeineSummary(reason: reason, onSince: onSince ?? now, offAt: now, peakChats: peakChats)
        phase = .off
        onSince = nil
        return summary
    }

    private static func refusal(_ input: CaffeineInput) -> CaffeineRefusal? {
        if input.thermalCritical { return .hot }
        if let percent = lowBattery(input) { return .lowBattery(percent) }
        return nil
    }

    /// Heat, then battery, then the time limit.
    private static func forcedStop(_ input: CaffeineInput, onSince: Date) -> CaffeineStopReason? {
        if input.thermalCritical { return .hot }
        if let percent = lowBattery(input) { return .lowBattery(percent) }
        if input.now.timeIntervalSince(onSince) >= maxDuration { return .timeLimit }
        return nil
    }

    private static func lowBattery(_ input: CaffeineInput) -> Int? {
        guard input.onBattery, let percent = input.batteryPercent, percent < minBattery else { return nil }
        return percent
    }
}
