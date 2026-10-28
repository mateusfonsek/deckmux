import AppKit
import SwiftUI

/// Hoje: today's meetings of every workspace on a timeline on the
/// left; on the right, the terminals waiting for the user, the workspaces and
/// the task board.
struct TodayView: View {
    @ObservedObject var deck: Deck
    @ObservedObject var meetings: NextMeetingModel
    let tasks: TasksModel

    static let agendaWidth: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            AgendaColumn(model: meetings) { deck.showWorkspacesTab() }
                .frame(width: Self.agendaWidth)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                TodayStrip(deck: deck)
                Divider()
                TasksBoard(model: tasks, deck: deck)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // SwiftUI's default tint is system blue; buttons follow the app's graphite.
        .tint(Color.deckAccent)
    }
}

// MARK: Agenda

private struct AgendaColumn: View {
    @ObservedObject var model: NextMeetingModel
    let openWorkspaces: () -> Void

    var body: some View {
        let events = model.today
        let day = DayLayout(events: events, now: model.now)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hoje").font(Theme.Font.largeTitle)
                Text(TodayFormat.longDate(model.now).capitalizingFirstLetter).font(Theme.Font.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !model.failures.isEmpty {
                Label("Agenda incompleta", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(model.failures.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider()

            if !model.hasAccounts {
                VStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text("Conecte uma conta Google na aba Workspaces para ver a agenda.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Abrir Workspaces", action: openWorkspaces)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Timeline(day: day, now: model.now) { model.workspace(of: $0) }
                Divider()
                Text(TodayFormat.free(day.freeSlots, meetings: events.count, now: model.now, dayEnd: day.workdayEnd))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct Timeline: View {
    let day: DayLayout
    let now: Date
    let workspace: (GoogleCalendarClient.Event) -> Workspace?

    static let hourHeight: CGFloat = 60
    static let gutter: CGFloat = 48

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(day.hours, id: \.self) { hour in
                            HourRow(hour: hour).frame(height: Self.hourHeight).id(hour)
                        }
                    }
                    GeometryReader { geometry in
                        let width = geometry.size.width - Self.gutter - 10
                        ForEach(day.placed, id: \.event.id) { placed in
                            let column = width / CGFloat(placed.columns)
                            EventCard(placed: placed, workspace: workspace(placed.event), now: now)
                                .frame(width: max(column - 3, 10), height: max(y(placed.end) - y(placed.start) - 2, 18))
                                .offset(x: Self.gutter + column * CGFloat(placed.column), y: y(placed.start) + 1)
                        }
                        if let nowY = day.contains(now) ? y(now) : nil {
                            NowLine().frame(width: geometry.size.width - Self.gutter + 6).offset(x: Self.gutter - 6, y: nowY - 4)
                        }
                    }
                }
                .frame(height: CGFloat(day.hours.count) * Self.hourHeight)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .onAppear { proxy.scrollTo(day.scrollHour(now: now), anchor: .top) }
        }
    }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(day.start) / 3600) * Self.hourHeight
    }
}

private struct HourRow: View {
    let hour: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(String(format: "%02d:00", hour % 24))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Timeline.gutter - 8, alignment: .trailing)
                .offset(y: -6)
            VStack { Divider() }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct NowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }
}

private struct EventCard: View {
    let placed: DayLayout.Placed
    let workspace: Workspace?
    let now: Date

    @State private var hovered = false

    private var event: GoogleCalendarClient.Event { placed.event }
    private var color: Color { workspace?.color ?? .secondary }
    private var isPast: Bool { event.end <= now }
    private var isShort: Bool { placed.end.timeIntervalSince(placed.start) < 40 * 60 }

