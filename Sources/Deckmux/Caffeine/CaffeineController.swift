import AppKit
import Combine
import DeckmuxCaffeine
import DeckmuxMonitor
import OSLog
import SwiftUI
import UserNotifications

/// A chat the café is keeping awake.
struct CaffeineChat: Identifiable, Equatable {
    /// The terminal.
    let id: UUID
    let itemID: UUID
    let name: String
    let color: Color?
    /// `.working` or `.subagents(n)`.
    let work: ChatWork
}

/// What the interface shows of the café.
struct CaffeineSnapshot: Equatable {
    var phase: CaffeinePhase = .off
    var onSince: Date?
    var deadline: Date?
    /// Only the chats under its effect; empty while off.
    var chats: [CaffeineChat] = []
    var power = PowerSource(onBattery: false, percent: nil)

    var isOn: Bool { phase != .off }

    func isUnderEffect(terminal: UUID) -> Bool { chats.contains { $0.id == terminal } }

    /// `.working` when one of the item's terminals works, otherwise its live subagents; nil when none.
    func work(ofItem id: UUID) -> ChatWork? {
        let mine = chats.filter { $0.itemID == id }
        guard !mine.isEmpty else { return nil }
        if mine.contains(where: { $0.work == .working }) { return .working }
        let agents = mine.reduce(0) { total, chat in
            if case .subagents(let n) = chat.work { return total + n }
            return total
        }
        return .subagents(agents)
    }
}

