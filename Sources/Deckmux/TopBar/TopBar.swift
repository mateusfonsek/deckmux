import AppKit
import Combine
import DeckmuxCalendar
import SwiftUI

/// Meetings from the Mac's calendars and from every workspace with a Google
/// login: the next one for the top bar and today's for Hoje. Events are
/// fetched from the start of today every few minutes (and at once when
/// Calendar changes); which one is "next" is worked out again every minute
/// from what was fetched, so a meeting that ends gives way to the following
/// one without waiting for the network.
@MainActor
final class NextMeetingModel: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var events: [Meeting] = []
    /// Whether Deckmux may read the Mac's calendars.
    @Published private(set) var calendarAccess: MacCalendarSource.Access
    /// Some workspace has a Google login (the API, with the Meet link).
    @Published private(set) var hasGoogleToken = false
    /// A Google account is among the Mac's calendars.
    @Published private(set) var hasGoogleOnMac = false
    /// Accounts whose last fetch failed, with the reason.
    @Published private(set) var failures: [String: String] = [:]
    /// Hoje's agenda guide is on screen (first visit, help button, top bar).
    @Published var guidePresented = false

    private let store: WorkspaceStore
    private let client = GoogleCalendarClient()
    private let mac = MacCalendarSource()
    private var clock: Timer?
    private var fetchTimer: Timer?
    private var observers: [AnyCancellable] = []
    private var wakeObserver: NSObjectProtocol?
    private var fetching = false
    /// A refresh asked for while one was running: runs when it ends.
    private var pending = false

    static let fetchInterval: TimeInterval = 5 * 60

    init(store: WorkspaceStore) {
        self.store = store
        calendarAccess = mac.access
        mac.onChange = { [weak self] in self?.refresh() }
        // Workspaces appearing or a new Google login change the accounts.
        observers.append(store.$workspaces.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        startClock()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        fetchTimer?.tolerance = 30
    }

    /// There is somewhere to read meetings from.
    var hasSources: Bool { calendarAccess == .granted || hasGoogleToken }

    /// The meeting to show: the one in progress, or else the next to start.
    var next: Meeting? {
        events.filter { $0.end > now }.min { $0.start < $1.start }
    }

    /// Every meeting overlapping the day of `now`, by start time.
    var today: [Meeting] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && $0.end > start }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Meetings of today that have not ended yet.
    var remainingToday: Int { today.filter { $0.end > now }.count }

    func workspace(of event: Meeting) -> Workspace? {
        event.workspaceSlug.flatMap { store.workspace(slug: $0) }
    }

    func requestCalendarAccess() {
        Task {
            calendarAccess = await mac.requestAccess()
            refresh()
        }
    }

    func openCalendarSettings() { mac.openSettings() }

    func refresh() {
        calendarAccess = mac.access
        hasGoogleOnMac = mac.hasGoogleAccount
        let accounts = GoogleCalendarClient.accounts(in: store.workspaces)
        hasGoogleToken = !accounts.isEmpty
        guard !fetching else { pending = true; return }
        fetching = true
        // A Mac calendar of the same account as a workspace's Google login takes that workspace's color.
        var slugs: [String: String] = [:]
        for workspace in store.workspaces {
            if let email = workspace.manifest.google?.email?.lowercased() { slugs[email] = workspace.id }
        }
        for account in accounts { slugs[account.email.lowercased()] = account.slug }
        // From midnight, so Hoje also shows the meetings already over.
        let fromMac = mac.meetings(from: Calendar.current.startOfDay(for: Date()), days: 8) { $0.flatMap { slugs[$0] } }
        Task {
            let (collected, failed) = await Self.fetch(accounts, client: client)
            // A failed account keeps its last known events instead of vanishing.
            let failedAccounts = Set(failed.keys.map { $0.lowercased() })
            let kept = events.filter { $0.source == .google && $0.accountEmail.map(failedAccounts.contains) == true }
            events = MeetingMerge.merge(google: collected + kept, mac: fromMac, googleAccounts: Set(accounts.map(\.email)))
            failures = failed
            fetching = false
            if pending {
                pending = false
                refresh()
            }
        }
    }

    /// Every account's events, fetched in parallel by one task per account.
    /// Not a task group: `withTaskGroup` here crashed release builds at random
    /// seconds after launch (swift::TaskGroup::offer, EXC_BAD_ACCESS).
    nonisolated private static func fetch(
        _ accounts: [GoogleCalendarClient.Account], client: GoogleCalendarClient
    ) async -> ([Meeting], [String: String]) {
        // From midnight, so Hoje also shows the meetings already over.
        let from = Calendar.current.startOfDay(for: Date())
        let tasks = accounts.map { account in
            (account.email, Task { try await client.upcomingEvents(for: account, now: from, days: 8) })
        }
        var collected: [Meeting] = []
        var failed: [String: String] = [:]
        for (email, task) in tasks {
            do { collected += try await task.value }
            catch { failed[email] = error.localizedDescription }
        }
        return (collected, failed)
    }

    /// Ticks on each new minute, so the clock and "agora" stay exact.
    private func startClock() {
        clock?.invalidate()
        now = Date()
        let seconds = Calendar.current.component(.second, from: now)
        let timer = Timer(fire: now.addingTimeInterval(Double(60 - seconds)), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // Up to half a second late, so the system can group the wakeup with others.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }
}

/// The strip at the top of the window, where the titlebar was: the date and
/// time on the left, the next meeting on the right. Empty parts move the
/// window, as a titlebar does.
struct TopBarView: View {
    @ObservedObject var model: NextMeetingModel
    let showAgenda: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(TopBarFormat.clock(model.now))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .allowsHitTesting(false)
            Spacer(minLength: 12)
            meeting
        }
        .padding(.horizontal, 14)
        .frame(height: TopBarFormat.height)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    @ViewBuilder private var meeting: some View {
        if !model.hasSources {
            Button(action: showAgenda) {
                Label("Mostrar agenda", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.plain)
            .font(Theme.Font.secondary)
            .foregroundStyle(.secondary)
            .help("Mostre as reuniões do Calendário do Mac na barra do topo")
        } else if let event = model.next {
            MeetingButton(event: event, workspace: model.workspace(of: event), now: model.now, failures: model.failures)
        } else if !model.failures.isEmpty {
            Label("Agenda indisponível", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.secondary)
                .foregroundStyle(.orange)
                .help(model.failures.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        } else {
            Text("Sem reuniões nos próximos 7 dias")
                .font(Theme.Font.secondary)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The next meeting as a chip. It turns into a call to action ("Entrar")
/// from 10 minutes before until it ends.
private struct MeetingButton: View {
    let event: Meeting
    let workspace: Workspace?
    let now: Date
    let failures: [String: String]
    @State private var hovered = false

    private var color: Color { workspace?.color ?? .secondary }
    private var inProgress: Bool { event.start <= now }
    private var isSoon: Bool { inProgress || event.start.timeIntervalSince(now) <= 10 * 60 }

    var body: some View {
        HStack(spacing: 8) {
            if !failures.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(failures.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
            }
            Button(action: event.open) {
                HStack(spacing: 7) {
                    if inProgress {
                        Text("Agora").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.now)
                    } else {
                        Text("Próxima").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(event.title).foregroundStyle(.primary).fontWeight(.medium).lineLimit(1)
                    Text(TopBarFormat.when(event, now: now)).foregroundStyle(.secondary).monospacedDigit()
                    if let relative = TopBarFormat.relative(event, now: now) {
                        Text(relative).foregroundStyle(isSoon ? color : .secondary).fontWeight(isSoon ? .semibold : .regular)
                    }
                    if event.joinURL != nil {
                        if isSoon {
                            Label("Entrar", systemImage: "video.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(color))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(.leading, 10)
                .padding(.trailing, event.joinURL != nil && isSoon ? 4 : 10)
                .frame(height: 26)
                .background(Capsule().fill(color.opacity(isSoon ? 0.16 : hovered ? 0.10 : 0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(tooltip)
        }
    }

    private var tooltip: String {
        let range = "\(TopBarFormat.time(event.start))–\(TopBarFormat.time(event.end))"
        let target = event.joinURL != nil ? "Clique para entrar na reunião" : "Clique para abrir na agenda"
        return "\(event.title)\n\(range) · \(event.origin(in: workspace))\n\(target)"
    }
}

@MainActor
enum TopBarFormat {
    static let height: CGFloat = Theme.topBarHeight

    private static let locale = Locale(identifier: "pt_BR")
    /// One formatter per pattern: making one costs more than formatting
    /// with it, and Hoje formats every card on every render.
    private static var formatters: [String: DateFormatter] = [:]

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter: DateFormatter
        if let cached = formatters[pattern] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = pattern
            formatters[pattern] = formatter
        }
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    /// "qua, 15 out · 17:20"
    static func clock(_ date: Date) -> String {
        "\(format("EEE, d MMM", date)) · \(time(date))"
    }

    static func time(_ date: Date) -> String { format("HH:mm", date) }

    /// "em 25 min", "em 1 h 10" within two hours; nil further away or during it.
    static func relative(_ event: Meeting, now: Date) -> String? {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0, minutes <= 120 else { return nil }
        if minutes < 60 { return "em \(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "em \(minutes / 60) h" : "em \(minutes / 60) h \(String(format: "%02d", rest))"
    }

    /// "09:30", "09:30 (amanhã)", "09:30 (sex, 17 out)" or, during the
    /// meeting, "até 10:00".
    static func when(_ event: Meeting, now: Date) -> String {
        if event.start <= now { return "até \(time(event.end))" }
        let calendar = Calendar.current
        if calendar.isDate(event.start, inSameDayAs: now) { return time(event.start) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(event.start, inSameDayAs: tomorrow) {
            return "\(time(event.start)) (amanhã)"
        }
        return "\(time(event.start)) (\(format("EEE, d MMM", event.start)))"
    }
}

extension Meeting {
    /// Where the meeting comes from, for tooltips: "Workspace (conta)".
    func origin(in workspace: Workspace?) -> String {
        let account = accountEmail ?? (source == .mac ? "Calendário do Mac" : nil)
        return switch (workspace?.name, account) {
        case let (name?, account?): "\(name) (\(account))"
        case let (name?, nil): name
        case let (nil, account?): account
        case (nil, nil): ""
        }
    }

    /// The call link, or else the event in Google Calendar or Calendar.
    func open() {
        if let url = joinURL ?? openURL, NSWorkspace.shared.open(url) { return }
        // A Mac event Calendar cannot show by its link: at least open Calendar.
        if source == .mac, let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendar, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
