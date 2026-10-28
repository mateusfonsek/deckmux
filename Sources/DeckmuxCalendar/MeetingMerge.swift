import Foundation

public enum MeetingMerge {
    /// Google's events (API) and the Mac's, as one agenda by start time. An
    /// account with a Google login comes from the API, which has the Meet link
    /// for sure, so the Mac's copy of that account is left out; an event the
    /// Mac still repeats (same title and start) keeps the Google one.
    public static func merge(google: [Meeting], mac: [Meeting], googleAccounts: Set<String>) -> [Meeting] {
        let accounts = Set(googleAccounts.map { $0.lowercased() })
        let seen = Set(google.map { Key(title: $0.title, start: $0.start) })
        let macOnly = mac.filter { event in
            !(event.accountEmail.map(accounts.contains) ?? false) && !seen.contains(Key(title: event.title, start: event.start))
        }
        return (google + macOnly).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Same rule for both sources: no all-day events, nothing cancelled or
    /// declined.
    public static func keep(isAllDay: Bool, isCancelled: Bool, declinedBySelf: Bool) -> Bool {
        !isAllDay && !isCancelled && !declinedBySelf
    }

    private struct Key: Hashable {
        let title: String
        let start: Date
    }
}
