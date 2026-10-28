import Foundation

/// One of the account's limits as `/usage` reports it: how much is used
/// and when it renews.
public struct UsageWindow: Equatable, Sendable, Codable {
    public var percent: Double
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// The 5-hour and 7-day limits, and when they were fetched (the cache shows
/// the last value with "⚠ há N min").
public struct Usage: Equatable, Sendable, Codable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }
}

/// Reads the JSON of `GET /api/oauth/usage` (the endpoint behind `/usage`)
/// and the credentials file or Keychain item that holds the OAuth token.
public enum UsageParser {
    public enum Problem: Error, Equatable {
        case noWindows
        case malformed
    }

    /// `five_hour` / `seven_day` → windows; a reset already past means 0 % and no reset.
    public static func parse(_ data: Data, now: Date) throws -> Usage {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Problem.malformed }
        let usage = Usage(fiveHour: window(object["five_hour"], now: now), sevenDay: window(object["seven_day"], now: now), fetchedAt: now)
        guard usage.fiveHour != nil || usage.sevenDay != nil else { throw Problem.noWindows }
        return usage
    }

    private static func window(_ value: Any?, now: Date) -> UsageWindow? {
        guard let object = value as? [String: Any], let percent = (object["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (object["resets_at"] as? String).flatMap(date)
        if let resetsAt, resetsAt <= now { return UsageWindow(percent: 0, resetsAt: nil) }
        return UsageWindow(percent: percent, resetsAt: resetsAt)
    }

    /// Second precision: the fraction some responses carry is dropped.
    private static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// `claudeAiOauth.accessToken` of a credentials JSON (file or Keychain item).
    public static func accessToken(credentials: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// "renova 15:40" (hoje), "renova amanhã 09:10", "renova sáb" (depois), in pt-BR.
    public static func renewalText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        if calendar.isDate(resetsAt, inSameDayAs: now) { return "renova \(formatter.string(from: resetsAt))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(resetsAt, inSameDayAs: tomorrow) {
            return "renova amanhã \(formatter.string(from: resetsAt))"
        }
        formatter.dateFormat = "EEE"
        return "renova \(formatter.string(from: resetsAt).replacingOccurrences(of: ".", with: ""))"
    }
}
