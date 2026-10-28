import AppKit
import DeckmuxCalendar
import EventKit

/// The Mac's calendars (EventKit): every account added to the Mac or to
/// Calendar (iCloud, Google, Exchange…), with no setup in Deckmux but the
/// calendar permission. This is the agenda's default source.
@MainActor
final class MacCalendarSource {
    enum Access { case notDetermined, denied, granted }

    /// Called when anything changes in Calendar's database.
    var onChange: (() -> Void)?

    private var store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        // writeOnly cannot read events; restricted is set by the Mac's admin.
        default: .denied
        }
    }

    func requestAccess() async -> Access {
        _ = try? await store.requestFullAccessToEvents()
        // A store made before the grant does not see the calendars.
        store = EKEventStore()
        return access
    }

    /// Meetings that overlap `from`…`from + days`, with the same filters as
    /// Google's: no all-day events, nothing cancelled or declined.
    func meetings(from: Date, days: Int, workspaceOf: (String?) -> String?) -> [Meeting] {
        guard access == .granted else { return [] }
        let end = from.addingTimeInterval(Double(days) * 86_400)
        let predicate = store.predicateForEvents(withStart: from, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            guard MeetingMerge.keep(isAllDay: event.isAllDay, isCancelled: event.status == .canceled, declinedBySelf: declined),
                  let start = event.startDate, let finish = event.endDate else { return nil }
            let account = Self.account(of: event.calendar)
            return Meeting(
                id: "\(event.calendarItemIdentifier)-\(start.timeIntervalSince1970)",
                title: event.title ?? "",
                start: start, end: finish,
                joinURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
                openURL: event.calendarItemExternalIdentifier
                    .flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }
                    .flatMap { URL(string: "ical://ekevent/\($0)") },
                accountEmail: account, workspaceSlug: workspaceOf(account), source: .mac
            )
        }
    }

    /// Whether a Google account is on the Mac: a CalDAV account named by an
    /// e-mail (Contas de Internet names Google accounts, or their main
    /// calendar, with the address).
    var hasGoogleAccount: Bool {
        guard access == .granted else { return false }
        return store.calendars(for: .event).contains { calendar in
            calendar.source?.sourceType == .calDAV && Self.account(of: calendar) != nil
        }
    }

    private static func account(of calendar: EKCalendar?) -> String? {
        MeetingLink.email(in: [calendar?.source?.title, calendar?.title])
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }
}