/// The café: keeps the Mac awake, lid closed included, while some chat works,
/// and lets it sleep once the last one is done.
@MainActor
final class CaffeineController: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "cafe")
    nonisolated static let notificationID = "deckmux-cafe"
    static let tick: TimeInterval = 5

    @Published private(set) var snapshot = CaffeineSnapshot()

    private let deck: Deck
    private var state = Caffeine()
    private let sleepGuard = SleepGuard()
    private let watcher = SubagentWatcher()
    private var subagents: [UUID: [SubagentInfo]] = [:]
    private var timer: Timer?
    /// Terminals whose tab shows the cup.
    private var markedTabs: Set<UUID> = []

    init(deck: Deck) {
        self.deck = deck
        watcher.onChange = { [weak self] id, agents in
            self?.subagents[id] = agents
            self?.update()
        }
    }

    /// A crash may have left sleep disabled.
    func start() { SleepGuard.restoreSleepAtLaunch() }

    var isRuleInstalled: Bool { SudoersRule.isInstalled() }

    func toggle() {
        if state.isOn { turnOff() } else { turnOn() }
    }

    func turnOff() {
        if let summary = state.turnOff(at: Date()) { finish(summary) }
    }

    /// ⌘Q: the chats close with Deckmux, so there is nothing to keep awake.
    func shutdown() { turnOff() }

    func removeRule() {
        turnOff()
        do {
            _ = try SudoersRule.remove()
        } catch {
            alert("Não deu para remover a permissão", detail: "\(error)")
        }
    }

    // MARK: Turning on

    private func turnOn() {
        if !SudoersRule.isInstalled() {
            guard explainRule(), install() else { return }
        }
        if let refusal = state.turnOn(input()) {
            alert(CaffeineCopy.refusal(refusal), detail: nil)
            return
        }
        guard engage(retrying: true) else {
            _ = state.turnOff(at: Date())
            publish()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func engage(retrying: Bool) -> Bool {
        do {
            try sleepGuard.engage()
            return true
        } catch {
            let detail: String
            if case SleepGuard.Failure.denied(let output) = error { detail = output } else { detail = "\(error)" }
            let alert = NSAlert()
            alert.messageText = "Não deu para manter o Mac acordado"
            alert.informativeText = detail
            if retrying { alert.addButton(withTitle: "Reinstalar permissão") }
            alert.addButton(withTitle: "Cancelar")
            guard retrying, alert.runModal() == .alertFirstButtonReturn, install() else { return false }
            return engage(retrying: false)
        }
    }

    private func explainRule() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Manter o Mac acordado com a tampa fechada"
        alert.informativeText = "O Deckmux vai pedir sua senha uma vez para poder ligar e desligar o repouso (só o comando pmset disablesleep). Dá para remover depois no menu do Deckmux."
        alert.addButton(withTitle: "Continuar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// false when cancelled or failed (the failure is shown).
    private func install() -> Bool {
        do {
            return try SudoersRule.install()
        } catch {
            alert("Não deu para instalar a permissão", detail: "\(error)")
            return false
        }
    }

    // MARK: Ticking

    private func update() {
        guard state.isOn else { return }
        watchSubagents()
        if let summary = state.update(input()) {
            finish(summary)
        } else {
            publish()
        }
    }

    private func finish(_ summary: CaffeineSummary) {
        timer?.invalidate()
        timer = nil
        watcher.stop()
        subagents = [:]
        sleepGuard.release()
        publish()
        Self.logger.info("Café off: \(CaffeineCopy.reason(summary.reason), privacy: .public)")
        if summary.reason != .user { notify(summary) }
    }

    private func input() -> CaffeineInput {
        let power = PowerSource.read()
        return CaffeineInput(now: Date(), workingChats: chats().count, onBattery: power.onBattery,
                             batteryPercent: power.percent,
                             thermalCritical: ProcessInfo.processInfo.thermalState == .critical)
    }

    /// The chats that count as working right now.
    private func chats() -> [CaffeineChat] {
        let now = Date()
        var found: [CaffeineChat] = []
        for item in deck.items {
            let layout = item.layout
            let color = deck.workspace(of: item)?.color
            for (id, _) in layout.claudeSessions {
                let surface = layout.terminal(withID: id)
                var needsInput = false
                if case .needsInput = layout.attention[id] { needsInput = true }
                let work = WorkRule.work(titleWorking: surface.map(TerminalLabel.isWorking) ?? false,
                                         needsInput: needsInput, subagents: subagents[id] ?? [], now: now)
                guard work != .idle else { continue }
                let name = TerminalLabel.plainName(pwd: surface?.pwd, title: surface?.title ?? "", runsClaude: true)
                found.append(CaffeineChat(id: id, itemID: item.id, name: name, color: color, work: work))
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func watchSubagents() {
        var sessions: [(terminal: UUID, cwd: String, sessionID: String)] = []
        for item in deck.items {
            for (id, session) in item.layout.claudeSessions {
                guard let cwd = session.directory ?? item.layout.terminal(withID: id)?.pwd else { continue }
                sessions.append((id, cwd, session.sessionID))
            }
        }
        watcher.watch(sessions)
    }

    private func publish() {
        var next = CaffeineSnapshot(phase: state.phase, onSince: state.onSince, deadline: state.deadline)
        if state.isOn {
            next.chats = chats()
            next.power = PowerSource.read()
        }
        markTabs(Set(next.chats.map(\.id)))
        if next != snapshot {
            snapshot = next
            #if DEBUG
            print("[cafe] \(next.phase) chats=\(next.chats.map { "\($0.name):\($0.work)" }) power=\(next.power)")
            #endif
        }
    }

    /// Only the terminals that entered or left the effect.
    private func markTabs(_ terminals: Set<UUID>) {
        guard terminals != markedTabs else { return }
        for item in deck.items {
            for (id, _) in item.layout.claudeSessions where terminals.contains(id) != markedTabs.contains(id) {
                item.layout.setCaffeine(terminals.contains(id), forTerminal: id)
            }
        }
        markedTabs = terminals
    }

    // MARK: Telling the user

    private func notify(_ summary: CaffeineSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Café"
        content.body = CaffeineCopy.notificationBody(summary)
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.logger.error("Could not post the café notification: \(error, privacy: .public)") }
        }
    }

    private func alert(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.runModal()
    }
}
