#if DEBUG
import AppKit
import DeckmuxAgents
import SwiftUI
import UserNotifications

/// For automated checks of the debug build, which cannot click or capture the
/// screen: commands arrive as the object of the distributed notification
/// `dev.fonsek.deckmux.debug`.
/// - `cafe` toggles the café; `cafe-off` turns it off.
/// - `open <dir>|<input>` opens a terminal in <dir> and types <input>.
/// - `type <text>` / `enter` type into the selected item's focused terminal.
/// - `appearance light|dark` switches the app's appearance.
/// - `notes` prints the delivered notifications.
/// - `settings` opens Ajustes; `enable <agent> on|off` turns an agent on or off
///   as the Ajustes toggle does.
/// - `button <id>` runs a tab-bar button's action in the selected item, as a
///   click on it does (e.g. `button newAgent.claude`).
/// - `mcp-sync <folder>` reviews writing <folder>'s `.mcp.json` servers into
///   the enabled agents' files (apply with `review apply`); `mcp-check <folder>`
///   prints each enabled agent's health for them.
/// - `state` prints each terminal's agent session, turn, working state and bell,
///   and each sidebar item's agent.
/// - `snap <dir>` writes every visible window, the café panel and the menu bar
///   face as PNGs into <dir> (rendered by the app, no screen recording needed).
@MainActor
enum DebugCommands {
    private static var observer: NSObjectProtocol?

    static func start(window: MainWindowController) {
        setvbuf(stdout, nil, _IOLBF, 0)   // the log file gets each line as it comes
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.fonsek.deckmux.debug"), object: nil, queue: .main
        ) { [weak window] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let window else { return }
                run(command, window: window)
            }
        }
    }

    private static func run(_ command: String, window: MainWindowController) {
        print("[debug] \(command)")
        let (verb, rest) = split(command)
        switch verb {
        case "cafe": window.caffeine.toggle()
        case "cafe-off": window.caffeine.turnOff()
        case "open":
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = parts.first ?? NSHomeDirectory()
            if parts.count > 1 { config.initialInput = parts[1] + "\n" }
            window.deck.add(config: config)
        case "snap": snap(into: URL(fileURLWithPath: rest), window: window)
        case "type": window.deck.selected?.layout.focusedSurface?.surfaceModel?.sendText(rest)
        case "enter":
            let surface = window.deck.selected?.layout.focusedSurface?.surfaceModel
            surface?.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
            surface?.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
        case "appearance": NSApp.appearance = NSAppearance(named: rest == "light" ? .aqua : .darkAqua)
        case "notes":
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                for note in notes { print("[debug] note \(note.request.identifier): \(note.request.content.body)") }
                print("[debug] notes: \(notes.count)")
            }
        case "settings": window.deck.showSettings()
        case "enable":
            let parts = rest.split(separator: " ").map(String.init)
            if parts.count == 2, let kind = AgentKind(rawValue: parts[0]) {
                let model = window.settingsModel
                AgentActivation.request(kind, on: parts[1] == "on", settings: .shared, review: model.review) { model.notice = $0 }
            }
            print("[debug] enabled: \(AgentSettings.shared.enabled.map(\.rawValue))")
        case "button":
            if let layout = window.deck.selected?.layout {
                layout.splitTabBar(layout.bonsplit, didRequestCustomAction: rest, inPane: layout.bonsplit.focusedPaneId ?? layout.bonsplit.allPaneIds[0])
            }
        case "review":
            // Prints the pending review, or applies it with `review apply`.
            if let pending = window.settingsModel.review.review {
                let model = window.settingsModel.review
                print("[debug] review: \(pending.set.title)")
                for change in pending.set.changes {
                    print("[debug]   \(change.url.path) \(change.summary)\n\(change.after ?? "<delete>")")
                }
                if rest == "apply" { model.apply(pending) }
            } else {
                print("[debug] review: none")
            }
        case "mcp-sync":
            let root = URL(fileURLWithPath: rest)
            let changes = WorkspaceOperations.agentMcpChanges(root: root, adding: WorkspaceOperations.mcpServers(in: root), removing: [])
            window.settingsModel.review.propose(ChangeSet(title: "MCP sync", changes: changes))
        case "context-migrate":
            let root = URL(fileURLWithPath: rest)
            print("[debug] context file: \(WorkspaceOperations.contextURL(root).lastPathComponent) migrate=\(WorkspaceOperations.needsContextMigration(root))")
            window.settingsModel.review.propose(ChangeSet(title: "Context", changes: WorkspaceOperations.contextMigrationChanges(root)))
        case "mcp-check":
            let root = URL(fileURLWithPath: rest)
            Task { @MainActor in
                let results = await McpStatusChecker.check(root: root, agents: AgentSettings.shared.enabled)
                for (kind, result) in results.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    switch result {
                    case .success(let health): print("[debug] mcp \(kind.rawValue): \(health.sorted { $0.key < $1.key })")
                    case .failure(let error): print("[debug] mcp \(kind.rawValue) failed: \(error.message)")
                    }
                }
            }
        case "workspace":
            // `workspace <slug> <tab>`: shows the Workspaces screen on that workspace's tab (geral, claude, mcps).
            let parts = rest.split(separator: " ").map(String.init)
            window.deck.showWorkspacesTab()
            if let slug = parts.first { window.workspacesModel.selectedSlug = slug }
            if parts.count > 1, let tab = WorkspacesModel.DetailTab.allCases.first(where: { "\($0)" == parts[1] }) {
                window.workspacesModel.detailTab = tab
            }
        case "buttons":
            print("[debug] buttons: \(window.deck.selected?.layout.bonsplit.configuration.appearance.splitButtons.map(\.id) ?? [])")
        case "state":
            for item in window.deck.items {
                let layout = item.layout
                print("[debug] item \(item.displayName) agent=\(item.runningAgent?.rawValue ?? "-") working=\(item.agentWorking)")
                for (id, session) in layout.agentSessions {
                    print("[debug]   \(session.agent.rawValue) \(session.sessionID) turn=\(layout.agentTurns.contains(id)) working=\(AgentWork.isWorking(terminal: id, in: layout)) bell=\(String(describing: layout.attention[id]))")
                }
            }
            print("[debug] status: \(AgentStatus.current(in: window.deck).label)")
        default: print("[debug] unknown command")
        }
    }

    private static func split(_ command: String) -> (String, String) {
        guard let space = command.firstIndex(of: " ") else { return (command, "") }
        return (String(command[..<space]), String(command[command.index(after: space)...]))
    }

    private static func snap(into dir: URL, window: MainWindowController) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, shown) in NSApp.windows.enumerated() where shown.isVisible {
            guard let view = shown.contentView?.superview ?? shown.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            write(rep, to: dir.appendingPathComponent("window-\(index).png"))
        }
        let panel = ImageRenderer(content: CaffeinePanel(caffeine: window.caffeine) {}
            .background(Color(nsColor: .windowBackgroundColor)))
        panel.scale = 2
        if let image = panel.nsImage { write(image, to: dir.appendingPathComponent("cafe-panel.png")) }
        let on = window.caffeine.snapshot.isOn
        write(AgentFace.image(.working, size: 80, ink: .black, caffeine: on), to: dir.appendingPathComponent("menubar-face.png"))
        print("[debug] snap -> \(dir.path)")
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        write(rep, to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
