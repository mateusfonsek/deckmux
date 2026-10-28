import AppKit
import OSLog
import UserNotifications

/// Turns Claude Code hook messages into Deckmux state: the conversation each
/// terminal runs (for resuming it later), the bell on its sidebar item and tab,
/// and a macOS notification when the user is not looking at that terminal.
@MainActor
final class ClaudeHookCenter {
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
        switch message.event {
        case "session-start":
            guard let session = message.string("session_id") else { return }
            layout.setClaudeSession(ClaudeSession(sessionID: session, directory: message.string("cwd")), forTerminal: id)
        case "session-end":
            layout.setClaudeSession(nil, forTerminal: id)
            clearAttention(terminal: id)
        case "stop":
            ring(.finished, terminal: id, in: item)
        case "permission-request":
            lastPermissionRequest[id] = Date()
            let tool = message.string("tool_name")
            ring(.needsInput(tool.map { "Quer usar \($0)" }), terminal: id, in: item)
        case "notification":
            // The idle reminder repeats what Stop already said; the permission
            // one repeats PermissionRequest.
            let kind = message.string("notification_type")
            if kind == "idle_prompt" { return }
            if kind == "permission_prompt", let last = lastPermissionRequest[id], Date().timeIntervalSince(last) < 10 { return }
            ring(.needsInput(message.string("message")), terminal: id, in: item)
        default:
            Self.logger.debug("Unhandled hook event \(message.event, privacy: .public)")
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
        switch attention {
        case .finished:
            content.body = "Claude terminou."
        case .needsInput(let detail):
            content.body = detail.map { "Claude precisa de você: \($0)" } ?? "Claude precisa de você."
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