    var body: some View {
        Button(action: event.open) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                content.padding(.horizontal, 6).padding(.vertical, isShort ? 1 : 4)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(color.opacity(hovered ? 0.30 : 0.20))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isPast ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tooltip)
    }

    @ViewBuilder private var content: some View {
        let range = "\(TopBarFormat.time(event.start))–\(TopBarFormat.time(event.end))"
        if isShort {
            HStack(spacing: 4) {
                title
                Text(TopBarFormat.time(event.start)).foregroundStyle(.secondary).monospacedDigit()
                badges
            }
            .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                title.font(.system(size: 12, weight: .semibold))
                HStack(spacing: 4) {
                    Text(range).monospacedDigit()
                    badges
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var title: some View {
        Text(event.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder private var badges: some View {
        if event.meetURL != nil { Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
        if !placed.conflicts.isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange) }
    }

    private var tooltip: String {
        var lines = [event.title, "\(TopBarFormat.time(event.start))–\(TopBarFormat.time(event.end)) · \(workspace?.name ?? "") (\(event.accountEmail))"]
        if !placed.conflicts.isEmpty { lines.append("Conflito com: " + placed.conflicts.joined(separator: ", ")) }
        lines.append(event.meetURL != nil ? "Clique para entrar na reunião" : "Clique para abrir no Google Calendar")
        return lines.joined(separator: "\n")
    }
}

// MARK: Strip

/// "Precisa de você" and the workspaces, above the board.
private struct TodayStrip: View {
    @ObservedObject var deck: Deck

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("PRECISA DE VOCÊ") {
                let waiting = deck.items.filter { $0.attention != nil }
                if waiting.isEmpty {
                    Text("Nenhum terminal esperando você").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    ForEach(waiting) { item in AttentionChip(item: item, workspace: deck.workspace(of: item), deck: deck) }
                }
            }
            row("WORKSPACES") {
                if deck.workspaces.workspaces.isEmpty {
                    Button("Criar ou escolher workspaces") { deck.showWorkspacesTab() }.buttonStyle(.link).font(.system(size: 12))
                }
                ForEach(deck.workspaces.workspaces) { workspace in
                    WorkspaceChip(workspace: workspace, count: deck.items(in: workspace).count) {
                        if let first = deck.items(in: workspace).first { deck.select(first) } else { deck.add(in: workspace) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.Font.section)
                .foregroundStyle(.tertiary)
                .frame(width: 120, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
            }
        }
    }
}

private struct AttentionChip: View {
    @ObservedObject var item: DeckItem
    let workspace: Workspace?
    let deck: Deck

    var body: some View {
        if let attention = item.attention {
            Chip(help: "\(workspace.map { "\($0.name) · " } ?? "")\(item.displayName)\n\(TodayFormat.attention(attention.kind, full: true))\nClique para ir ao terminal") {
                deck.reveal(terminal: attention.terminal)
            } label: {
                Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.orange)
                if let workspace { Circle().fill(workspace.color).frame(width: 6, height: 6) }
                Text(item.displayName).lineLimit(1)
                Text("· " + TodayFormat.attention(attention.kind, full: false)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct WorkspaceChip: View {
    let workspace: Workspace
    let count: Int
    let action: () -> Void

    var body: some View {
        Chip(help: count == 0 ? "Abrir um terminal em \(workspace.name)" : "Ir para \(workspace.name)", action: action) {
            Circle().fill(workspace.color).frame(width: 7, height: 7)
            Text(workspace.name).foregroundStyle(workspace.color).fontWeight(.medium)
            Text(count == 0 ? "+" : count == 1 ? "1 terminal" : "\(count) terminais").foregroundStyle(.secondary)
        }
    }
}

private struct Chip<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(Theme.Font.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(hovered ? 0.2 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: Layout and text

/// Where each of today's meetings goes on the timeline. Overlapping meetings
/// share the width side by side, as in Calendar.
struct DayLayout {
    struct Placed {
        let event: GoogleCalendarClient.Event
        /// Clamped to the day.
        let start: Date
        let end: Date
        var column = 0
        var columns = 1
        /// Titles of the meetings this one overlaps.
        var conflicts: [String] = []
    }

    /// The working day shown even without meetings; meetings outside it widen it.
    static let workdayHours = 8..<18

    let start: Date
    let hours: [Int]
    let placed: [Placed]
    let workdayEnd: Date
    let freeSlots: [(start: Date, end: Date)]

    init(events: [GoogleCalendarClient.Event], now: Date, calendar: Calendar = .current) {
        let midnight = calendar.startOfDay(for: now)
        let nextMidnight = midnight.addingTimeInterval(86_400)
        var items = events
            .map { Placed(event: $0, start: max($0.start, midnight), end: min($0.end, nextMidnight)) }
            .sorted { ($0.start, $1.end) < ($1.start, $0.end) }

        let hour = { (date: Date) in date.timeIntervalSince(midnight) / 3600 }
        let first = min(Self.workdayHours.lowerBound, items.map { Int(hour($0.start).rounded(.down)) }.min() ?? 24)
        let last = max(Self.workdayHours.upperBound, items.map { Int(hour($0.end).rounded(.up)) }.max() ?? 0)
        start = midnight.addingTimeInterval(Double(first) * 3600)
        hours = Array(first..<max(last, first + 1))
        workdayEnd = midnight.addingTimeInterval(Double(Self.workdayHours.upperBound) * 3600)

        // Columns: clusters of meetings that overlap one another share the width.
        var cluster: [Int] = []
        var clusterEnd = Date.distantPast
        var columnEnds: [Date] = []
        func closeCluster() {
            for index in cluster { items[index].columns = columnEnds.count }
            cluster = []
            columnEnds = []
        }
        for index in items.indices {
            if items[index].start >= clusterEnd { closeCluster() }
            let column = columnEnds.firstIndex { $0 <= items[index].start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(items[index].end) } else { columnEnds[column] = items[index].end }
            items[index].column = column
            cluster.append(index)
            clusterEnd = max(clusterEnd, items[index].end)
        }
        closeCluster()
        for a in items.indices {
            items[a].conflicts = items.indices.filter { b in
                b != a && items[b].start < items[a].end && items[a].start < items[b].end
            }.map { items[$0].event.title }
        }
        placed = items

        // Free time left in the working day, at least 15 minutes long.
        let workdayStart = midnight.addingTimeInterval(Double(Self.workdayHours.lowerBound) * 3600)
        var cursor = max(now, workdayStart)
        var slots: [(start: Date, end: Date)] = []
        for item in items where item.end > cursor {
            if item.start >= workdayEnd { break }
            if item.start.timeIntervalSince(cursor) >= 15 * 60 { slots.append((cursor, item.start)) }
            cursor = max(cursor, item.end)
        }
        if workdayEnd.timeIntervalSince(cursor) >= 15 * 60 { slots.append((cursor, workdayEnd)) }
        freeSlots = slots
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < start.addingTimeInterval(Double(hours.count) * 3600)
    }

    /// The hour to scroll to: one before now, so the next meetings are in view.
    func scrollHour(now: Date) -> Int {
        let hour = Calendar.current.component(.hour, from: now) - 1
        return min(max(hour, hours.first ?? 0), hours.last ?? 0)
    }
}

@MainActor
enum TodayFormat {
    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        return formatter
    }()

    /// "sexta-feira, 16 de outubro"
    static func longDate(_ date: Date) -> String {
        longDateFormatter.string(from: date)
    }

    /// "Livre: 12:10–13:30 · 15:00–18:00"
    static func free(_ slots: [(start: Date, end: Date)], meetings: Int, now: Date, dayEnd: Date) -> String {
        if now >= dayEnd { return meetings == 0 ? "Sem reuniões hoje." : "Dia de trabalho encerrado." }
        if slots.isEmpty { return "Sem horário livre até as \(TopBarFormat.time(dayEnd))." }
        let ranges = slots.map { "\(TopBarFormat.time($0.start))–\(TopBarFormat.time($0.end))" }
        return (meetings == 0 ? "Sem reuniões hoje. " : "") + "Livre: " + ranges.joined(separator: " · ")
    }

    static func attention(_ kind: AgentAttention, full: Bool) -> String {
        switch kind {
        case .finished: return "Claude terminou"
        case .needsInput(let detail): return full ? (detail ?? "Claude precisa de você") : "esperando você"
        }
    }
}

extension String {
    /// "sexta-feira, 16 de outubro" → "Sexta-feira, 16 de outubro".
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
