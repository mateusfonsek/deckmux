import AppKit
import Combine
import OSLog
import SwiftUI

/// What Claude Code is doing across all of Deckmux, the most urgent first.
enum AgentStatus: Equatable {
    /// Some terminal waits on a permission prompt or a question.
    case needsInput
    /// Some terminal finished and the user has not looked at it yet.
    case finished
    /// Some terminal's Claude is working.
    case working
    case idle

    @MainActor static func current(in deck: Deck) -> AgentStatus {
        var finished = false
        var working = false
        for item in deck.items {
            let layout = item.layout
            for kind in layout.attention.values {
                if case .needsInput = kind { return .needsInput }
                finished = true
            }
            if !working {
                working = layout.claudeSessions.keys.contains { id in
                    layout.terminal(withID: id).map(TerminalLabel.isWorking) ?? false
                }
            }
        }
        return finished ? .finished : working ? .working : .idle
    }

    var label: String {
        switch self {
        case .needsInput: "Claude precisa de você"
        case .finished: "Claude terminou"
        case .working: "Claude trabalhando…"
        case .idle: "Nada a fazer"
        }
    }
}

/// The Deckmux face in the menu bar: asleep when idle, looking
/// around while Claude works, happy when it finished, wide awake with an
/// orange dot when it needs the user, and a count when two or more terminals
/// wait. Its menu is a quick look, not a second app: the state, the next
/// meeting, the terminals waiting and a few shortcuts.
@MainActor
final class AgentStatusItem: NSObject, NSMenuDelegate {
    nonisolated private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "agent")
    private let deck: Deck
    private let meetings: NextMeetingModel
    private let tasks: TasksModel
    private let reveal: (UUID) -> Void
    private let openApp: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var status = AgentStatus.idle
    private var waiting = 0
    private var frame = 0
    private var timer: Timer?
    private var deckObserver: AnyCancellable?
    /// The Janelinha: its state and the switch, set by the app delegate.
    var isMonitorEnabled: () -> Bool = { false }
    var onToggleMonitor: () -> Void = {}

    init(deck: Deck, meetings: NextMeetingModel, tasks: TasksModel,
         reveal: @escaping (UUID) -> Void, openApp: @escaping () -> Void) {
        self.deck = deck
        self.meetings = meetings
        self.tasks = tasks
        self.reveal = reveal
        self.openApp = openApp
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.image = AgentFace.image(.idle)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Deckmux")
        }
    }

    /// Follows the deck (bells, Claude sessions, the focused terminal's
    /// state) and, only while some terminal runs Claude Code, looks every
    /// 0.6 s instead of observing every terminal's title, which Claude Code
    /// changes ten times a second while it works. The same tick moves the
    /// eyes. Without Claude the timer is off: nothing wakes the app.
    func start() {
        deckObserver = deck.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.deckDidChange() }
        deckDidChange()
    }

    private func deckDidChange() {
        update()
        let runsClaude = deck.items.contains { !$0.layout.claudeSessions.isEmpty }
        if runsClaude, timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.1
            self.timer = timer
        } else if !runsClaude, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func update() {
        let now = AgentStatus.current(in: deck)
        let waitingNow = deck.items.reduce(0) { $0 + $1.layout.attention.count }
        guard now != status || now == .working || waitingNow != waiting else { return }
        frame = now == .working && status == .working ? frame + 1 : 0
        if now != status { Self.logger.info("Menu bar: \(now.label, privacy: .public)") }
        status = now
        waiting = waitingNow
        guard let button = item.button else { return }
        button.image = AgentFace.image(now, frame: frame)
        button.toolTip = now.label
        // Two or more terminals waiting: the count next to the face, as Slack does.
        if waitingNow >= 2 {
            let color: NSColor = now == .needsInput ? .systemOrange : .labelColor
            button.attributedTitle = NSAttributedString(string: "\(waitingNow)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color,
                .baselineOffset: 0.5,
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        // The state: the face, what it means and the numbers behind it.
        let header = NSMenuItem()
        header.isEnabled = false
        header.view = StatusMenuRowView(.init(leading: .face(status), title: status.label, subtitle: summary(), selectable: false),
                                        height: StatusMenuRowView.headerHeight)
        menu.addItem(header)

        // The next meeting, within a day (same rules as the top bar).
        if let event = meetings.next, event.start.timeIntervalSince(now) < 24 * 60 * 60 {
            menu.addItem(.separator())
            menu.addItem(meetingRow(event, now: now))
        }

        // Terminals that wait, questions first.
        let rows = waitingTerminals(now: now)
        if !rows.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Precisa de você"))
            for row in rows {
                let entry = NSMenuItem(title: row.content.title, action: #selector(revealTerminal(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = row.terminal
                entry.view = StatusMenuRowView(row.content)
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let newTerminal = NSMenuItem(title: "Novo terminal em", action: nil, keyEquivalent: "")
        newTerminal.image = StatusMenuImages.symbol("plus")
        newTerminal.submenu = newTerminalMenu()
        menu.addItem(newTerminal)
        let newTask = NSMenuItem(title: "Nova tarefa…", action: #selector(newTask(_:)), keyEquivalent: "")
        newTask.target = self
        newTask.image = StatusMenuImages.symbol("plus.square")
        menu.addItem(newTask)
        let taskManager = NSMenuItem(title: "Gerenciador de tarefas…", action: #selector(openTaskManager(_:)), keyEquivalent: "")
        taskManager.target = self
        taskManager.image = StatusMenuImages.symbol("cpu")
        menu.addItem(taskManager)
        let monitor = NSMenuItem(title: "Janelinha", action: #selector(toggleMonitor(_:)), keyEquivalent: "")
        monitor.target = self
        monitor.image = StatusMenuImages.symbol("rectangle.inset.bottomright.filled")
        monitor.state = isMonitorEnabled() ? .on : .off
        menu.addItem(monitor)

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Abrir Deckmux", action: #selector(openDeckmux(_:)), keyEquivalent: "")
        open.target = self
        // The system gives "Sair" its own image; this one matches it.
        open.image = StatusMenuImages.symbol("macwindow")
        // Shows the global shortcut; the shortcut itself is registered system-wide.
        let preset = GlobalHotkey.preset
        open.keyEquivalent = preset.keyEquivalent
        open.keyEquivalentModifierMask = preset.modifierFlags
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Sair do Deckmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    /// "1 pergunta · 2 terminaram · 1 trabalhando", or what there is instead.
    private func summary() -> String {
        var questions = 0, finished = 0, working = 0, claude = 0
        for item in deck.items {
            let layout = item.layout
            for kind in layout.attention.values {
                if case .needsInput = kind { questions += 1 } else { finished += 1 }
            }
            claude += layout.claudeSessions.count
            working += layout.claudeSessions.keys.filter { id in
                layout.terminal(withID: id).map(TerminalLabel.isWorking) ?? false
            }.count
        }
        var parts: [String] = []
        if questions > 0 { parts.append(questions == 1 ? "1 pergunta" : "\(questions) perguntas") }
        if finished > 0 { parts.append(finished == 1 ? "1 terminou" : "\(finished) terminaram") }
        if working > 0 { parts.append("\(working) trabalhando") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch claude {
        case 0: return "Nenhum terminal com Claude"
        case 1: return "1 terminal com Claude, parado"
        default: return "\(claude) terminais com Claude, parados"
        }
    }

    private func meetingRow(_ event: GoogleCalendarClient.Event, now: Date) -> NSMenuItem {
        let workspace = meetings.workspace(of: event)
        let color = workspace.flatMap { NSColor(hex: $0.manifest.color) } ?? .secondaryLabelColor
        let inProgress = event.start <= now
        let isSoon = inProgress || event.start.timeIntervalSince(now) <= 10 * 60
        let range = "\(TopBarFormat.time(event.start)) – \(TopBarFormat.time(event.end))"
        var subtitle: String
        if inProgress {
            subtitle = "Agora · até \(TopBarFormat.time(event.end))"
        } else if let relative = TopBarFormat.relative(event, now: now) {
            subtitle = "\(relative) · \(range)"
        } else if Calendar.current.isDate(event.start, inSameDayAs: now) {
            subtitle = range
        } else {
            subtitle = "amanhã · \(range)"
        }
        if let name = workspace?.name { subtitle += " · \(name)" }
        var content = StatusMenuRowView.Content(leading: .swatch(color), title: event.title, subtitle: subtitle)
        if event.meetURL != nil, isSoon {
            content.pill = ("Entrar", color)
        } else {
            content.trailing = event.meetURL != nil ? "Meet" : "Agenda"
        }
        let entry = NSMenuItem(title: event.title, action: #selector(openMeeting(_:)), keyEquivalent: "")
        entry.target = self
        entry.view = StatusMenuRowView(content)
        return entry
    }

    /// Terminals with a bell, questions first: the conversation (or folder),
    /// why it waits and since when, and the workspace on the right.
    private func waitingTerminals(now: Date) -> [(terminal: UUID, content: StatusMenuRowView.Content)] {
        var rows: [(UUID, Date, Bool, StatusMenuRowView.Content)] = []
        for item in deck.items {
            let layout = item.layout
            let workspace = deck.workspace(of: item)
            for (id, kind) in layout.attention {
                let surface = layout.terminal(withID: id)
                let name = TerminalLabel.plainName(pwd: surface?.pwd, title: surface?.title ?? "",
                                                   runsClaude: layout.claudeSessions[id] != nil)
                let since = layout.attentionSince[id] ?? now
                let reason: String
                let isQuestion: Bool
                switch kind {
                case .needsInput(let detail):
                    reason = detail ?? "Precisa de você"
                    isQuestion = true
                case .finished:
                    reason = "Terminou"
                    isQuestion = false
                }
                var content = StatusMenuRowView.Content(
                    leading: .symbol(isQuestion ? "bell.fill" : "checkmark.circle", .systemOrange),
                    title: name, subtitle: "\(reason) · \(Self.ago(since, now: now))")
                if let workspace {
                    content.trailing = workspace.name
                    content.trailingSwatch = NSColor(hex: workspace.manifest.color)
                }
                rows.append((id, since, isQuestion, content))
            }
        }
        // Questions first; within each kind, the oldest bell first.
        return rows.sorted { a, b in a.2 != b.2 ? a.2 : a.1 < b.1 }.map { ($0.0, $0.3) }
    }

    /// "agora", "há 3 min", "há 1 h 05".
    static func ago(_ since: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        if minutes < 1 { return "agora" }
        if minutes < 60 { return "há \(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "há \(minutes / 60) h" : "há \(minutes / 60) h \(String(format: "%02d", rest))"
    }

    private func newTerminalMenu() -> NSMenu {
        let menu = NSMenu()
        let home = NSMenuItem(title: "Sem workspace", action: #selector(newTerminalOutside(_:)), keyEquivalent: "")
        home.target = self
        home.image = StatusMenuImages.symbol("house")
        menu.addItem(home)
        if !deck.workspaces.workspaces.isEmpty { menu.addItem(.separator()) }
        for workspace in deck.workspaces.workspaces {
            let entry = NSMenuItem(title: workspace.name, action: #selector(newTerminal(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = workspace.id
            entry.image = StatusMenuImages.swatch(NSColor(hex: workspace.manifest.color) ?? .secondaryLabelColor)
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: Actions

    @objc private func revealTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        reveal(id)
    }

    @objc private func openMeeting(_ sender: NSMenuItem) {
        meetings.next?.open()
    }

    @objc private func newTerminalOutside(_ sender: NSMenuItem) {
        openApp()
        deck.addOutsideWorkspaces()
    }

    @objc private func newTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID,
              let workspace = deck.workspaces.workspaces.first(where: { $0.id == id }) else { return }
        openApp()
        deck.add(in: workspace)
    }

    @objc private func newTask(_ sender: NSMenuItem) {
        openApp()
        deck.show(.today)
        tasks.newTask()
    }

    @objc private func openDeckmux(_ sender: Any?) { openApp() }

    @objc private func toggleMonitor(_ sender: Any?) { onToggleMonitor() }

    @objc private func openTaskManager(_ sender: Any?) { TaskManagerWindowController.shared?.show() }
}

/// The Deckmux mark next to the wordmark (sidebar, palette): the menu bar
/// face with its eyes open, on the same 24-point grid. Drawn with shapes, not
/// the template image, so it takes exactly the text's color around it.
struct DeckmuxMark: View {
    var size: CGFloat = 14

    var body: some View {
        let unit = size / 24
        // Heavier lines than in the menu bar: at 12–14 pt it sits next to semibold text.
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4.6 * unit, style: .continuous)
                .stroke(lineWidth: 2.3 * unit)
                .frame(width: 18.5 * unit, height: 15 * unit)
                .offset(x: 2.75 * unit, y: 4.75 * unit)
            ForEach([7.75, 13.15], id: \.self) { x in
                Capsule()
                    .frame(width: 3.1 * unit, height: 5.4 * unit)
                    .offset(x: x * unit, y: 9.6 * unit)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The menu bar face, drawn on a 24-point grid scaled to 20 points (same
/// proportions as the app icon: a wide body and two capsule eyes).
/// A template image, so the menu bar colors it, except "needs you", whose dot
/// is orange.
enum AgentFace {
    private static let size: CGFloat = 20
    private static let dot = CGPoint(x: 20.4, y: 4.5)

    /// The face at `size` points. With `ink`, a plain image in that color (the
    /// menu's header); without it, a template image for the menu bar.
    static func image(_ status: AgentStatus, frame: Int = 0, size: CGFloat = AgentFace.size, ink: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size / 24, y: size / 24)
            // Solid like the template states, in the menu bar's appearance
            // (resolved while drawing); labelColor is translucent.
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = ink ?? (status == .needsInput && dark ? NSColor.white : NSColor.black)
            ink.set()
            drawFace(status, frame: frame)
            if status == .finished || status == .needsInput {
                context.setBlendMode(.clear)
                NSBezierPath(ovalIn: circle(dot, radius: 4.3)).fill()
                context.setBlendMode(.normal)
                (status == .needsInput ? NSColor.systemOrange : ink).set()
                NSBezierPath(ovalIn: circle(dot, radius: 2.7)).fill()
            }
            return true
        }
        image.isTemplate = ink == nil && status != .needsInput
        image.accessibilityDescription = status.label
        return image
    }

    private static func drawFace(_ status: AgentStatus, frame: Int) {
        let body = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 4.75, width: 18.5, height: 15), xRadius: 4.6, yRadius: 4.6)
        body.lineWidth = 1.6
        body.stroke()
        switch status {
        case .idle:                          // asleep: eyes closed
            stroke([(8.1, 13.4), (10.5, 13.4)], width: 1.7)
            stroke([(13.5, 13.4), (15.9, 13.4)], width: 1.7)
        case .working:                       // looking around while it works
            let dx = [-1.8, 0, 1.8, 0][frame % 4]
            for x in [8.05, 13.45] { capsule(x: x + dx, y: 9.6, width: 2.5, height: 5.4) }
        case .finished:                      // happy
            stroke([(8, 13.6), (9.3, 11.9), (10.6, 13.6)], width: 1.55)
            stroke([(13.4, 13.6), (14.7, 11.9), (16, 13.6)], width: 1.55)
        case .needsInput:                    // wide awake, looking at you
            for x in [7.9, 13.3] { capsule(x: x, y: 8.7, width: 2.8, height: 7) }
        }
    }

    private static func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { path.line(to: CGPoint(x: point.0, y: point.1)) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func capsule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                     xRadius: width / 2, yRadius: width / 2).fill()
    }

    private static func circle(_ center: CGPoint, radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
