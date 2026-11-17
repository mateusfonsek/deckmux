import AppKit
import DeckmuxAgents
import OSLog
import UserNotifications

/// Turns agent hook messages into Deckmux state: the conversation each
/// terminal runs (for resuming it later), whether its turn is open, the bell
/// on its sidebar item and tab, and a macOS notification when the user is not
/// looking at that terminal. Each agent's provider translates its own hooks.
@MainActor
final class AgentHookCenter {
    nonisolated private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "agent")
    nonisolated static let terminalKey = "deckmux.terminal"

    private let deck: Deck
    private let server = AgentSocketServer(path: AgentIntegration.socketPath)
    /// When each terminal last asked for permission, to drop the Notification
    /// hook Claude Code sends for the same prompt.
    private var lastPermissionRequest: [UUID: Date] = [:]
    /// Set while quitting: the conversations end because Deckmux closes their
    /// terminals, and they must still be resumed next time.
    var isTerminating = false

    init(deck: Deck) {
        self.deck = deck
        server.onMessage = { [weak self] message in self?.handle(message) }
    }

    func start() {
        server.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Self.logger.error("Notification authorization failed: \(error, privacy: .public)") }
        }
    }

    func stop() { server.stop() }

    // MARK: Hook events

    private func handle(_ message: AgentHookMessage) {
        guard !isTerminating,
              let id = message.terminalID,
              let item = deck.item(withTerminal: id) else { return }
        let layout = item.layout
        // Agents turned off in Ajustes are not followed, even if their hooks
        // still fire (the Claude wrapper always adds them; a hooks file kept).
        guard AgentSettings.shared.isEnabled(message.agent) else { return }
        let payload = message.stringPayload
        // Claude Code's permission Notification repeats its PermissionRequest.
        if message.agent == .claude, message.event == "notification", payload["notification_type"] == "permission_prompt",
           let last = lastPermissionRequest[id], Date().timeIntervalSince(last) < 10 { return }
        guard let event = AgentRegistry.provider(for: message.agent).event(hook: message.event, payload: payload) else {
            Self.logger.debug("Unhandled hook event \(message.agent.rawValue, privacy: .public) \(message.event, privacy: .public)")
            return
        }
        switch event {
        case .sessionStarted(let session, let cwd):
            layout.setAgentSession(AgentSession(agent: message.agent, sessionID: session, directory: cwd), forTerminal: id)
        case .sessionEnded:
            layout.setAgentSession(nil, forTerminal: id)
            clearAttention(terminal: id)
        case .turnStarted:
            // A prompt without a session (Deckmux started after the agent) opens nothing.
            guard layout.agentSessions[id] != nil else { return }
            layout.setTurn(true, forTerminal: id)
            clearAttention(terminal: id)
        case .activity:
            guard layout.agentSessions[id] != nil else { return }
            layout.touchTurn(forTerminal: id)
            // Working again after asking: the question was answered.
            if case .needsInput? = layout.attention[id] { clearAttention(terminal: id) }
        case .turnFinished:
            layout.setTurn(false, forTerminal: id)
            ring(.finished, terminal: id, in: item)
        case .needsInput(let detail):
            if message.event == "permission-request" { lastPermissionRequest[id] = Date() }
            // The turn stays open: once the user answers, the agent goes on
            // without another prompt hook. While it waits it does not count
            // for the café (WorkRule: needsInput is idle).
            ring(.needsInput(detail), terminal: id, in: item)
        }
    }

    // MARK: Bell

    private func ring(_ attention: AgentAttention, terminal id: UUID, in item: DeckItem) {
        guard !isLookingAt(terminal: id, in: item) else { return }
        item.layout.setAttention(attention, forTerminal: id)
        notify(attention, terminal: id, item: item)
    }

    /// The user is looking at a terminal when Deckmux is in front, its item is
    /// shown and it has keyboard focus.
    private func isLookingAt(terminal id: UUID, in item: DeckItem) -> Bool {
        guard NSApp.isActive, deck.page == nil, deck.selectedID == item.id,
              let surface = item.layout.terminal(withID: id) else { return false }
        return surface.window?.isKeyWindow == true && surface.window?.firstResponder === surface
    }

    func clearAttention(terminal id: UUID) {
        deck.item(withTerminal: id)?.layout.setAttention(nil, forTerminal: id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID(id)])
    }

    /// Clears the bell of the terminal the user is now looking at.
    func clearFocusedAttention() {
        guard NSApp.isActive, deck.page == nil, let surface = deck.selected?.layout.focusedSurface,
              surface.window?.firstResponder === surface else { return }
        clearAttention(terminal: surface.id)
    }

    // MARK: macOS notifications

    private func notify(_ attention: AgentAttention, terminal id: UUID, item: DeckItem) {
        let content = UNMutableNotificationContent()
        let workspace = deck.workspace(of: item)?.name
        content.title = [workspace, item.layout.terminal(withID: id).map { TerminalLabel.folderName($0.pwd) }]
            .compactMap { $0 }.joined(separator: " · ")
        let name = item.layout.agentSessions[id].map { AgentRegistry.provider(for: $0.agent).displayName } ?? "IA"
        switch attention {
        case .finished:
            content.body = "\(name) terminou."
        case .needsInput(let detail):
            content.body = detail.map { "\(name) precisa de você: \($0)" } ?? "\(name) precisa de você."
        }
        content.sound = .default
        content.userInfo = [Self.terminalKey: id.uuidString]
        let request = UNNotificationRequest(identifier: notificationID(id), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.logger.error("Could not post notification: \(error, privacy: .public)") }
        }
    }

    /// Shows the terminal a clicked notification came from.
    func reveal(terminal id: UUID) {
        guard let item = deck.item(withTerminal: id), let surface = item.layout.terminal(withID: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        surface.window?.makeKeyAndOrderFront(nil)
        deck.select(item)
        item.layout.focus(surface)
        clearAttention(terminal: id)
    }

    private func notificationID(_ terminal: UUID) -> String { "deckmux-claude-\(terminal.uuidString)" }
}
